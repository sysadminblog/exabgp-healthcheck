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

All documentation for this project is available in the [Wiki], I recommend having a quick read through.

## System Requirements
An installation of Perl is required with the following modules:
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

For more information, see the [System Requirements wiki page].

## Installation
Copy healthcheck.pl to the ExaBGP directory, usually /etc/exabgp. Create a configuration file for the health check script in /etc/exabgp/healthcheck.conf.

Configure ExaBGP as normal and add the appropriate process for the Neighbor, eg.:
```
      process myservice {
        run /etc/exabgp/healthcheck.pl -c announce -n myservice;
      }
```

For complete instructions, see the [Installation wiki page].

## Configuration File
A sample configuration file is included for both ExaBGP and healthcheck.pl.

For complete configuration options, see the [Configuration File wiki page].

## Command Line Usage
For a list of available options, call the script with the '-help' switch:
```
/etc/exabgp/healthcheck.pl -help
```

For full instuctions, see the [CLI Usage wiki page].

[//]: # (Links to other sites/projects)

  [ExaBGP]: <https://github.com/Exa-Networks/exabgp>
  [my blog post]: <https://sysadminblog.net/2016/04/exabgp-bgp-routing-health-checks/>
  [Wiki]: <https://github.com/shthead/exabgp-healthcheck/wiki/>
  [System Requirements wiki page]: <https://github.com/shthead/exabgp-healthcheck/wiki/System-Requirements>
  [Installation wiki page]: <https://github.com/shthead/exabgp-healthcheck/wiki/Installation>
  [quick start page]: <https://github.com/shthead/exabgp-healthcheck/wiki/Quick-Start>
  [Configuration File wiki page]: <https://github.com/shthead/exabgp-healthcheck/wiki/Configuration-File>
  [CLI Usage wiki page]: <https://github.com/shthead/exabgp-healthcheck/wiki/CLI-Usage>
