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
Config::IniFiles;
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
apt-get install libconfig-inifiles-perl libdigest-md5-file-perl libfile-pid-perl liblog-log4perl-perl libswitch-perl liblog-dispatch-filerotate-perl
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

Call the script with `-h` or `-help` to get the printed help version: `/etc/exabgp/healthcheck.pl -h`

To get the current status of all services use the command `status`: `/etc/exabgp/healthcheck.pl -c status`

To validate the configuration file use the command `validate`: `/etc/exabgp/healthcheck.pl -c validate`

There are many more options, run the script with the `help` switch for more.

[//]: # (Links to other sites/projects)

   [ExaBGP]: <https://github.com/Exa-Networks/exabgp>
   [my blog post]: <https://sysadminblog.net/2016/04/exabgp-bgp-routing-health-checks/>
