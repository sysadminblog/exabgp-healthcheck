# ExaBGP-Healthcheck
ExaBGP healthcheck is a simple Perl script for use with [ExaBGP] which can control the announcing of routes based on the status of health checks. The health checks can be anything you like - the script only cares about the exit code (0 is success, anything else is a failure).

Features:
* IPv4 and IPv6 support
* Configuration file changes are applied automatically, no need to reload/restart services. The configuration file is verified before applying changes, if there are errors the changes will not be applied.
* Health checks can call your own scripts, normal CLI utilities etc.
* Multiple services can be defined with different IP addresses
* Easy monitoring of service status - plain text files contain the current status of services, the image name for the process also has the current status
* Command line options to view the current status, validate config etc.
* Logging (with debug options)

As an example of what this can be used for, see [my blog post].

## Requirements
The following Perl modules are required:
```
Array::Utils
Config::IniFiles
Digest::MD5::File
File::Basename
File::Pid
Getopt::Long
Log::Log4perl
Scalar::Util
Switch
Time::Piece
```
On a minimal Debian install you can install the required Perl modules with this command:
```
apt-get install libconfig-inifiles-perl libdigest-md5-file-perl libfile-pid-perl liblog-log4perl-perl libswitch-perl liblog-dispatch-filerotate-perl libarray-utils-perl
```

## Configuration File
The configuration file must have a `[global]` section present. Services defined will inherit the settings from the `[global]` section - if you want multiple services with different settings, any global settings can be defined per service.

See the sample configuration file included for examples of IPv4 and IPv6 services.

The Perl script will by default expect its configuration file to be in `/etc/exabgp/healthcheck.conf`. If you would like to change that, edit the script and change the line `my $config=` to the appropriate path. By default the script will also write out the current status of all services to files stored in `/var/healthcheck/` - you can override this in the variable `my $healthdir`.

## ExaBGP configuration
To use the script with ExaBGP, define your neighbor as normal in `exabgp.conf`. A process line needs to be added for each service defined in the `healthcheck.conf` file, eg.
```
  process myservice1 {
    run /etc/exabgp/healthcheck.pl -c announce -n myservice1;
  }
  process myservice2 {
    run /etc/exabgp/healthcheck.pl -c announce -n myservice2;
  }
```

For a complete example see the file `exabgp.conf.sample`.

## Command line options
Calling the script with no options will parse the default configuration file and print out a list of currently defined services.

To get the current status of all services use the command `status`: `/etc/exabgp/healthcheck.pl -c status`

To validate the configuration file use the command `validate`: `/etc/exabgp/healthcheck.pl -c validate`

Call the script with `-h` or `-help` to get the printed help version: `/etc/exabgp/healthcheck.pl -h`:
```
  This script runs health checks for IP's that are announced via ExaBGP.

  Usage:

    With ExaBGP:
      process myservice {
        run /etc/exabgp/healthcheck.pl -c announce -n myservice;
      }

    Command Line:
      Run script:
        /etc/exabgp/healthcheck.pl -c announce -n myservice -f /etc/exabgp/healthcheck.conf
      Validate config of all services:
        /etc/exabgp/healthcheck.pl -c validate
      Validate config of a single service:
        /etc/exabgp/healthcheck.pl -c validate -n myservice
      Check status of all services:
        /etc/exabgp/healthcheck.pl -c status
      Check status of a single service:
        /etc/exabgp/healthcheck.pl -c status -n myservice
      List details of all configured checks:
        /etc/exabgp/healthcheck.pl -c list
      List details of a specific check:
        /etc/exabgp/healthcheck.pl -c list -n myservice

    Commands:

      announce          Run checks and announce services.
      validate          Validate the configuration file and exit.
      status            Check the status and exit.
      list [Default]    List the details for a check/all checks and exit.

    Arguments:

      -command  | -c    The command to run. See the above commands for a list.
      -name     | -n    The name of the service to check. Must be present as a section in the configuration file.
                        This argument is REQUIRED for the 'announce' command.
      -config   | -f    The path to the configuration file. Defaults to /etc/exabgp/healthcheck.conf.
      -help     | -h    Print this help message and exit.

  General Information:

    This healthcheck script will run a check command that is defined in the configuration file. The command that is run
    must return 0 for the service to be up, any other exit code will assume that the service is down. If the service is up
    it will announce a list of IP's to exabgp.

    When testing this script on the command line extra debugging info will be output.

    When the script is running under ExaBGP, you can check the processs list of the status of the service. The process name
    will be set to the script name with the name of the service check and the current status of the check.

  Requirements:

    When this script is running as an ExaBGP process, it required write access to the following:

      - /var/healthcheck: This directory stores the current status for the configured healthchecks.
      - logfile specific in configured: The directory (used for locks, creating new logs/rotating logs) and file

  Configuration File:

    The configuraiton file is a text file which contains a list of options. The file must contain at least two sections, a [global]
    section and the [checkname] section.

    The [global] section applies to all checks unless there is an override in the specific check section.

    The command that is used to check the service expects a return value of 0 if the service is up. Any other value considers the service down.

    The configuration file is checked frequently for changes, any changes made do NOT require a restart of any service to take effect.

  Configuration Example:
    [global]

    # Wait N seconds between health checks
    interval=3
    # Wait N seconds for the check command to execute. The timeout must be lower than the interval.
    timeout=2
    # Metric to set. Must be between 1 and 1000.
    metric=150
    # Check N times before considering the service up
    rise=2
    # Check N times before considering the service down
    fall=1
    # Log location. Errors will be logged to logfile.err and debug to logfile.debug (if enabled)
    logfile=/var/log/healthcheck/healthcheck
    # Log the output of the check command to the debug log. Requires debug=yes
    logcheck=no
    # Enable the debug log
    debug=no

    [myservice]

    # The command to use for health check
    command="/usr/local/scripts/healthcheck.sh"
    # IP addresses to announce
    ip=10.1.1.1/32
    ip=10.1.1.2/32
    # The next hop IP address. This will usually be this server.
    nexthop=192.168.1.1
    # If FILE exists, the service is considered disabled
    disable=/etc/exabgp/healthcheck_myservice.disable
```

[//]: # (Links to other sites/projects)

   [ExaBGP]: <https://github.com/Exa-Networks/exabgp>
   [my blog post]: <https://sysadminblog.net/2016/04/exabgp-bgp-routing-health-checks/>
