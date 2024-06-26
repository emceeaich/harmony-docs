#!/usr/bin/env perl
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

# testserver.pl is invoked with the baseurl of the Bugzilla installation
# as its only argument.  It attempts to troubleshoot as many installation
# issues as possible.

use 5.10.1;
use strict;
use warnings;

use lib qw(. lib local/lib/perl5);

use Bugzilla;
use Bugzilla::Constants;

use Socket;

my $datadir = bz_locations()->{'datadir'};

eval "require LWP; require LWP::UserAgent;";
my $lwp = $@ ? 0 : 1;
eval "require LWP::Protocol::https;";
my $lwpssl = $@ ? 0 : 1;

if ((@ARGV < 1) || (@ARGV > 2) || ($ARGV[0] !~ /^https?:/i) || (defined($ARGV[1]) && $ARGV[1] ne '--self-signed')) {
  print "Usage: $0 <URL to this Bugzilla installation> [--self-signed]\n";
  print "e.g.:  $0 http://www.mycompany.com/bugzilla\n";
  print "\n";
  print "Pass --self-signed to prevent hostname verification of SSL certificates if needed.";
  exit(1);
}
my $selfsigned = defined($ARGV[1]) ? 1 : 0;

# Try to determine the GID used by the web server.
my @pscmds
  = ('ps -eo comm,gid', 'ps -acxo command,gid', 'ps -acxo command,rgid');
my $sgid = 0;
if (!ON_WINDOWS) {
  foreach my $pscmd (@pscmds) {
    open PH, '-|', "$pscmd 2>/dev/null";
    while (my $line = <PH>) {
      if ($line =~ /^(?:\S*\/)?(?:httpd|apache)2?\s+(\d+)$/) {
        $sgid = $1 if $1 > $sgid;
      }
    }
    close(PH);
  }
}

# Determine the numeric GID of $webservergroup
my $webgroupnum    = 0;
my $webservergroup = Bugzilla->localconfig->webservergroup;
if ($webservergroup =~ /^(\d+)$/) {
  $webgroupnum = $1;
}
else {
  eval { $webgroupnum = (getgrnam $webservergroup) || 0; };
}

# Check $webservergroup against the server's GID
if ($sgid > 0) {
  if ($webservergroup eq "") {
    print "WARNING \$webservergroup is set to an empty string.
That is a very insecure practice. Please refer to the
Bugzilla documentation.\n";
  }
  elsif ($webgroupnum == $sgid || Bugzilla->localconfig->use_suexec) {
    print "TEST-OK Webserver is running under group id in \$webservergroup.\n";
  }
  else {
    print
      "TEST-WARNING Webserver is running under group id not matching \$webservergroup.
This if the tests below fail, this is probably the problem.
Please refer to the web server configuration section of the Bugzilla guide.
If you are using virtual hosts or suexec, this warning may not apply.\n";
  }
}
elsif (!ON_WINDOWS) {
  print "TEST-WARNING Failed to find the GID for the 'httpd' process, unable
to validate webservergroup.\n";
}


# Try to fetch a static file (padlock.png)
$ARGV[0] =~ s/\/$//;
my $url = $ARGV[0] . "/images/padlock.png";
if (fetch($url)) {
  print "TEST-OK Got padlock picture.\n";
}
else {
  print "TEST-FAILED Fetch of images/padlock.png failed
Your web server could not fetch $url.
Check your web server configuration and try again.\n";
  exit(1);
}

# Try to execute a cgi script
my $response = fetch($ARGV[0] . "/testagent.cgi");
if ($response =~ /^OK (.*)$/) {
  print "TEST-OK Webserver is executing CGIs via $1.\n";
}
elsif ($response =~ /^#!/) {
  print "TEST-FAILED Webserver is fetching rather than executing CGI files.
Check the AddHandler statement in your httpd.conf file.\n";
  exit(1);
}
else {
  print "TEST-FAILED Webserver is not executing CGI files.\n";
}

# Make sure that the web server is honoring .htaccess files
my $localconfig = bz_locations()->{'localconfig'};
$localconfig =~ s~^\./~~;
$url      = $ARGV[0] . "/$localconfig";
$response = fetch($url);
if ($response) {
  print "TEST-FAILED Webserver is permitting fetch of $url.
This is a serious security problem.
Check your web server configuration.\n";
  exit(1);
}
else {
  print "TEST-OK Webserver is preventing fetch of $url.\n";
}

