#!/usr/bin/perl
####################################################################################################################################
# pg_backrest.pl - Simple Postgres Backup and Restore
####################################################################################################################################

####################################################################################################################################
# Perl includes
####################################################################################################################################
use threads;
use strict;
use warnings;
use Carp;

use File::Basename;
use Pod::Usage;

use lib dirname($0) . '/../lib';
use BackRest::Utility;
use BackRest::Config;
use BackRest::File;
use BackRest::Backup;
use BackRest::Db;

####################################################################################################################################
# Usage
####################################################################################################################################

=head1 NAME

pg_backrest.pl - Simple Postgres Backup and Restore

=head1 SYNOPSIS

pg_backrest.pl [options] [operation]

 Operation:
   archive-get      retrieve an archive file from backup
   archive-push     push an archive file to backup
   backup           backup a cluster
   expire           expire old backups (automatically run after backup)

 General Options:
   --stanza         stanza (cluster) to operate on (currently required for all operations)
   --config         alternate path for pg_backrest.conf (defaults to /etc/pg_backrest.conf)
   --version        display version and exit
   --help           display usage and exit

 Backup Options:
    --type           type of backup to perform (full, diff, incr)
    --no-start-stop  do not call pg_start/stop_backup().  Postmaster should not be running.
    --force          force backup when --no-start-stop passed and postmaster.pid exists.
                     Use with extreme caution as this will produce an inconsistent backup!
=cut

####################################################################################################################################
# Load command line parameters and config
####################################################################################################################################
# Load the config file
config_load();

# Display version and exit if requested
if (param_get(PARAM_VERSION) || param_get(PARAM_HELP))
{
    print 'pg_backrest ' . version_get() . "\n";

    if (!param_get(PARAM_HELP))
    {
        exit 0;
    }
}

# Display help and exit if requested
if (param_get(PARAM_HELP))
{
    print "\n";
    pod2usage();
}

####################################################################################################################################
# Global variables
####################################################################################################################################
my $oRemote;            # Remote object
my $strRemote;          # Defines which side is remote, DB or BACKUP

####################################################################################################################################
# REMOTE_EXIT - Close the remote object if it exists
####################################################################################################################################
sub remote_exit
{
    my $iExitCode = shift;

    if (defined($oRemote))
    {
        $oRemote->thread_kill()
    }

    if (defined($iExitCode))
    {
        exit $iExitCode;
    }
}

####################################################################################################################################
# REMOTE_GET - Get the remote object or create it if not exists
####################################################################################################################################
sub remote_get
{
    if (!defined($oRemote) && $strRemote ne REMOTE_NONE)
    {
        $oRemote = new BackRest::Remote
        (
            config_key_load($strRemote eq REMOTE_DB ? CONFIG_SECTION_STANZA : CONFIG_SECTION_BACKUP, CONFIG_KEY_HOST, true),
            config_key_load($strRemote eq REMOTE_DB ? CONFIG_SECTION_STANZA : CONFIG_SECTION_BACKUP, CONFIG_KEY_USER, true),
            config_key_load(CONFIG_SECTION_COMMAND, CONFIG_KEY_REMOTE, true)
        );
    }

    return $oRemote;
}

####################################################################################################################################
# SAFE_EXIT - terminate all SSH sessions when the script is terminated
####################################################################################################################################
sub safe_exit
{
    remote_exit();

    my $iTotal = backup_thread_kill();

    confess &log(ERROR, "process was terminated on signal, ${iTotal} threads stopped");
}

$SIG{TERM} = \&safe_exit;
$SIG{HUP} = \&safe_exit;
$SIG{INT} = \&safe_exit;

