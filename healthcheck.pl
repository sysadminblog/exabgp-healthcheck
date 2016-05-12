#!/usr/bin/perl

########################################################################################
# ExaBGP - Health Checking Script
# GitHub project page: https://github.com/shthead/exabgp-healthcheck
########################################################################################
# This script is used with ExaBGP to control BGP announcements to various services.
# The IP's are only announced if the health check passes.
# See the GitHub page for more information.

use strict;
use warnings;

use Array::Utils qw(array_diff);
use Config::IniFiles;
use Data::Validate::IP qw(is_ipv4 is_ipv6);
use Digest::MD5::File qw( file_md5_hex );
use File::Basename;
use File::Pid;
use Getopt::Long;
use Log::Log4perl qw(get_logger);
use Scalar::Util qw(looks_like_number);
use Switch;
use Time::Piece;

# Default variables
my $help        = undef;
my $check       = undef;
my $version     = undef;
my $config      = '/etc/exabgp/healthcheck.conf';
my $command     = 'list';
my $healthdir   = '/var/healthcheck/';

# List of valid commands that can be used
my @commands = ( 'list', 'announce', 'validate', 'status' );

# Parse the provided options
GetOptions(
  "help|h"      => \$help,
  "version|v"   => \$version,
  "name|n=s"    => \$check,
  "config|f=s"  => \$config,
  "command|c=s" => \$command,
);

########## Begin Script ##########

my $script_version = '0.4.1';

# Get this scripts name
my $name = basename($0);
my $full_name = $0;

# If we need to print help, print and exit.
if ($help) { print_help(); }

# If we need to print the version for the script, print and exit.
if ($version) { print_version(); }

# Check to see if this script is running interactively. If so, let debug messages go to console
my $console_debug = undef;
if ($ENV{'USER'}) { $console_debug = 1; }
else { $SIG{INT} = sub { }; $SIG{TERM} = \&terminate; }

# Make STDOUT unbuffered
select STDOUT; $| = 1;

# Various variables that are used
my ($cfg,$logger,$service_state,$service_metric,$service_nexthop,@service_ips,$statusfile,$pidfile,$pid);

# Initialise the script with some basic sanity checks
init();

# Load config
$cfg = Config::IniFiles->new( -file => $config );

