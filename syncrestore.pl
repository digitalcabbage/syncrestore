#!/usr/bin/perl
#
# Synchronize/restore a file system one directory hierachy at a time guided
# by a SQLite DB storing the results in the DB
#
# Written by Jonathan Buzzard (last update 11/3/2021)
#
#

use warnings;
use strict;
use DBI;
use Socket;
use Sys::Hostname;
use Email::MIME;
use Email::Address;
use Email::Sender::Simple;
use Email::Sender::Transport::SMTP;


my $DSMC = '/usr/bin/dsmc';
my $RSYNC = '/usr/bin/rsync';
my $SSH = '/usr/bin/ssh';
my $CHSH='/usr/bin/chsh';
my $MAKE='/usr/bin/make';

my $DB = '/root/syncrestore.db';
my $DBARGS = { AutoCommit => 1, PrintError => 1 };
my $RELAY = 'relay.uni.ac.uk';
my $FROM = 'support@uni.ac.uk';
my $FINISHED = 'personal@mail.com';

# penalty for having lots of files. Suitable values 3000 for rsync, 4000 for dsmc
my $PENALTY = 4000;

# module name and hash of host pairs for when using rsync with the rsync daemon
my $MODULE = 'general';
my %HOSTS = ( 'nemo1.uni.ac.uk' => 'krebs1.uni.ac.uk',
		'nemo2.uni.ac.uk' => 'krebs1.uni.ac.uk', 
		'nemo3.uni.ac.uk' => 'krebs1.uni.ac.uk');


# template email for a succesful sync/restore to let user know account is reenabled
my $EMAILTEMPLATE = <<EOF;
Your account on the HPC system has been successfully restored
from backup and you can now log on and start to submit jobs again.  

If you have any problems please submit a support request to $FROM

Sincerely
The Support team.
EOF


#
# Send an email to enform a user that their account is ready for use
#
sub SendEmail
{
	my $username = shift @_;

	# get the information from the GCOS field
	my @info = getpwnam("$username");

	# use simple regex for display name, and first extracted email address
	$info[6] =~ m/^([\w\s]+),*/;
	my $displayname= $1;
	my @address = Email::Address->parse($info[6]);

	# exit if address is blank
	if (!length($address[0])) {
		return;
	}

	my $body = "Dear $displayname\n\n";
	$body .= $EMAILTEMPLATE;

	my $email = Email::MIME->create(
		header_str => [
			From    => $FROM,
			To      => $address[0],
			Subject => 'HPC account restored',
		],
		attributes => {
			encoding => 'quoted-printable',
			charset  => 'ISO-8859-1',
		},
		body_str => $body
	);

	# send using the mail relay
	my $transport = Email::Sender::Transport::SMTP->new({ host => $RELAY, port => 25 });

	# we don't process any send errors, just let them generate bounces to the ticket system
	Email::Sender::Simple->try_to_send($email, { transport => $transport });

	return;
}


#
# Enable a user account (this will need customizing for your site)
#
sub EnableUser {
	my $username = shift @_;

	system("$SSH -l root nis.uni.ac.uk $CHSH -s /bin/bash $username");
	system("$SSH -l root nis.uni.ac.uk $MAKE -sC /var/yp");

	return;
}


#
# Rsync an individual users files and return 0 on success
#
sub SyncUser {
	my $username = shift @_;

	# pick the host to synchronize from
	my $host = $HOSTS{ hostname() };

	# first option uses rsync demon, the second option assumes you have
	# mounted the source filesystem on the local machine
#	my $command = "$RSYNC -av --delete $host\:\:/lustre/$username /lustre/";
	my $command = "$RSYNC -av --delete /mnt/lustre/$username /lustre/";

	system($command);

	if ($? == -1) {
		print STDERR "failed to execute rsync for $username\n";
		return -127;
	} elsif ($? & 127) {
		printf STDERR "rsync died with signal %d\n", ($? & 127);
		return -127;
	} elsif (($? >> 8) != 0) {
		printf STDERR "rsync returned error %d while syncronizing $username\n", ($? >> 8);
		return ($? >> 8);
	} else {
		return 0;
	}

	return -127;
}


#
# Restore an individual users files and return 0 on success
#
sub RestoreUser {
	my $username = shift @_;

	my $command = "$DSMC restore \"/gpfs/users/$username/*\" -subdir=yes -replace=all";

	system($command);
	if ($? == -1) {
		print STDERR "failed to execute dsmc for $username\n";
		return -127;
	} elsif ($? & 127) {
		printf STDERR "dsmc died with signal %d\n", ($? & 127);
		return -127;
	} elsif (($? >> 8) != 0) {
		printf STDERR "dsmc returned error %d while restoring $username\n", ($? >> 8);
		return ($? >> 8);
	} else {
		return 0;
	}

	return -127;
}


# open a connection to the database
my $dbh = DBI->connect("dbi:SQLite:$DB", "", "", $DBARGS) or die $DBI::errstr;

# select the first user
my $name = $dbh->selectrow_array("SELECT name FROM users WHERE sync=-1 ORDER BY priority,(blocks+(files*$PENALTY))") or die "unable to find any folders to restore $DBI::errstr";


# keep looping until there are no more users to resture
while ($name) {
	# mark the user as being restored/syncronized
	$dbh->do("UPDATE users SET sync=-2 WHERE name='$name'") or die $DBI::errstr;

	# restore/syncronize the user (uncomment your the one requried)
#	my $error = SyncUser($name);
	my $error = RestoreUser($name);

	# update the DB with the result of the restore/syncronization
	$dbh->do("UPDATE users SET sync=$error WHERE name='$name'") or die $DBI::errstr;

	# re-enable the account again if there is no errors in the restore/synchronization
	if ($error==0) {
		EnableUser($name);
		my $priority = $dbh->selectrow_array("SELECT priority FROM users WHERE name='$name'")  or die $DBI::errstr;
		# if the account is not disabled let the user know it is available again via email
		if ($priority!=10) {
			SendEmail($name);
		}
	}

	# select the next user
	$name = $dbh->selectrow_array("SELECT name FROM users WHERE sync=-1 ORDER BY priority,(blocks+(files*$PENALTY))");
}

$dbh->disconnect();


my $body = "Dear $displayname\n\n";
my $email = Email::MIME->create(
	header_str => [
		From    => $FROM,
		To      => $FINSIHED,
		Subject => 'Syncrestore has finished',
	],
	attributes => {
		encoding => 'quoted-printable',
		charset  => 'ISO-8859-1',
	},
	body_str => 'Syncrestore has no more candidates left and is finsihed\n'
);

# send using the mail relay
my $transport = Email::Sender::Transport::SMTP->new({ host => $RELAY, port => 25 });

# we don't process any send errors, just let them generate bounces to the ticket system
Email::Sender::Simple->try_to_send($email, { transport => $transport });

exit(0);