####################################################################################################################################
# START EVAL BLOCK TO CATCH ERRORS AND STOP THREADS
####################################################################################################################################
eval {

####################################################################################################################################
# START MAIN
####################################################################################################################################

####################################################################################################################################
# DETERMINE IF THERE IS A REMOTE
####################################################################################################################################
# First check if backup is remote
if (defined(config_key_load(CONFIG_SECTION_BACKUP, CONFIG_KEY_HOST)))
{
    $strRemote = REMOTE_BACKUP;
}
# Else check if db is remote
elsif (defined(config_key_load(CONFIG_SECTION_STANZA, CONFIG_KEY_HOST)))
{
    # Don't allow both sides to be remote
    if (defined($strRemote))
    {
        confess &log(ERROR, 'db and backup cannot both be configured as remote');
    }

    $strRemote = REMOTE_DB;
}
else
{
    $strRemote = REMOTE_NONE;
}

####################################################################################################################################
# ARCHIVE-PUSH Command
####################################################################################################################################
if (operation_get() eq OP_ARCHIVE_PUSH)
{
    # Make sure the archive push operation happens on the db side
    if ($strRemote eq REMOTE_DB)
    {
        confess &log(ERROR, 'archive-push operation must run on the db host');
    }

    # If an archive section has been defined, use that instead of the backup section when operation is OP_ARCHIVE_PUSH
    my $bArchiveLocal = defined(config_key_load(CONFIG_SECTION_ARCHIVE, CONFIG_KEY_PATH));
    my $strSection =  $bArchiveLocal ? CONFIG_SECTION_ARCHIVE : CONFIG_SECTION_BACKUP;
    my $strArchivePath = config_key_load($strSection, CONFIG_KEY_PATH);

    # Get checksum flag
    my $bChecksum = config_key_load(CONFIG_SECTION_BACKUP, CONFIG_KEY_CHECKSUM, true, 'y') eq 'y' ? true : false;

    # Get the async compress flag.  If compress_async=y then compression is off for the initial push when archiving locally
    my $bCompressAsync = false;

    if ($bArchiveLocal)
    {
        config_key_load($strSection, CONFIG_KEY_COMPRESS_ASYNC, true, 'n') eq 'n' ? false : true;
    }

    # If logging locally then create the stop archiving file name
    my $strStopFile;

    if ($bArchiveLocal)
    {
        $strStopFile = "${strArchivePath}/lock/" + param_get(PARAM_STANZA) + "-archive.stop";
    }

    # If an archive file is defined, then push it
    if (defined($ARGV[1]))
    {
        # If the stop file exists then discard the archive log
        if (defined($strStopFile))
        {
            if (-e $strStopFile)
            {
                &log(ERROR, "archive stop file (${strStopFile}) exists , discarding " . basename($ARGV[1]));
                remote_exit(0);
            }
        }

        # Get the compress flag
        my $bCompress = $bCompressAsync ? false : config_key_load($strSection, CONFIG_KEY_COMPRESS, true, 'y') eq 'y' ? true : false;

        # Create the file object
        my $oFile = new BackRest::File
        (
            param_get(PARAM_STANZA),
            config_key_load($strSection, CONFIG_KEY_PATH, true),
            $bArchiveLocal ? REMOTE_NONE : $strRemote,
            $bArchiveLocal ? undef : remote_get()
        );

        # Init backup
        backup_init
        (
            undef,
            $oFile,
            undef,
            $bCompress,
            undef,
            !$bChecksum
        );

        &log(INFO, 'pushing archive log ' . $ARGV[1] . ($bArchiveLocal ? ' asynchronously' : ''));

        archive_push(config_key_load(CONFIG_SECTION_STANZA, CONFIG_KEY_PATH), $ARGV[1]);

        # Exit if we are archiving local but no backup host has been defined
        if (!($bArchiveLocal && defined(config_key_load(CONFIG_SECTION_BACKUP, CONFIG_KEY_HOST))))
        {
            remote_exit(0);
        }

        # Fork and exit the parent process so the async process can continue
        if (!param_get(PARAM_TEST_NO_FORK))
        {
            if (fork())
            {
                remote_exit(0);
            }
        }
        # Else the no-fork flag has been specified for testing
        else
        {
            &log(INFO, 'No fork on archive local for TESTING');
        }
    }

    # If no backup host is defined it makes no sense to run archive-push without a specified archive file so throw an error
    if (!defined(config_key_load(CONFIG_SECTION_BACKUP, CONFIG_KEY_HOST)))
    {
        &log(ERROR, 'archive-push called without an archive file or backup host');
    }

    &log(INFO, 'starting async archive-push');

    # Create a lock file to make sure async archive-push does not run more than once
    my $strLockPath = "${strArchivePath}/lock/" . param_get(PARAM_STANZA) . "-archive.lock";

    if (!lock_file_create($strLockPath))
    {
        &log(DEBUG, 'archive-push process is already running - exiting');
        remote_exit(0);
    }

    # Build the basic command string that will be used to modify the command during processing
    my $strCommand = $^X . ' ' . $0 . " --stanza=" . param_get(PARAM_STANZA);

    # Get the new operational flags
    my $bCompress = config_key_load(CONFIG_SECTION_BACKUP, CONFIG_KEY_COMPRESS, true, 'y') eq 'y' ? true : false;
    my $iArchiveMaxMB = config_key_load(CONFIG_SECTION_ARCHIVE, CONFIG_KEY_ARCHIVE_MAX_MB);

    # eval
    # {
        # Create the file object
        my $oFile = new BackRest::File
        (
            param_get(PARAM_STANZA),
            config_key_load(CONFIG_SECTION_BACKUP, CONFIG_KEY_PATH, true),
            $strRemote,
            remote_get()
        );

        # Init backup
        backup_init
        (
            undef,
            $oFile,
            undef,
            $bCompress,
            undef,
            !$bChecksum,
            config_key_load(CONFIG_SECTION_BACKUP, CONFIG_KEY_THREAD_MAX),
            undef,
            config_key_load(CONFIG_SECTION_BACKUP, CONFIG_KEY_THREAD_TIMEOUT)
        );

        # Call the archive_xfer function and continue to loop as long as there are files to process
        my $iLogTotal;

        while (!defined($iLogTotal) || $iLogTotal > 0)
        {
            $iLogTotal = archive_xfer($strArchivePath . "/archive/" . param_get(PARAM_STANZA), $strStopFile,
                                      $strCommand, $iArchiveMaxMB);

            if ($iLogTotal > 0)
            {
                &log(DEBUG, "${iLogTotal} archive logs were transferred, calling archive_xfer() again");
            }
            else
            {
                &log(DEBUG, 'no more logs to transfer - exiting');
            }
        }
    #
    # };

    # # If there were errors above then start compressing
    # if ($@)
    # {
    #     if ($bCompressAsync)
    #     {
    #         &log(ERROR, "error during transfer: $@");
    #         &log(WARN, "errors during transfer, starting compression");
    #
    #         # Run file_init_archive - this is the minimal config needed to run archive pulling !!! need to close the old file
    #         my $oFile = BackRest::File->new
    #         (
    #             # strStanza => $strStanza,
    #             # bNoCompression => false,
    #             # strBackupPath => config_key_load(CONFIG_SECTION_BACKUP, CONFIG_KEY_PATH, true),
    #             # strCommand => $0,
    #             # strCommandCompress => config_key_load(CONFIG_SECTION_COMMAND, CONFIG_KEY_COMPRESS, $bCompress),
    #             # strCommandDecompress => config_key_load(CONFIG_SECTION_COMMAND, CONFIG_KEY_DECOMPRESS, $bCompress)
    #         );
    #
    #         backup_init
    #         (
    #             undef,
    #             $oFile,
    #             undef,
    #             $bCompress,
    #             undef,
    #             !$bChecksum,
    #             config_key_load(CONFIG_SECTION_BACKUP, CONFIG_KEY_THREAD_MAX),
    #             undef,
    #             config_key_load(CONFIG_SECTION_BACKUP, CONFIG_KEY_THREAD_TIMEOUT)
    #         );
    #
    #         archive_compress($strArchivePath . "/archive/${strStanza}", $strCommand, 256);
    #     }
    #     else
    #     {
    #         confess $@;
    #     }
    # }

    lock_file_remove();
    remote_exit(0);
}

####################################################################################################################################
# ARCHIVE-GET Command
####################################################################################################################################
if (operation_get() eq OP_ARCHIVE_GET)
{
    # Make sure the archive file is defined
    if (!defined($ARGV[1]))
    {
        confess &log(ERROR, 'archive file not provided');
    }

    # Make sure the destination file is defined
    if (!defined($ARGV[2]))
    {
        confess &log(ERROR, 'destination file not provided');
    }

    # Init the file object
    my $oFile = new BackRest::File
    (
        param_get(PARAM_STANZA),
        config_key_load(CONFIG_SECTION_BACKUP, CONFIG_KEY_PATH, true),
        $strRemote,
        remote_get()
    );

    # Init the backup object
    backup_init
    (
        undef,
        $oFile
    );

    # Info for the Postgres log
    &log(INFO, 'getting archive log ' . $ARGV[1]);

    # Get the archive file
    remote_exit(archive_get(config_key_load(CONFIG_SECTION_STANZA, CONFIG_KEY_PATH), $ARGV[1], $ARGV[2]));
}

####################################################################################################################################
# OPEN THE LOG FILE
####################################################################################################################################
if (defined(config_key_load(CONFIG_SECTION_BACKUP, CONFIG_KEY_HOST)))
{
    confess &log(ASSERT, 'backup/expire operations must be performed locally on the backup server');
}

log_file_set(config_key_load(CONFIG_SECTION_BACKUP, CONFIG_KEY_PATH, true) . "/log/" . param_get(PARAM_STANZA));

####################################################################################################################################
# GET MORE CONFIG INFO
####################################################################################################################################
# Make sure backup and expire operations happen on the backup side
if ($strRemote eq REMOTE_BACKUP)
{
    confess &log(ERROR, 'backup and expire operations must run on the backup host');
}

# Get the operational flags
my $bCompress = config_key_load(CONFIG_SECTION_BACKUP, CONFIG_KEY_COMPRESS, true, 'y') eq 'y' ? true : false;
my $bChecksum = config_key_load(CONFIG_SECTION_BACKUP, CONFIG_KEY_CHECKSUM, true, 'y') eq 'y' ? true : false;

# Set the lock path
my $strLockPath = config_key_load(CONFIG_SECTION_BACKUP, CONFIG_KEY_PATH, true) .  '/lock/' .
                                  param_get(PARAM_STANZA) . '-' . operation_get() . '.lock';

if (!lock_file_create($strLockPath))
{
    &log(ERROR, 'backup process is already running for stanza ' . param_get(PARAM_STANZA) . ' - exiting');
    remote_exit(0);
}

# Initialize the default file object
my $oFile = new BackRest::File
(
    param_get(PARAM_STANZA),
    config_key_load(CONFIG_SECTION_BACKUP, CONFIG_KEY_PATH, true),
    $strRemote,
    remote_get()
);

# Initialize the db object
my $oDb;

if (!param_get(PARAM_NO_START_STOP))
{
    $oDb = new BackRest::Db
    (
        config_key_load(CONFIG_SECTION_COMMAND, CONFIG_KEY_PSQL),
        config_key_load(CONFIG_SECTION_STANZA, CONFIG_KEY_HOST),
        config_key_load(CONFIG_SECTION_STANZA, CONFIG_KEY_USER)
    );
}

# Run backup_init - parameters required for backup and restore operations
backup_init
(
    $oDb,
    $oFile,
    param_get(PARAM_TYPE),
    config_key_load(CONFIG_SECTION_BACKUP, CONFIG_KEY_COMPRESS, true, 'y') eq 'y' ? true : false,
    config_key_load(CONFIG_SECTION_BACKUP, CONFIG_KEY_HARDLINK, true, 'y') eq 'y' ? true : false,
    !$bChecksum,
    config_key_load(CONFIG_SECTION_BACKUP, CONFIG_KEY_THREAD_MAX),
    config_key_load(CONFIG_SECTION_BACKUP, CONFIG_KEY_ARCHIVE_REQUIRED, true, 'y') eq 'y' ? true : false,
    config_key_load(CONFIG_SECTION_BACKUP, CONFIG_KEY_THREAD_TIMEOUT),
    param_get(PARAM_NO_START_STOP),
    param_get(PARAM_FORCE)
);

####################################################################################################################################
# BACKUP
####################################################################################################################################
if (operation_get() eq OP_BACKUP)
{
    backup(config_key_load(CONFIG_SECTION_STANZA, CONFIG_KEY_PATH),
           config_key_load(CONFIG_SECTION_BACKUP, CONFIG_KEY_START_FAST, true, 'n') eq 'y' ? true : false);

    operation_set(OP_EXPIRE);
}

####################################################################################################################################
# EXPIRE
####################################################################################################################################
if (operation_get() eq OP_EXPIRE)
{
    backup_expire
    (
        $oFile->path_get(PATH_BACKUP_CLUSTER),
        config_key_load(CONFIG_SECTION_RETENTION, CONFIG_KEY_FULL_RETENTION),
        config_key_load(CONFIG_SECTION_RETENTION, CONFIG_KEY_DIFFERENTIAL_RETENTION),
        config_key_load(CONFIG_SECTION_RETENTION, CONFIG_KEY_ARCHIVE_RETENTION_TYPE),
        config_key_load(CONFIG_SECTION_RETENTION, CONFIG_KEY_ARCHIVE_RETENTION)
    );

    lock_file_remove();
}

remote_exit(0);
};

####################################################################################################################################
# CHECK FOR ERRORS AND STOP THREADS
####################################################################################################################################
if ($@)
{
    remote_exit();
    confess $@;
}