# Decide what needs to be done
switch ($command) {

  # Announce routes for a config
  case 'announce' {

    # Start logging
    $logger = start_log();

    # Validate the configuration to make sure it will work for this check.
    if (validate_config($check) ne 'valid') {
      $logger->error("$check: The configuration file cannot be validated due to errors, this script will not run.");
      $logger->error(validate_config($check));
      print "Script died due to config errors:\n";
      print validate_config($check);
      die;
    }

    # Make sure that the status file can be opened for writing. This only matters if its running under ExaBGP and not via SSH
    if (! $console_debug) {
      $statusfile = "$healthdir$check";
      $pidfile = "$healthdir$check.run";
      if (-f $statusfile && ! -w $statusfile) {
        $logger->error("$check: Cannot write status file. Ensure that $statusfile is writable.");
        print "Cannot write status file or PID file. Ensure that $pidfile and $statusfile are writable.\n";
        die;
      }
      # Writeout PID file
      $pid = File::Pid->new({file => $pidfile});
      if ($pid->running()) {
        $logger->error("$check: Process already locked, check there isn't already a process running for this.");
        print "Process already locked, check there isn't already a process running for this check.\n";
        die;
      }
      $pid->write();
    }

    # Start the announcements
    run_announce();
  }

  case 'list' {
    # If this is for a single service, get the facts
    if ($check) {
      print "Facts for $check:\n";
      # Make sure config is valid
      if (validate_config($check) ne 'valid') {
        print "Error: Invalid configuration. Perhaps try $full_name -c validate -n $check\n";
      } else {
        get_facts($check);
      }
    } else {
      # Get a list of sections and loop over them
      foreach (@{$cfg->{mysects}}) {
        $check = $_;
        # Skip the global section
        if ($check eq 'global') { next; }
        print "Facts for $check:\n";
        # Make sure config is valid
        if (validate_config($check) ne 'valid') {
          print "Error: Invalid configuration. Perhaps try $full_name -c validate -n $check\n";
        } else {
          get_facts($check);
        }
        print "\n";
      }
    }
  }

  case 'validate' {
    # Check if there is a check name to validate. If there is not one all configs should be validated.
    if ($check) {
      print "Validating configuration for check $check: ";
      if (validate_config($check) ne 'valid') {
        print "Invalid\n";
        print validate_config($check);
      } else {
        print "Valid\n";
      }
    } else {
      # Get a list of sections and loop over them
      foreach (@{$cfg->{mysects}}) {
        $check = $_;
        # Skip the global section
        if ($check eq 'global') { next; }
        # Validate each section
        print "Validating configuration for check $check: ";
        if (validate_config($check) ne 'valid') {
          print "Invalid\n";
          print validate_config($check);
        } else {
          print "Valid\n";
        }
      }
    }
  }

  case 'status' {
    # Check if there is a service name. If not all show status for all services
    if ($check) {
      # Make sure there is a status file
      $statusfile = "$healthdir$check";
      if (! -f $statusfile) {
        print "NO STATUS FILE FOR $check - PERHAPS IT HAS NOT RUN YET\n";
      } else {
        print "STATUS FOR $check:\n";
        open(STATUS, $statusfile);
        while (<STATUS>) {
          print;
        }
        close(STATUS);
      }
    } else {
      # Get a list of sections and loop over them
      foreach (@{$cfg->{mysects}}) {
        $check = $_;
        # Skip the global section
        if ($check eq 'global') { next; }
        # Make sure there is a status file
        $statusfile = "$healthdir$check";
        if (! -f $statusfile) {
          print "NO STATUS FILE FOR $check - PERHAPS IT HAS NOT RUN YET\n";
        } else {
          print "STATUS FOR $check:\n";
          open(STATUS, $statusfile);
          while (<STATUS>) {
            print;
          }
          close(STATUS);
        }
        print "\n";
      }
    }
  }

}

########## Begin Subs ##########

# Sub to initialise the script
sub init {
  my $errors = undef;

  # Check that the configuration file exists
  if (! $config) { $errors .= "No configuration file was specified\n" }
  elsif (! -f $config) { $errors .= "Error: The configuration file specified does not exist: $config\n"; }

  # Make sure that a valid command was given
  my %commands = map { $_ => 1 } @commands;
  if (! exists($commands{$command})) { $errors .= "Error: An invalid command was provided: $command\n"; }

  # If the script is to announce routes, validate there was a check name provided
  if ($command eq 'announce' && ! $check) { $errors .= "Error: No check name was specified\n"; }

  # Verify that the healthcheck directory exists
  if (! -d $healthdir) { $errors .= "Error: The directory $healthdir does not exist\n"; }
  elsif (! -w $healthdir) { $errors .= "Error: The directory $healthdir is not writable\n"; }

  # Check to see if any errors were returned. If they were, print help.
  if ($errors) { print_help($errors); }
}

# Sub to get facts about a service
sub get_facts {
  my $check_name = shift;

  print " - Service Name: $check_name\n";
  print " - Check Command: " . get_value('command', $check_name) . "\n";
  print " - Check Interval: " . get_value('interval', $check_name) . "\n";
  print " - Check Timeout: " . get_value('timeout', $check_name) . "\n";
  print " - Disable File: " . get_value('disable', $check_name) . "\n";
  print " - Service Rise: " . get_value('rise', $check_name) . "\n";
  print " - Service Fall: " . get_value('fall', $check_name) . "\n";
  print " - Service Log: " . get_value('logfile', $check_name) . "\n";
  print " - Debug Log: " . get_value('debug', $check_name) . "\n";
  print " - Log Check Output: " . get_value('logcheck', $check_name) . "\n";
  print " - Route Metric: " . get_value('metric', $check_name) . "\n";
  print " - Route Nexthop: " . get_value('nexthop', $check_name) . "\n";
  print " - Announce IP's:\n";
  my @ips = get_value('ip', $check_name);
  foreach (@ips) {
    print "   - $_\n";
  }
}

