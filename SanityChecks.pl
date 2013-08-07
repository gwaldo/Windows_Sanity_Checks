#! /usr/bin/env perl
# written on perl 5, version 14, subversion 2 (v5.14.2) built for MSWin32-x64-multi-thread

# Basic monitoring check of vital parts

use strict;
use warnings;

use POSIX qw(strftime);
use Win32::OLE('in');
use Net::Ping;
#use Term::ReadKey;
use LWP::UserAgent;
use HTTP::Request;
use Digest::MD5;

# To break out subs to separate files, see http://stackoverflow.com/a/1712165/428779

use constant wbemFlagReturnImmediately => 0x10;
use constant wbemFlagForwardOnly => 0x20;


##Allow for credentials to be input quietly
# my $arg = @ARGV;
##TODO: check for "--quiet" argument
# my $password = @ARGV[0];
# if ($arg < 1) {
	# ReadMode('noecho');
	# print "Password:\n";
	# $password = ReadLine(0);
	# chomp $password;
# }

# array of servers
# in production, delete "localhost );" and uncomment the following lines
my @servers = qw (	localhost );
#					web1.domain.local
#					web2.domain.local
#					sql1.domain.local
#					sql2.domain.local
#					sbs.domain.local
#					vcenter.domain.local
#				);

my $message = '';	# string to hold results
my $objWMI;			# object to hold each servers' WMI connection
my $errors = 0;		# scalar to hold error state

################################################################################

### FUNCTIONS ###

sub fnDateTime
{
	strftime "%Y%m%d_%H%M%S", localtime;
}

sub isNotPingable
{
	my $ping = Net::Ping->new() or die "Can't Create Ping Object.  Something is very wrong...\n";
	my $server = $_[0];
	#print "pinging $server\n";
	if ($ping->ping($server)) {
		#return 0; #as in "true", not "error"
	}# else {
		#return 1;
	#}
}

sub diskUtil
{
	my $diskFree		= $_[0];
	my $diskCapacity	= $_[1];
	my $diskUsed		= ($diskCapacity - $diskFree);
	#print "$diskUtil\% utilized\n";
	return(my $diskUtil	= substr((($diskUsed / $diskCapacity) * 100), 0, 5));
}

sub diskCheck
{
	# DriveType = '3' means "Local Hard Disk"
	my $colDisk = $objWMI->ExecQuery("SELECT 
		DeviceID,DriveType,FreeSpace,Size FROM 
		Win32_LogicalDisk WHERE DriveType = '3'", "WQL",
		wbemFlagReturnImmediately | wbemFlagForwardOnly);
	foreach my $objDisk (in $colDisk)
	{
		my $util = diskUtil($objDisk->{FreeSpace}, $objDisk->{Size});
		#print "$server\\$objDisk->{DeviceID} is $util\% full.\n";
		if ($util >= 75) {
			$message = $message
				. "\t$objDisk->{DeviceID} is $util\% full.\n";
			$errors++;
		}
	}
}

sub serviceQuery
{
	my $service = $_[0];
	my $query = "SELECT DisplayName, Name, StartMode, Started, State, Status, ExitCode FROM 
		Win32_Service WHERE Name = '" . $service . "'";
	my $colService = $objWMI->ExecQuery($query, "WQL",
		wbemFlagReturnImmediately | wbemFlagForwardOnly);
	foreach my $objService (in $colService) {
		my $svcDisplayName	= $objService->{DisplayName};
		my $svcName			= $objService->{Name};
		my $svcStartMode	= $objService->{StartMode};
		my $svcStarted		= $objService->{Started};
		my $svcState		= $objService->{State};
		my $svcExitCode		= $objService->{ExitCode};
		
		if (($svcStartMode eq "Auto") && ($svcState ne "Running")) {
			#print "$svcDisplayName Service is $svcState.  Last exist code is $svcExitCode.\n";
			$message = $message . "\t$svcDisplayName Service is $svcState.  Last exist code is $svcExitCode.\n";
			$errors++;
		}
	}
}

sub siteCheck
{
	my $site = $_[0];
	my $userAgent = LWP::UserAgent->new( 'ssl_opts' => {'verify_hostname' => 0} );
	$userAgent->timeout(10);
	my $response = $userAgent->get("$site");

	if ($response->is_success) {
		#print $response->content;  # or whatever
		return 0;  # or whatever
	} else {
		$message = $message . $response->status_line . "\n";
		$errors++;
	}
}