# Test chart generation
eval 'use GD';
if ($@ eq '') {
  undef $/;

  # Ensure major versions of GD and libgd match
  # Windows's GD module include libgd.dll, guaranteed to match
  if (!ON_WINDOWS) {
    my $gdlib = `gdlib-config --version 2>&1` || "";
    $gdlib =~ s/\n$//;
    if (!$gdlib) {
      print "TEST-WARNING Failed to run gdlib-config; can't compare "
        . "GD versions.\n";
    }
    else {
      my $gd = $GD::VERSION;

      my $verstring = "GD version $gd, libgd version $gdlib";

      $gdlib =~ s/^([^\.]+)\..*/$1/;
      $gd =~ s/^([^\.]+)\..*/$1/;

      if ($gdlib == $gd) {
        print "TEST-OK $verstring; Major versions match.\n";
      }
      else {
        print "TEST-FAILED $verstring; Major versions do not match.\n";
      }
    }
  }

  # Test GD
  eval {
    my $image = new GD::Image(100, 100);
    my $black = $image->colorAllocate(0,   0,   0);
    my $white = $image->colorAllocate(255, 255, 255);
    my $red   = $image->colorAllocate(255, 0,   0);
    my $blue  = $image->colorAllocate(0,   0,   255);
    $image->transparent($white);
    $image->rectangle(0, 0, 99, 99, $black);
    $image->arc(50, 50, 95, 75, 0, 360, $blue);
    $image->fill(50, 50, $red);

    if ($image->can('png')) {
      create_file("$datadir/testgd-local.png", $image->png);
      check_image("$datadir/testgd-local.png", 'GD');
    }
    else {
      print "TEST-FAILED GD doesn't support PNG generation.\n";
    }
  };
  if ($@ ne '') {
    print "TEST-FAILED GD returned: $@\n";
  }

  # Test Chart
  eval 'use Chart::Lines';
  if ($@) {
    print "TEST-FAILED Chart::Lines is not installed.\n";
  }
  else {
    eval {
      my $chart = Chart::Lines->new(400, 400);

      $chart->add_pt('foo', 30, 25);
      $chart->add_pt('bar', 16, 32);

      $chart->png("$datadir/testchart-local.png");
      check_image("$datadir/testchart-local.png", "Chart");
    };
    if ($@ ne '') {
      print "TEST-FAILED Chart returned: $@\n";
    }
  }

  eval 'use Template::Plugin::GD::Image';
  if ($@) {
    print "TEST-FAILED Template::Plugin::GD is not installed.\n";
  }
  else {
    print "TEST-OK Template::Plugin::GD is installed.\n";
  }
}

sub fetch {
  my $url = shift;
  my $rtn;
  if ($lwp) {
    if ($url =~ /^https:/i && !$lwpssl) {
      die ("You need LWP::Protocol::https installed to use https with testserver.pl");
    } else {
      my $req = HTTP::Request->new(GET => $url);
      my $ua  = LWP::UserAgent->new;
      $ua->ssl_opts( verify_hostname => 0 ) if $selfsigned;
      my $res = $ua->request($req);
      if (!$res->is_success) {
        my $errstr = $res->status_line;
        print $errstr . "\n";
        if ($errstr =~ m/certificate/) {
          say "Try passing --self-signed to skip certificate checks."
        }
      }
      $rtn = ($res->is_success ? $res->content : undef);
    }
  }
  elsif ($url =~ /^https:/i) {
    die("You need LWP (and LWP::Protocol::https, for LWP 6.02 or newer) installed to use https with testserver.pl");
  }
  else {
    my ($host, $port, $file) = ('', 80, '');
    if ($url =~ m#^http://([^:]+):(\d+)(/.*)#i) {
      ($host, $port, $file) = ($1, $2, $3);
    }
    elsif ($url =~ m#^http://([^/]+)(/.*)#i) {
      ($host, $file) = ($1, $2);
    }
    else {
      die("Cannot parse url");
    }

    my $proto = getprotobyname('tcp');
    socket(SOCK, PF_INET, SOCK_STREAM, $proto);
    my $sin = sockaddr_in($port, inet_aton($host));
    if (connect(SOCK, $sin)) {
      binmode SOCK;
      select((select(SOCK), $| = 1)[0]);

      # get content
      print SOCK "GET $file HTTP/1.0\015\012host: $host:$port\015\012\015\012";
      my $header = '';
      while (defined(my $line = <SOCK>)) {
        last if $line eq "\015\012";
        $header .= $line;
      }
      my $content = '';
      while (defined(my $line = <SOCK>)) {
        $content .= $line;
      }

      my ($status) = $header =~ m#^HTTP/\d+\.\d+ (\d+)#;
      $rtn = (($status =~ /^2\d\d/) ? $content : undef);
    }
  }
  return ($rtn);
}

sub check_image {
  my ($local_file, $library) = @_;
  my $filedata = read_file($local_file);
  if ($filedata =~ /^\x89\x50\x4E\x47\x0D\x0A\x1A\x0A/) {
    print "TEST-OK $library library generated a good PNG image.\n";
    unlink $local_file;
  }
  else {
    print "TEST-WARNING $library library did not generate a good PNG.\n";
  }
}

sub create_file {
  my ($filename, $content) = @_;
  open(FH, ">", $filename) or die "Failed to create $filename: $!\n";
  binmode FH;
  print FH $content;
  close FH;
}

sub read_file {
  my ($filename) = @_;
  open(FH, "<", $filename) or die "Failed to open $filename: $!\n";
  binmode FH;
  my $content = <FH>;
  close FH;
  return $content;
}