# Sub to run check commands
sub run_announce {

  # Check if the service has been disabled
  my $service_disabled;
  if (-f get_value('disable')) {
    $service_disabled = 'yes';
    # Set the process status
    proc_status('DISABLED');
  } else {
    $service_disabled = 'no';
    # Set the process status
    proc_status('INIT');
  }
  
  # Set the service state to down initially
  $service_state = 'down';
  
  # Get a list of service IP's and put in array
  @service_ips = get_value('ip');
  
  # Get the metric to announce
  $service_metric = get_value('metric');
  
  # Set the rise/fall values initially
  my $service_rise = 0;
  my $service_fall = 0;
  
  # Get the log path
  my $log_path = get_value('logfile');
  
  # Get the debug option
  my $service_debug = get_value('debug');
  
  # Last result variable
  my $last_result = undef;
  
  # Get the next hop address
  $service_nexthop = get_value('nexthop');

  # Get the current hash of the config file to check for changes
  my $config_md5 = file_md5_hex($config);

  # Config is valid
  my $config_valid = 'valid';
  
  # Start loop
  while (1) {
  
    # Set start time
    my $start = time();
  
    $logger->debug("$check: Check start");
  
    # Check the hash of the config file. If it has changed since the last run, re-read the config to make sure that we use the correct values.
    my $new_config_md5 = file_md5_hex($config);
    if ($new_config_md5 ne $config_md5) {
      # File has changed, validate config
      $logger->debug("$check: Configuration file has changed since last check, validating config");
      $config_valid = validate_config($check);
      if ($config_valid ne 'valid') {
        $logger->error("$check: Configuration file is not valid. Not reloading any changes. Error: $config_valid");
      } else {
        # Re-read config
        $cfg->ReadConfig;
  
        # Check the log path is still the same
        if (get_value('logfile') ne $log_path || get_value('debug') ne $service_debug) {
          # Restart logger due to config change
          $log_path = get_value('logfile');
          $service_debug = get_value('debug');
          $logger = start_log();
        }
  
        # Check that the list of IP's and the metric is still the same. If the list of IP's has been changed, withdraw all old routes and announce new ones. This should only be done if the routes are CURRENTLY announced.
        if ($service_state ne 'down') {
          my @new_service_ips = get_value('ip');
          if (array_diff(@new_service_ips, @service_ips)) {
            my $new_ips_csv = join(',', @new_service_ips);
            my $old_ips_csv = join(',', @service_ips);
            $logger->debug("$check: IP list changed. Old IP's: $old_ips_csv. New IP's: $new_ips_csv.");
            $logger->info("$check: IP list has changed. Withdrawing and announcing routes");
            withdraw_ips();
            @service_ips = @new_service_ips;
            announce_ips();
          } elsif ($service_metric ne get_value('metric')) {
            $logger->info("$check: Metric for routes has changed. Withdrawing and announcing routes");
            withdraw_ips();
            $service_metric = get_value('metric');
            announce_ips();
          } elsif ($service_nexthop ne get_value('nexthop')) {
            $logger->info("$check: Nexthop for routes has changed. Withdrawing and announcing routes");
            withdraw_ips();
            $service_nexthop = get_value('nexthop');
            announce_ips();
          }
        } else {
          @service_ips = get_value('ip');
          $service_metric = get_value('metric');
        }
  
        $logger->info("$check: Configuration file has been reloaded");
      }
      # Update hash for the config file.
      $config_md5 = $new_config_md5;
    }
  
    # Check if the service has been disabled.
    if (-f get_value('disable')) {
      # Check if this is a state change
      if ($service_disabled ne 'yes') {
        # Disabled file has been created since last check. First, check to see if the service is currently up. If the services is up, withdraw the routes.
        $logger->info("$check: Service has been disabled by file check. No further service checks will run until this is removed.");
        if ($service_state eq 'up') {
          $logger->debug("$check: Withdrawing IP's and setting service to down due to service being disabled");
          withdraw_ips();
          $service_state = 'down';
        }
        $service_disabled = 'yes';
        # Set the process status
        proc_status('DISABLED');
      }
    } else {
      # Service shouldn't be disabled. Check to see if it was previously
      if ($service_disabled eq 'yes') {
        $logger->info("$check: Service was previously disabled by file check. Setting back to enabled. Service checks need to pass before routes are announced.");
        $service_disabled = 'no';
        # Ensure that service state is down to reset all counters
        $service_state = 'down';
        # Set the process status
        proc_status('INIT');
      }
    }
  
    # Only run checks if the service is not disabled
    if ($service_disabled eq 'no') {
      # Run the check
      my $result = run_check();
  
      # Check if $last_result is defined. If not, define it.
      if (! $last_result) {
        $last_result = $result;
      } else {
        # Compare last_result to the result.
        if ($last_result ne $result) {
  
          # If the last result was != 0 (fail) but the current result is 0 (success), reset the fall counter
          # The process name needs to be updated otherwise it will still be in the falling state when checking the process list
          if ($last_result ne 0 && $result eq 0) {
            $service_fall = 0;
            proc_status('UP');
          }
  
          # If the last result was 0 (success) but the current result is != 0 (fail), reset the rise counter
          # The process name needs to be updated otherwise it will still be in the rising state when checking the process list
          if ($last_result eq 0 && $result ne 0) {
            $service_rise = 0;
            proc_status('DOWN');
          }
  
        }
  
        # Store the last result
        $last_result = $result;
      }
  
      # Check if the service check returned 0 (success)
      if ($result eq 0) {
  
        # Check if the service is currently marked down. If so, increment $service_rise.
        if ($service_state eq 'down') {
          $service_rise++;
          # Check if the value of $service_rise is high enough to mark the service as up
          if ($service_rise >= get_value('rise')) {
            $logger->info("$check: Last check succeeded. Service has met the number of success checks required, marking as up and announcing IP's");
            # Service should be marked as up.
            $service_state = 'up';
            # Announce routes
            announce_ips();
            # Reset the $service_rise value
            $service_rise = 0;
            # Set the process status
            proc_status('UP');
          } else {
            my $service_rise_left = get_value('rise') - $service_rise;
            $logger->info("$check: Last check succeeded. Service needs $service_rise_left checks to succeed before it is active");
            # Set the process status
            proc_status("DOWN | RISING $service_rise/".get_value('rise'));
          }
        }
  
      } else {
  
        # The service is down, check to see if the service is up. If so, increment $service_fall.
        if ($service_state eq 'up') {
          $service_fall++;
          # Check if the value of $service_fall is high enough to mark the service as down
          if ($service_fall >= get_value('fall')) {
            $logger->info("$check: Last check failed. Service has met the number of failure checks required, marking service as down and withdrawing IP's");
            # Service should be marked as down
            $service_state = 'down';
            # Withdraw routes
            withdraw_ips();
            # Reset the $service_fall value
            $service_fall = 0;
            # Set the process status
            proc_status('DOWN');
          } else {
            my $service_fall_left = get_value('fall') - $service_fall;
            $logger->info("$check: Last check failed. Service needs $service_fall_left checks to fail before it is down");
            # Set the process status
            proc_status("UP | FALLING $service_fall/".get_value('fall'));
          }
        }
  
      }
    }
  
    # Get the check interval
    my $interval = get_value('interval');
  
    # Check how long this check took, sleep for the appropriate amount of time to start next check
    my $end = time();
    my $runtime = $end - $start;
    my $sleeptime = $interval - $runtime;
    # Minimum sleep period is 1 second to prevent a very tight loop
    if ($sleeptime lt 0) {
      $sleeptime = 1;
    }
    $logger->debug("$check: Check complete. Sleeping $sleeptime seconds before next check");
    sleep $sleeptime;
  
  }

}

