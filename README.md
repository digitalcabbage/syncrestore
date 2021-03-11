# *syncrestore*

## TL;DR

*syncrestore* is a Perl script to control the synchronization or restore of a large file system one user at a time using an SQLite database with the list of users to be synchronized/restored and storing the exit code of the program doing the synchronization/restore for each user so you can know who was successful and who was not.

The code here will *have* to be adjusted to suit your needs. The purpose of this repository is to give others access to the methodology I have been using for a number of times over the years. To head off any "why use Perl" questions, this is because the script is now many years old and rewritting known working code would gain no benefit and invariably introduce bugs. Given the low number of opportunities to run this code for real and hence debug it, rewritting in the latest fashionable scripting language is not an sensible proposition.

## Background

Invariably at some point in the life of a storage system you end up needing to migrate it to another newer shinier system. When you have hundreds of TB and/or hundreds or thousands of users giant restore from backup or synchronization from the old system becomes problematic. Any hiccup in the process and you have to start again from scratch which can be very time consuming. Meanwhile this process can be very time consuming and all of your users are unable to access either the new or old system during the process.

One way to get around this is do the synchronization/restore one user at a time. However this leaves the problem of how to manage that. In particular how do I know which users had problems. The solution presented here is to use a simple SQLite database with a list of the users to process. We then have a script that runs through the list in the database, picks a candidate does the synchronization/restore and stores the exit code of the program doing the synchronization/restore in the database.

We can now easily monitor the progress of the synchronization/restore by querying the database using the SQLite command line interface and some SQL queries. In addition we can now prioritize users based on whether they are "special" and/or the amount of data that we need to restore. Another feature is that if we put the SQLite database in a commonly accessible location then we can potentially run the script on multiple host pairs to speed up the synchronization/restore process.

## Preparation

The first step in the process is to create the SQLite database that will be used for the restore. This is a simple flat one table database. With the following fields

| field    | use                  |
|----------|----------------------|
| name     | username on system   |  
| blocks   | storage usage in KB  |
| files    | number of files      |
| priority | number from 1 to 10  |
| sync     | controls the process |

For the priority 1 is the highest and 10 is the lowest. A priority of 10 is reserved for users that are "inactive" on the system. That is you are still holding data for them but their account is disabled. Typically this is a user who has recently left but for which due to policy you have not yet removed their data. We do these users last and don't attempt to email them to let them know their data is synchronized/restored. I generally set myself and any other administrators to a priority of one so we are ready to go first. This enables you to get on the system quickly and check things out before the main restore is started. The grouping of users into different priority groups is down to decisions at your site.

The sync field is where it all happens. Initially this is set to -1. This indicates that the user is available for a restore. Once we start a restore for a user we change it to -2. This has several functions, firstly it allows us to see who is being restored at any give point in time. Second should something happen and the process stops you can immediately restart the process and look to clean up the first attempt before setting sync to -1 again for that user. At which point the script will automatically pick them up again when it gets to the next user.

Finally setting sync to -2 stops a script running on a second host from attempting to process that user. In this way you can run the script on more than one host at a time and parallelize the process.

I use the script syncrestore-prep.pl to gather all the information needed and generate the database. You will need to customize the script for the particular storage migration project you are undertaking.

## Running

Once you have the database prepared you can now move onto the actual synchronization/restore. If you are using rsync then you need to get your source and destination file systems mounted on the same host, or get the rsync daemon running on a the source hosts and check things are working. The other option is to setup temporary password-less SSH and let rsync run over SSH.

Assuming you are ready to start you need to kick all the users off the system. How you achieve that will be dependant on your local site. What I tend to do is change their shell to /sbin/nologin. Once they are done I change it back to /bin/bash and the users can log back on. Note if you are going down the restore from backup route, then once you have kicked the users off you will need to run a final backup to make sure you have everything.

However a word of caution here even if a users shell is set to /sbin/nologin they can still attempt to log on. When they do this if there home directory does not exist then there is a good chance it will unhelpfully get created. Also it will likely update some of the files in the users home directory if it is partially processed. This can cause the synchronization/restore to finish with an none zero exit code and will need rerunning once you have determine the issue. As such it is advisable to warn your users in advance that attempting to access the system prior to being notified will only delay them getting access to the system, that this process is fully automatic and won't be interrupted or changed. Even then expect a small percentage of users to fail the Marshmallow Test. 

Basically it is now just a case of firing the syncrestore.pl script off, on as many hosts as required. I recommend in the strongest possible terms that you run the script inside either screen or tmux. Basically we don't want your flaky connection to the server to cause the script to exit prematurely. Further if you are running in screen/tmux you can reconnect from a different host to check on the output of the script.

Note the script when selecting the next user orders users with the same priority depending on how much "stuff" they have to restore. The goal is to get as many users back on the system as quickly as possible. What I have observed is that there is a significant overhead per file. That is, it is quicker to restore 100 files 1GB in size than 1,000,000 files 1KB in size. As such the script orders the users by (total size in KB)+(no of files * PENALTY), where a lower number is better. I recommend you run some tests and determine the value of PENALTY for your scenario. I have found that a value of 3000 is about right when using rsync and 4000 is about right when restoring using Spectrum Protect. The latter having a higher overhead for a file than rsync (at least in my tests).

The script, once a user has been processed cleanly (exit code of zero) re-enables the account and sends the user an email to that effect. This will need modifying for your site. Alternatively you might decide to disable this and let them all back on at once when it is done.

As a final point I strongly recommend testing this out with a cut down version of the database with a handful of users in it. Possibly synchronizing/restoring to a test area to make sure that any customizations for your site are work correctly before attempting the main run.

## Monitoring progress

To monitor the progress of the restore we open the SQLite database using the command line interface like this

    sqlite3 syncrestore.db

So to see which user(s) is currently being restored

    select name from users where sync=-2;

We can see how many users have been completed successfully and who they are with queries like this 

    select count(name) from users where sync=0;
    select name from users where sync=0;

Or how many users are still to do

    select count(name) from users where sync=1;

how many TB we have left to restore

    select sum(blocks)/(1024*1024*1024) from users where sync=-1;

and how many files to go

    select sum(files) from users where sync=-1;

One way to check on the progress of the current restore is to compare their quota usage (assuming you are using quotas) against the amount in the database. We can also see which users had problems with the restore

    select name,sync from users when sync>0;

By looking at the exit codes we can make some determination of what went wrong. After fixing the problem and possibly deleting what was restored we can set the sync back to -1 with

    update users set sync=-1 where name='joeblogs';

and the script will pick them up and try again next time it selects a candidate. Finally to exit the SQLite command line interface the command is 

    .quit

## Pausing the operation

If for some reason we need to pause the operation then we can just set the sync to say -10

    update users set sync=-10 where sync=-1;

and then as soon as the current users have finished the process will stop as there will be no more valid candidates. Once things are sorted you can set the sync back to -1 with

    update users set sync=-1 where sync=-10;

and start the script again.
