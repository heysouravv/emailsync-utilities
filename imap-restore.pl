#!/usr/bin/perl

use strict;
use warnings;
use IO::Socket::SSL;
use IO::Socket::INET;
use Mail::IMAPClient;
use File::Find;
use YAML::XS;
use Getopt::Long;
use Pod::Usage;
use Cwd qw(getcwd);
use File::Path qw(make_path);

=head1 NAME

imap-restore.pl - Restore IMAP mailboxes

=head1 SYNOPSIS

perl imap-restore.pl [options]

Options:
    --config     Configuration file (default: restore-config.yaml)
    --backup-dir Directory containing backups (default: ./mailbackup)
    --date       Specific backup date to restore (optional)
    --email      Specific email to restore (optional)
    --help       Show this help message

=cut

# Get command line options
my %opts;
GetOptions(
    'config=s'     => \$opts{config},
    'backup-dir=s' => \$opts{backup_dir},
    'date=s'       => \$opts{date},
    'email=s'      => \$opts{email},
    'help'         => \$opts{help}
) or pod2usage(2);

pod2usage(1) if $opts{help};

# Set default backup directory
$opts{backup_dir} ||= getcwd() . "/mailbackup";
$opts{config} ||= 'restore-config.yaml';

# Create restore log directory
my $LOG_DIR = getcwd() . "/restore_logs";
make_path($LOG_DIR) unless -d $LOG_DIR;

# Open main log file
my ($sec,$min,$hour,$mday,$mon,$year) = localtime(time);
my $timestamp = sprintf("%04d%02d%02d_%02d%02d%02d", 
                       $year+1900, $mon+1, $mday, $hour, $min, $sec);
my $MAIN_LOG = "$LOG_DIR/restore_$timestamp.log";
open my $main_log_fh, '>', $MAIN_LOG or die "Cannot create log file: $!";

# Log function
sub log_message {
    my ($message) = @_;
    my $time = localtime;
    print $main_log_fh "[$time] $message\n";
    print "$message\n";
}

# Load configuration
sub load_config {
    my $config_file = shift;
    log_message("Loading configuration from $config_file");
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

# Function to get all email accounts from backup directory
sub get_backup_accounts {
    my $backup_dir = shift;
    my %accounts;
    
    find(
        sub {
            return unless -f && $_ eq 'backup_info.txt';
            open my $fh, '<', $File::Find::name or return;
            my $email;
            while (<$fh>) {
                if (/^Email:\s*(.+)$/) {
                    $email = $1;
                    last;
                }
            }
            close $fh;
            $accounts{$email} = 1 if $email;
        },
        $backup_dir
    );
    
    return sort keys %accounts;
}

# Function to get latest backup for an email
sub get_latest_backup {
    my ($backup_dir, $email) = @_;
    my $domain = get_domain_from_email($email);
    my $email_backup_dir = "$backup_dir/$domain/$email";
    
    return unless -d $email_backup_dir;
    
    my @backups;
    opendir(my $dh, $email_backup_dir) or die "Cannot open directory: $!";
    while (my $entry = readdir($dh)) {
        next if $entry =~ /^\./ || $entry eq 'logs';
        push @backups, $entry if -d "$email_backup_dir/$entry";
    }
    closedir($dh);
    
    return unless @backups;
    return (sort @backups)[-1];  # Return latest backup
}

# Function to test IMAP connection
sub test_connection {
    my ($server, $port, $user, $pass, $use_ssl) = @_;
    
    log_message("Testing connection to $server:$port for $user");
    
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
        log_message("Failed to establish connection: $!");
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
        log_message("Failed to create IMAP client: $@");
        return 0;
    }

    my @folders = $imap->folders;
    unless (@folders) {
        log_message("No folders found: " . $imap->LastError);
        return 0;
    }
    
    $imap->logout;
    log_message("Connection test successful");
    return 1;
}

# Function to restore messages from mbox file
sub restore_mbox {
    my ($imap, $folder, $mbox_file) = @_;
    
    log_message("Restoring messages from $mbox_file to folder $folder");
    
    open my $fh, '<', $mbox_file or die "Cannot open mbox file: $!";
    my $message = '';
    my $in_message = 0;
    my $count = 0;
    
    while (my $line = <$fh>) {
        if ($line =~ /^From - IMAP Backup/) {
            if ($in_message && $message) {
                eval {
                    $imap->append_string($folder, $message);
                    $count++;
                };
                if ($@) {
                    log_message("Error appending message to $folder: $@");
                }
                $message = '';
            }
            $in_message = 1;
            next;
        }
        $message .= $line if $in_message;
    }
    
    # Append last message
    if ($in_message && $message) {
        eval {
            $imap->append_string($folder, $message);
            $count++;
        };
        if ($@) {
            log_message("Error appending last message to $folder: $@");
        }
    }
    
    close $fh;
    log_message("Restored $count messages to $folder");
}