# Sub to validate config file for a section
sub validate_config {
  my $section = shift;
  my $errors = undef;

  # Ensure that there is a section for global config
  if (! $cfg->SectionExists('global') ) { return "No configuration for the global section\n"; }

  # Ensure that there is a section for this config name
  if (! $cfg->SectionExists($section) ) { return "No configuration for the $section section\n"; }

  # Ensure there is a log file
  if (! get_value('logfile',$section)) { $errors .= "  - No log file specified\n"; }

  # Ensure there is a metric set and it is valid
  if (! get_value('metric',$section)) { $errors .= "  - No metric specified\n"; }
  elsif (! looks_like_number(get_value('metric',$section))) { $errors .= "  - Metric specified is not a number\n"; }
  elsif (get_value('metric',$section) < 1 || get_value('metric',$section) > 1000) { $errors .= "  - Metric specified must be between 1 and 1000\n"; }

  # Ensure there is a check interval set and it is valid
  if (! get_value('interval',$section)) { $errors .= "  - No check interval specified\n"; }
  elsif (! looks_like_number(get_value('interval',$section))) { $errors .= "  - Check interval specified is not a number\n"; }

  # Ensure there is a check timeout set
  if (! get_value('timeout',$section)) { $errors .= "  - No timeout value specified\n"; }
  elsif (! looks_like_number(get_value('timeout',$section))) { $errors .= "  - Timeout specified is not a number\n"; }

  # Ensure that the check timeout is less than the check interval
  if (get_value('timeout',$section) >= get_value('interval',$section)) { $errors .= "  - The timeout specified is larger than the check interval\n"; }

  # Ensure that there is a rise value set and it is valid
  if (! get_value('rise',$section)) { $errors .= "  - No rise value specified\n"; }
  elsif (! looks_like_number(get_value('rise',$section))) { $errors .= "  - Rise value specified is not a number\n"; }

  # Ensure that there is a fall value set and it is valid
  if (! get_value('fall',$section)) { $errors .= "  - No fall value specified\n"; }
  elsif (! looks_like_number(get_value('fall',$section))) { $errors .= "  - Fall value specified is not a number\n"; }

  # Ensure there is a logcheck value
  if (! get_value('logcheck',$section)) { $errors .= "  - No logcheck value specified\n"; }
  elsif (get_value('logcheck',$section) ne 'yes' && get_value('logcheck',$section) ne 'no') { $errors .= "  - Logcheck value must be yes or no\n"; }

  # Ensure there is a logcheck value
  if (! get_value('debug',$section)) { $errors .= "  - No debug value specified\n"; }
  elsif (get_value('debug',$section) ne 'yes' && get_value('debug',$section) ne 'no') { $errors .= "  - Debug value must be yes or no\n"; }

  # Ensure there is a check command
  if (! get_value('command',$section)) { $errors .= "  - No check command specified\n"; } 

  # Next hop IP
  my $nexthop_family;
  if (! get_value('nexthop',$section)) { $errors .= "  - Next hop IP address not supplied\n"; }
  else {
    my $nexthop = get_value('nexthop',$section);
    # Ensure next hop IP is valid
    if (is_ipv4($nexthop)) {
      $nexthop_family = '4';
    } elsif (is_ipv6($nexthop)) {
      $nexthop_family = '6';
    } else {
      $errors .= "  - Next hop IP address not valid. It should be an IPv4 or IPv6 address.\n";
    }
  }

  # Ensure there is at least one IP address supplied
  if (! get_value('ip',$section)) { $errors .= "  - No IP addresses to advertise\n"; }
  else {
    # We can't validate the IP's unless $nexthop_family has been set.
    if (! $nexthop_family) { $errors .= "  - IP address validation skipped due to nexthop configuration error\n"; }
    else {
      # Ensure that the IP addresses are in a valid and that they are in the correct address family.
      my @ips = get_value('ip',$section);
      foreach my $ip (@ips) {
        # If the IP's are not in the format x.x.x.x/x or ::1/x, validate them
        if ($ip !~ m/\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\/\d{1,2}/ && $ip !~ m/[A-Za-z0-9:]+\/\d{1,3}/) {
          if ($nexthop_family eq '4') { if (! is_ipv4($ip)) { $errors .= "  - IP address $ip is not not a valid IPv4 address\n"; } }
          if ($nexthop_family eq '6') { if (! is_ipv6($ip)) { $errors .= "  - IP address $ip is not not a valid IPv6 address\n"; } }
          if (get_value('nexthop',$section) eq $ip) { $errors .= "  - IP address to advertise ($ip) cannot be the same as the nexthop\n"; }
        }
        # The IP's are in the format x.x.x.x/x or ::1/x. Split the string into $address and $mask, then validate those.
        else {
          my ($address, $mask) = split('/', $ip);
          # Validations for IPv4
          if ($nexthop_family eq '4') {
            # Validate mask is between 1 and 32
            if (! looks_like_number($mask) || $mask < 1 || $mask > 32) { $errors .= "  - Netmask for address $ip must be between 1 and 32\n"; }
            if (! is_ipv4($address)) { $errors .= "  - IP address $ip is not a valid IPv4 address\n"; }
            elsif ($mask eq '32' && get_value('nexthop',$section) eq $address) { $errors .= "  - IP address to advertise ($ip) cannot be the same as the nexthop\n"; }
          }
          # Validations for IPv6
          if ($nexthop_family eq '6') {
            # Validate mask is between 1 and 128
            if (! looks_like_number($mask) || $mask < 1 || $mask > 128) { $errors .= "  - Netmask for address $ip must be between 1 and 128\n"; }
            if (! is_ipv6($address)) { $errors .= "  - IP address $ip is not a valid IPv6 address\n"; }
            elsif ($mask eq '128' && get_value('nexthop',$section) eq $address) { $errors .= "  - IP address to advertise ($ip) cannot be the same as the nexthop\n"; }
          }
        }
      }
    }
  }

  # Disable file
  if (! get_value('disable',$section)) { $errors .= "  - No disable file specified\n"; }

  # Ensure that the script can do logging
  my $logfile = get_value('logfile',$section);
  my $logdir = dirname($logfile);
  if (! -d $logdir) {
    mkdir $logdir or $errors .= " - Could not create log directory $logdir: $!\n";
    # This script will probably be running as a different user than it will be with ExaBGP if it is being run on the command line so delete the directory and let ExaBGP create it
    if (-d $logdir && $console_debug) { rmdir $logdir; }
  } else {
    if (-f $logfile && ! -w $logfile) { $errors .= "  - Could not write to log file $logfile\n"; }
    elsif (! -f $logfile) {
      open my $LOGFH, '>', "$logfile" or $errors .= "  - Could not create log file $logfile: $!\n";
      if ($LOGFH) {
        close $LOGFH;
      }
      if (-f $logfile && $console_debug) { unlink $logfile; }
    }
  }

  # Checks complete
  if ($errors) {
    return $errors;
  } else {
    return 'valid';
  }

}

