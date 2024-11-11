#!/usr/bin/perl

use strict;
use warnings;
use IO::Socket::SSL;
use IO::Socket::INET;
use Mail::IMAPClient;
use File::Path qw(make_path);
use YAML::XS;
use Cwd qw(getcwd);
use Getopt::Long;
use Pod::Usage;

=head1 NAME

imap-backup.pl - Backup IMAP mailboxes

=head1 SYNOPSIS

perl imap-backup.pl [options]

Options:
    --config     Configuration file (default: backup-config.yaml)
    --help       Show this help message

=cut

# Get command line options
my %opts;
GetOptions(
    'config=s' => \$opts{config},
    'help'     => \$opts{help}
) or pod2usage(2);

pod2usage(1) if $opts{help};

# Get current directory for backup
my $current_dir = getcwd();
my $BASE_BACKUP_DIR = "$current_dir/mailbackup";

# Create the complete backup directory if it doesn't exist
make_path($BASE_BACKUP_DIR) unless -d $BASE_BACKUP_DIR;

# Load configuration
sub load_config {
    my $config_file = shift || 'backup-config.yaml';
    open my $fh, '<', $config_file or die "Cannot open config file: $!";
    my $config = YAML::XS::Load(do { local $/; <$fh> });
    close $fh;
    return $config;
}

# Function to extract domain from email
sub get_domain_from_email {
    my $email = shift;
    $email =~ /\@(.+)$/;
    return $1;
}

# Function to test IMAP connection
sub test_connection {
    my ($server, $port, $user, $pass, $use_ssl) = @_;
    
    print "\nTesting connection to $server:$port...\n";
    
    my $socket;
    if ($use_ssl) {
        $socket = IO::Socket::SSL->new(
            PeerAddr => $server,
            PeerPort => $port,
            SSL_verify_mode => SSL_VERIFY_NONE,
            Timeout => 10
        );
    } else {
        $socket = IO::Socket::INET->new(
            PeerAddr => $server,
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => 10
        );
    }

    unless ($socket) {
        print "Failed to establish connection: $!\n";
        return 0;
    }

    my $imap = Mail::IMAPClient->new(
        Socket => $socket,
        User => $user,
        Password => $pass,
        Clear => 5,
        Uid => 1,
        Debug => 0
    );

    unless ($imap) {
        print "Failed to create IMAP client: $@\n";
        return 0;
    }

    my @folders = $imap->folders;
    unless (@folders) {
        print "No folders found: " . $imap->LastError . "\n";
        return 0;
    }
    
    $imap->logout;
    return 1;
}

# Function to save mailbox to mbox format
sub save_mailbox {
    my ($imap, $folder, $output_file) = @_;
    
    open my $fh, '>', $output_file or die "Cannot open $output_file: $!";
    
    $imap->select($folder) or die "Cannot select folder $folder: " . $imap->LastError;
    my @messages = $imap->messages or return;
    
    foreach my $msg (@messages) {
        my $message = $imap->message_string($msg);
        print $fh "From - IMAP Backup\n";
        print $fh $message;
        print $fh "\n";
    }
    
    close $fh;
}

# Function to run backup
sub run_backup {
    my ($server, $port, $user, $pass, $use_ssl) = @_;
    
    # Extract domain from email and create backup structure
    my $domain = get_domain_from_email($user);
    my $backup_dir = "$BASE_BACKUP_DIR/$domain/$user";
    make_path($backup_dir);
    
    # Create backup log directory
    my $log_dir = "$backup_dir/logs";
    make_path($log_dir);
    
    # Get current timestamp
    my ($sec,$min,$hour,$mday,$mon,$year) = localtime(time);
    my $timestamp = sprintf("%04d%02d%02d_%02d%02d%02d", 
                          $year+1900, $mon+1, $mday, $hour, $min, $sec);
    
    # Create backup directory
    my $backup_path = "$backup_dir/$timestamp";
    make_path($backup_path);
    
    print "\nCreating backup in: $backup_path\n";
    
    # Open log file
    open my $log_fh, '>', "$log_dir/backup_$timestamp.log" 
        or die "Cannot create log file: $!";
    
    # Create IMAP connection
    my $socket;
    if ($use_ssl) {
        $socket = IO::Socket::SSL->new(
            PeerAddr => $server,
            PeerPort => $port,
            SSL_verify_mode => SSL_VERIFY_NONE,
            Timeout => 10
        ) or die "Cannot create SSL socket: $!";
    } else {
        $socket = IO::Socket::INET->new(
            PeerAddr => $server,
            PeerPort => $port,
            Proto    => 'tcp',
            Timeout  => 10
        ) or die "Cannot create socket: $!";
    }
    
    my $imap = Mail::IMAPClient->new(
        Socket => $socket,
        User => $user,
        Password => $pass,
        Clear => 5,
        Uid => 1,
        Debug => 0
    ) or die "Cannot connect to IMAP server: $@";
    
    # Get all folders
    my @folders = $imap->folders;
    
    foreach my $folder (@folders) {
        print "Backing up folder: $folder\n";
        print $log_fh "Processing folder: $folder\n";
        
        eval {
            my $safe_folder_name = $folder;
            $safe_folder_name =~ s/[\/\\]/_/g;  # Replace slashes with underscores
            my $mbox_file = "$backup_path/$safe_folder_name.mbox";
            save_mailbox($imap, $folder, $mbox_file);
            print $log_fh "Successfully backed up $folder to $mbox_file\n";
        };
        if ($@) {
            print $log_fh "Error backing up $folder: $@\n";
            warn "Error backing up $folder: $@\n";
        }
    }
    
    $imap->logout;
    close $log_fh;
    
    # Create a summary file
    open my $summary, '>', "$backup_path/backup_info.txt" 
        or die "Cannot create summary file: $!";
    print $summary "Backup Information\n";
    print $summary "=================\n";
    print $summary "Email: $user\n";
    print $summary "Server: $server\n";
    print $summary "Port: $port\n";
    print $summary "Date: $timestamp\n";
    print $summary "SSL: " . ($use_ssl ? "Yes" : "No") . "\n";
    print $summary "Folders: " . join(", ", @folders) . "\n";
    close $summary;
    
    print "\nBackup complete for $user. Check $log_dir/backup_$timestamp.log for details.\n";
}

# Main execution
print "IMAP Backup Script\n";
print "================\n";

print "Backup directory: $BASE_BACKUP_DIR\n";

my $config = load_config($opts{config});

# Validate server configuration
die "No backup server configuration found!\n" unless $config->{'backup-server'};
my $server = $config->{'backup-server'}->{server};
my $port = $config->{'backup-server'}->{port};
my $use_ssl = $config->{'backup-server'}->{ssl} // 1;  # Default to SSL

print "Backup Server: $server:$port (SSL: " . ($use_ssl ? "Yes" : "No") . ")\n";

foreach my $account (@{$config->{accounts}}) {
    print "\nProcessing account: $account->{email}\n";
    
    my $success = test_connection($server, $port, $account->{email}, 
                                $account->{password}, $use_ssl);
    
    if ($success) {
        eval {
            run_backup($server, $port, $account->{email}, 
                      $account->{password}, $use_ssl);
        };
        if ($@) {
            print "Error during backup of $account->{email}: $@\n";
        }
    } else {
        print "Failed to backup $account->{email}\n";
    }
}