# Function to restore IMAP mailbox
sub restore_mailbox {
    my ($server_config, $email, $backup_path) = @_;
    
    log_message("Starting restore for $email from $backup_path");
    
    my $socket;
    if ($server_config->{ssl}) {
        $socket = IO::Socket::SSL->new(
            PeerAddr => $server_config->{server},
            PeerPort => $server_config->{port},
            SSL_verify_mode => SSL_VERIFY_NONE,
            Timeout => 10
        ) or die "Cannot create SSL socket: $!";
    } else {
        $socket = IO::Socket::INET->new(
            PeerAddr => $server_config->{server},
            PeerPort => $server_config->{port},
            Proto    => 'tcp',
            Timeout  => 10
        ) or die "Cannot create socket: $!";
    }
    
    my $imap = Mail::IMAPClient->new(
        Socket => $socket,
        User => $email,
        Password => $server_config->{accounts}->{$email},
        Clear => 5,
        Uid => 1,
        Debug => 0
    ) or die "Cannot connect to IMAP server: $@";
    
    # Read backup info
    open my $info_fh, '<', "$backup_path/backup_info.txt" 
        or die "Cannot open backup info: $!";
    my %backup_info;
    while (<$info_fh>) {
        if (/^([^:]+):\s*(.+)$/) {
            $backup_info{$1} = $2;
        }
    }
    close $info_fh;
    
    log_message("Restoring backup from $backup_info{Date} for $email");
    
    # Find all .mbox files in backup directory
    find(
        sub {
            return unless -f && /\.mbox$/;
            my $mbox_file = $File::Find::name;
            my ($folder) = $mbox_file =~ m|/([^/]+)\.mbox$|;
            $folder =~ s/_/\//g;  # Restore original folder name
            
            log_message("Processing folder: $folder");
            
            # Create folder if it doesn't exist
            unless ($imap->exists($folder)) {
                eval {
                    $imap->create($folder)
                        or die "Cannot create folder: " . $imap->LastError;
                };
                if ($@) {
                    log_message("Error creating folder $folder: $@");
                    return;
                }
            }
            
            # Restore messages
            eval {
                restore_mbox($imap, $folder, $mbox_file);
            };
            if ($@) {
                log_message("Error restoring folder $folder: $@");
            }
        },
        $backup_path
    );
    
    $imap->logout;
    log_message("Restore complete for $email");
}

# Main execution
log_message("IMAP Restore Script Started");
log_message("Backup Directory: $opts{backup_dir}");
log_message("Config File: $opts{config}");

my $config = load_config($opts{config});

# Validate server configuration
die "No restore server configuration found!\n" unless $config->{'restore-server'};
my $server_config = $config->{'restore-server'};

log_message("Restore Server: $server_config->{server}:$server_config->{port}");
log_message("SSL: " . ($server_config->{ssl} ? "Yes" : "No"));

# Get accounts to restore
my @accounts = get_backup_accounts($opts{backup_dir});
log_message("Found " . scalar(@accounts) . " accounts in backup directory");

foreach my $email (@accounts) {
    next if $opts{email} && $email ne $opts{email};
    next unless $server_config->{accounts}->{$email};
    
    log_message("Processing account: $email");
    
    # Test connection first
    next unless test_connection(
        $server_config->{server},
        $server_config->{port},
        $email,
        $server_config->{accounts}->{$email},
        $server_config->{ssl}
    );
    
    my $backup_date = $opts{date} || get_latest_backup($opts{backup_dir}, $email);
    unless ($backup_date) {
        log_message("No backup found for $email");
        next;
    }
    
    my $backup_path = "$opts{backup_dir}/" . 
                     get_domain_from_email($email) .
                     "/$email/$backup_date";
    
    eval {
        restore_mailbox($server_config, $email, $backup_path);
    };
    if ($@) {
        log_message("Failed to restore $email: $@");
    }
}

log_message("Restore process completed");
close $main_log_fh;