# Sub to get a configuration value.
sub get_value {
  my $key = shift;
  my $section = shift // $check;

  if ($cfg->exists($section, $key)) {
    return $cfg->val($section, $key);
  } elsif ($cfg->exists('global', $key)) {
    return $cfg->val('global', $key);
  } else {
    return undef;
  }
}

# Sub that executes when the script terminates
sub terminate {
  # Cleanup only needs to be done if the script was announcing and running under ExaBGP
  if (! $console_debug && $command eq 'announce') {
    proc_status('TERMINATED');
    $pid->remove();
  }
  exit;
}

# Sub to write out status file
sub update_status_file {
  my $status = shift;

  my $current_time = localtime(time())->strftime('%F %T');

  open STATUSFH, '>', $statusfile;
  print STATUSFH "Service State: $status\n";
  print STATUSFH "Last State Change: $current_time\n";
  print STATUSFH "Nexthop: $service_nexthop\n";
  print STATUSFH "Managed IP's: ";
  foreach my $ip (@service_ips) {
    print STATUSFH "$ip ";
  }
  print STATUSFH "\n";
  close STATUSFH
}

# Sub to handle the process status
sub proc_status {
  my $status = shift;

  # This should only be called in announcement mode when running under exabgp.
  if (! $console_debug && $command eq 'announce') {

    # Set the name that shows in ps
    $0 = "ExaBGP $name: $check $status";

    # Write out status file
    update_status_file($status);
  }
}