sub md5sum
{
	my $file = shift;
	my $digest = "";
	eval{
		open(FILE, $file) or die "[ERROR] md5sum: Can't find file $file\n";
		my $ctx = Digest::MD5->new;
		$ctx->addfile(*FILE);
		$digest = $ctx->hexdigest;
		close(FILE);
	};
	if($@) {
		print $@;
		return "";
	}
	return $digest;
}

sub parityCheck
{
	# Ensure that files that we care about are the same on all concerned servers
	my $path = "D\$\\Path\\to\\domain.com\\bin\\";
	
	if ( md5sum("\\\\web1\\$path\\deployed_file.dll") ne
		md5sum("\\\\web2\\$path\\deployed_file.dll")) {
			#print "They don't match!\n";
		$message = $message . "\ndeployed_file.dll does not match.\n";
		$errors++;
	}
	
	if ( md5sum("\\\\web1\\$path\\other_file.pdb") ne 
		md5sum("\\\\web2\\$path\\other_file.pdb")) {
			#print "They don't match!\n";
		$message = $message . "other_file.pdb does not match.\n";
		$errors++;
	}

}

sub fnEmail {
	use MIME::Lite;

	my $msg;
	my $msgBody = $_[0];

	$msg = MIME::Lite->new(	From	=> 'mailer@domain.com',
							To		=> 'recipient@domain.com',
							Subject	=> 'Validations Failure',
							Type	=> 'multipart/mixed');

	$msg->attach(	Type => 'TEXT',
					Data => $msgBody);
	$msg->send('smtp', 'mail.domain.local');
}



################################################################################

my $timestamp = fnDateTime();

foreach my $server (@servers) {
	$message = $message . "\n" . $server . "\'s notifications:\n";
	# ping server
	if (isNotPingable($server)) {
		#print "$server is not pingable.\n";
		$message = $message . "\t$server is not pingable.\n";
		$errors++;
		next;
	} else {
		# Carry On
		#print "$server is pingable.\n";
		
		#---Set our Namespaces---
		$objWMI = Win32::OLE->GetObject
			("winmgmts:\\\\$server\\root\\CIMV2");
		if (!$objWMI) {        # Thanks, Juan...
			$message = $message . "\tWMI connection to $server failed.\n";
			$errors++;
			next;
		} else {	# ... Go On...
			
			#---Uptime---
			#my $colOS = $objWMI->InstancesOf('Win32_OperatingSystem');
			#foreach my $objOS (in $colOS) {
				#uptime($objOS->{LastBootUpTime}, $objOS->{LocalDateTime});
			#}
			
			#---Disk Utilization---
			diskCheck();
			
			#---Service Checks---
			# Webservers
			if ( $server =~ m/web/ ) {
				serviceQuery("w3svc");
			}
			
			# DB Servers
			if ( $server =~ m/sql/ ) {
				serviceQuery("SQL2005");
			}
			
			# VCenter
			if ( $server =~ m/vcenter/ ) {
				serviceQuery("vpxd");
			}
			
			# DC
			if ( $server =~ m/sbs/ || $server =~ m/dc/ ) {
				serviceQuery("dns");
				serviceQuery("kdc");
			}
			
			# Mail
			if ( $server =~ m/sbs/ || $server =~ m/mail/ ) { ) {
				serviceQuery("MSExchangeSA");
				serviceQuery("MSExchangeIS");
				serviceQuery("MSExchangeMGMT");
				serviceQuery("MSExchangeMTA");
				serviceQuery("RESvc");
				serviceQuery("IMAP4Svc");
				serviceQuery("POP3Svc");
				serviceQuery("SMTPSVC");
			}
			
		}
		
	}
	
	
}
$message = $message . "\n"

# Check our websites
siteCheck("http://web1/");
siteCheck("http://web2/");
#siteCheck("http://www.domain.com/");
siteCheck("http://repo.domain.local/");
siteCheck("https://wiki.domain.com/");


# Check that the Prod DLLs match
parityCheck();


# Go Home
if ($errors) {
	$message = "Validations began at $timestamp.\nThere were $errors error(s):\n" 
		. $message;
		
	print $message;
	fnEmail($message);
} else {
#	print "Nothing to see here.\n";
}



################################################################################
# TODO:

# get uptime

#	-AD Health
#		Will need Perl Cookbook Ch16 p.622

# SQL Replication Check

# Check for recent errors

# TODO: if not "--quiet"
#	Perl Cookbook p.585
