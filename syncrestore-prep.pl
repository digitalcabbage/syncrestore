#!/usr/bin/perl
#
# Generate the SQLite DB needed for the main syncrestore script to run
#
# Written by Jonathan Buzzard (last update 11/3/2021)
#
#

use strict;
use warnings;
use DBI;
use Socket;


my $MMREPQUOTA='/usr/lpp/mmfs/bin/mmrepquota';
my $GETENT = '/usr/bin/getent';


my $DEVICE='gpfs';
my $DB = '/root/syncrestore.db';
my $DBARGS = {AutoCommit => 1, PrintError => 1};



#
# list of users to priortise/skip in the restore
#
my @admins = ('bofh', 'pfy');
my @special = ('boss', 'sharon', 'george');
chomp (my $getent = `getent group industry | sed 's/.*://'`);
my @industry = split /,/, $getent;
chomp ($getent = `getent group teaching | sed 's/.*://'`);
my @teaching = split /,/, $getent;


#
# create hashes of the users block and file usage
#
my %blocks;
my %files;
my @quota = split /\n/, `$MMREPQUOTA -Y -u $DEVICE:users`;
foreach (@quota) {
	# skip the first line
	next if (/^mmrepquota::HEADER:/);

	my @line = split /:/, $_;
	if ($line[8]>=1000) {
		$blocks{$line[9]} = $line[10];
		$files{$line[9]} = $line[15];
	}
}


#
# get a list of user directories for the restore. This is the definitive list for the restore
# we can't use the list of users as there may be users in the system without home directories
#
my @users = </gpfs/users/*>;
foreach (@users) {
	# stip the leading path to expose the username
	$_ =~ s/\/gpfs\/users\///g;
}


#
# create an array of active user accounts (leap seconds ignored here)
#
my @active;
my $cutoff = int(time/86400);
foreach (@users) {
	# getpwnam does not return anything for expiry so get it like this 
	my @info = split /:/, `$GETENT shadow $_`;
	if (($info[7] eq "") || ($info[7]>$cutoff)) {
		push @active, $_;
	}
}


#
# create the database for the restore
#

# first remove any existing database
if (-e $DB) {
	unlink($DB);
}

# connect which creates the DB and then create the table
my $dbh = DBI->connect("dbi:SQLite:$DB", "", "", $DBARGS) or die $DBI::errstr;
$dbh->do("CREATE TABLE users ( name TEXT, blocks INTEGER, files INTEGER, priority INTEGER, sync INTEGER );") or die $DBI::errstr;

# now populate the table setting their initial priority to 10
foreach (@users) {
	$dbh->do("INSERT INTO users (name,blocks,files,priority,sync) VALUES ('$_', $blocks{$_}, $files{$_}, 10, -1 );") or die $DBI::errstr;
}


#
# set the priority for each user according the following table
#
# 1 = admin
# 2 = special
# 3 = industry
# 4 = teaching
# 10 = disabled
#
# we go backwards through the priorities as users may be in more than one category and we
# want them to have the highest category they are eligible for
#
foreach (@active) {
	$dbh->do("UPDATE users SET priority=6 WHERE name='$_';") or die $DBI::errstr;
}
foreach (@teaching) {
	$dbh->do("UPDATE users SET priority=5 WHERE name='$_';") or die $DBI::errstr;
}
foreach (@industry) {
	$dbh->do("UPDATE users SET priority=3 WHERE name='$_';") or die $DBI::errstr;
}
foreach (@special) {
	$dbh->do("UPDATE users SET priority=2 WHERE name='$_';") or die $DBI::errstr;
}
foreach (@admins) {
	$dbh->do("UPDATE users SET priority=1 WHERE name='$_';") or die $DBI::errstr;
}

$dbh->disconnect();

exit(0);