# Sub to announce all IP's
sub announce_ips {
  # Ensure the service_state is up before announcing anything
  if ($service_state eq 'up') {
    foreach my $ip (@service_ips) {
      # If there was no mask specified, it will default to /32 for IPv4 or /128 for IPv6
      if ($ip !~ m/\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\/\d{1,2}/ && $ip !~ m/[A-Za-z0-9:]+\/\d{1,3}/) {
        if (is_ipv4($ip)) { $ip = "$ip/32"; }
        if (is_ipv6($ip)) { $ip = "$ip/128"; }
      }
      my $announce = "announce route $ip next-hop $service_nexthop med $service_metric";
      $logger->debug("$check: Send to exabgp: $announce");
      print "$announce\n";
    }
  }
}

# Sub to withdraw all IP's
sub withdraw_ips {
  foreach my $ip (@service_ips) {
    # If there was no mask specified, it will default to /32 for IPv4 or /128 for IPv6
    if ($ip !~ m/\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\/\d{1,2}/ && $ip !~ m/[A-Za-z0-9:]+\/\d{1,3}/) {
      if (is_ipv4($ip)) { $ip = "$ip/32"; }
      if (is_ipv6($ip)) { $ip = "$ip/128"; }
    }
    my $announce = "withdraw route $ip next-hop $service_nexthop med $service_metric";
    $logger->debug("$check: Send to exabgp: $announce");
    print "$announce\n";
  }
}

# Sub to execute check command
sub run_check {
  my $cmd = get_value('command');
  my $timeout = get_value('timeout');

  # Remove quotes from start/end of the command if it is quoted
  if ($cmd =~ /^"/) {
    $cmd =~ s/^"//;
    $cmd =~ s/"$//;
  }

  # Prepend the timeout to the check command
  $cmd = "timeout $timeout $cmd";

  $logger->debug("$check: Attempting to fork and run check command [$cmd]");

  # opening a pipe creates a forked process
  my $pid = open(my $pipe, '-|');
  $logger->error("$check: Cannot fork, service marked down: $!") unless defined $pid;
  return(-1) unless defined $pid;

  if ($pid) {
    my @result = ();
    @result = <$pipe>;
    close($pipe);
    my $exit_code = $?;
    $logger->debug("$check: Executed check command [$cmd]. Return code [$exit_code]");
    if (get_value('logcheck') eq 'yes') {
      $logger->debug("$check: Output from [$cmd]: @result");
    }
    return ($exit_code);
  }

  {
    no warnings;
    open(STDERR, '>&STDOUT');
    ref($cmd) eq 'ARRAY' ? exec(@$cmd) : exec($cmd);
  }
  $logger->error("$check: Cannot exec command [@$cmd]: $!");
  return (-2);
}

# Sub to start logging
sub start_log {
  my $log_path = get_value('logfile');

  my $rootlogger;

  # If this is running with -debug passed to the script, only log to screen.
  if ($console_debug) {
    $rootlogger = 'DEBUG, Screen';
  } else {
    if (get_value('debug') eq 'yes') {
      $rootlogger = 'DEBUG, AppInfo, AppError, AppDebug';
    } else {
      $rootlogger = 'DEBUG, AppInfo, AppError';
    }
  }

  my $log_conf = "
    log4perl.rootLogger                 = $rootlogger

    log4perl.appender.AppInfo              = Log::Dispatch::FileRotate
    log4perl.appender.AppInfo.filename     = $log_path
    log4perl.appender.AppInfo.mode         = append
    log4perl.appender.AppInfo.autoflush    = 1
    log4perl.appender.AppInfo.size         = 10485760
    log4perl.appender.AppInfo.max          = 10
    log4perl.appender.AppInfo.layout       = Log::Log4perl::Layout::PatternLayout
    log4perl.appender.AppInfo.recreate     = 1
    log4perl.appender.AppInfo.Threshold    = INFO
    log4perl.appender.AppInfo.layout.ConversionPattern = %d %P %p %m %n

    log4perl.appender.AppDebug              = Log::Dispatch::FileRotate
    log4perl.appender.AppDebug.filename     = $log_path.debug
    log4perl.appender.AppDebug.mode         = append
    log4perl.appender.AppDebug.autoflush    = 1
    log4perl.appender.AppDebug.size         = 10485760
    log4perl.appender.AppDebug.max          = 10
    log4perl.appender.AppDebug.layout       = Log::Log4perl::Layout::PatternLayout
    log4perl.appender.AppDebug.recreate     = 1
    log4perl.appender.AppDebug.Threshold    = DEBUG
    log4perl.appender.AppDebug.layout.ConversionPattern = %d %P %p %m %n

    log4perl.appender.AppError              = Log::Dispatch::FileRotate
    log4perl.appender.AppError.filename     = $log_path.error
    log4perl.appender.AppError.mode         = append
    log4perl.appender.AppError.autoflush    = 1
    log4perl.appender.AppError.size         = 10485760
    log4perl.appender.AppError.max          = 10
    log4perl.appender.AppError.layout       = Log::Log4perl::Layout::PatternLayout
    log4perl.appender.AppError.recreate     = 1
    log4perl.appender.AppError.Threshold    = ERROR
    log4perl.appender.AppError.layout.ConversionPattern = %d %P %p %m %n

    log4perl.appender.Screen                = Log::Log4perl::Appender::Screen
    log4perl.appender.Screen.stderr         = 0
    log4perl.appender.Screen.layout         = Log::Log4perl::Layout::PatternLayout
    log4perl.appender.Screen.Threshold      = DEBUG
    log4perl.appender.Screen.layout.ConversionPattern = %d %P %p %m %n
  ";
  Log::Log4perl::init(\$log_conf);

  my $logger = Log::Log4perl->get_logger();
  return $logger;
}

# Sub to print out version info
sub print_version {
  print <<EOVERSION
ExaBGP health check script - version $script_version.
See the GitHub page for version history and change log: https://github.com/shthead/exabgp-healthcheck
EOVERSION
  ;exit;
}

# Sub to print usage/config info
sub print_help {
  my ($errors) = @_;
  if ($errors) {
    print $errors;
  }

  print <<EOUSAGE

  This script runs health checks for IP's that are announced via ExaBGP. Complete usage instructions are available
  via the GitHub wiki page here: https://github.com/shthead/exabgp-healthcheck/wiki.

  For more information, updates and to report bugs, see the GitHub project page:
  https://github.com/shthead/exabgp-healthcheck/wiki

  Usage:

    Command Line:
      Run script:
        $full_name -c announce -n myservice -f /etc/exabgp/healthcheck.conf
      Validate config of all services:
        $full_name -c validate
      Validate config of a single service:
        $full_name -c validate -n myservice
      Check status of all services:
        $full_name -c status
      Check status of a single service:
        $full_name -c status -n myservice
      List details of all configured checks:
        $full_name -c list
      List details of a specific check:
        $full_name -c list -n myservice

    Arguments:

      -command  | -c    The command to run. See the above commands for a list.
      -name     | -n    The name of the service to check. Must be present as a section in the configuration file.
                        This argument is REQUIRED for the 'announce' command.
      -config   | -f    The path to the configuration file. Defaults to /etc/exabgp/healthcheck.conf.
      -help     | -h    Print this help message and exit.
      -version  | -v    Print the version and exit.

    Commands:

      announce          Run checks and announce services.
      validate          Validate the configuration file and exit.
      status            Check the status and exit.
      list [Default]    List the details for a check/all checks and exit.

  General Information:

    This healthcheck script will run a check command that is defined in the configuration file. The command that is run
    must return 0 for the service to be up, any other exit code will assume that the service is down. If the service is up
    it will announce a list of IP's to exabgp.

    When testing this script on the command line extra debugging info will be output automatically via the console.

    When the script is running under ExaBGP, you can check the processs list to see the status of the service. The process
    name will be set to the script name with the name of the service check and the current status of the check.

  Links:

    Installation instructions: https://github.com/shthead/exabgp-healthcheck/wiki/Installation
    Configuration instructions: https://github.com/shthead/exabgp-healthcheck/wiki/Configuration-File
    Command line options: https://github.com/shthead/exabgp-healthcheck/wiki/CLI-Usage

EOUSAGE
  ;exit;
}
