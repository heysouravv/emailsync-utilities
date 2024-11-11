#!/usr/bin/perl

use strict;
use warnings;
use IO::Socket::SSL;
use IO::Socket::INET;
use Mail::IMAPClient;

# Configuration
my $imap_server = 
my $email = 
my $password = 
my $ssl_port = 993;   # Standard IMAP SSL port
my $non_ssl_port = 143;  # Standard IMAP non-SSL port

# Function to test IMAP connection with SSL
sub test_ssl_connection {
    my ($server, $port, $user, $pass) = @_;
    
    print "\nTesting SSL connection to $server:$port...\n";
    
    my $socket = IO::Socket::SSL->new(
        PeerAddr => $server,
        PeerPort => $port,
        SSL_verify_mode => SSL_VERIFY_NONE,
        Timeout => 10
    );

    unless ($socket) {
        print "Failed to establish SSL connection: $!\n";
        return 0;
    }

    print "SSL Connection established. Attempting IMAP connection...\n";
    return test_imap_connection($socket, $user, $pass);
}

# Function to test IMAP connection without SSL
sub test_non_ssl_connection {
    my ($server, $port, $user, $pass) = @_;
    
    print "\nTesting non-SSL connection to $server:$port...\n";
    
    my $socket = IO::Socket::INET->new(
        PeerAddr => $server,
        PeerPort => $port,
        Proto    => 'tcp',
        Timeout  => 10
    );

    unless ($socket) {
        print "Failed to establish non-SSL connection: $!\n";
        return 0;
    }

    print "Non-SSL Connection established. Attempting IMAP connection...\n";
    return test_imap_connection($socket, $user, $pass);
}

# Common IMAP testing function
sub test_imap_connection {
    my ($socket, $user, $pass) = @_;

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

    print "IMAP client created. Checking connection...\n";

    # Test the connection by listing mailboxes
    my @folders = $imap->folders;
    if (@folders) {
        print "Successfully connected!\n";
        print "Available folders: " . join(", ", @folders) . "\n";
        
        # Test INBOX access
        if ($imap->select('INBOX')) {
            my $messages = $imap->message_count('INBOX');
            print "INBOX contains $messages messages\n";
        } else {
            print "Could not access INBOX: " . $imap->LastError . "\n";
        }
    } else {
        print "Could not list folders: " . $imap->LastError . "\n";
        return 0;
    }

    $imap->logout;
    return 1;
}

# Function to run backup
sub run_backup {
    my ($server, $port, $user, $pass, $use_ssl) = @_;
    
    # Create backup directory
    my $backup_dir = "/tmp/mailbackup";
    system("mkdir -p $backup_dir");
    
    # Construct server string with appropriate port
    my $server_string = $server;
    $server_string .= ":$port" if $port != ($use_ssl ? 993 : 143);
    
    # Run the imapdump.pl script
    my $command = "perl imapdump.pl -S $server_string/$user/$pass -f $backup_dir -L $backup_dir/backup.log -d";
    print "\nExecuting backup command...\n";
    system($command);
    
    print "\nBackup process complete. Check $backup_dir/backup.log for details.\n";
}

# Main execution
print "IMAP Connection Test Script (SSL and Non-SSL)\n";
print "-------------------------------------------\n";

my $ssl_success = test_ssl_connection($imap_server, $ssl_port, $email, $password);
print "\nSSL Connection Test: " . ($ssl_success ? "SUCCESS" : "FAILED");

my $non_ssl_success = test_non_ssl_connection($imap_server, $non_ssl_port, $email, $password);
print "\nNon-SSL Connection Test: " . ($non_ssl_success ? "SUCCESS" : "FAILED");

print "\n\nTest Results Summary:";
print "\n---------------------";
print "\nSSL (Port $ssl_port): " . ($ssl_success ? "WORKING" : "NOT WORKING");
print "\nNon-SSL (Port $non_ssl_port): " . ($non_ssl_success ? "WORKING" : "NOT WORKING");

if ($ssl_success || $non_ssl_success) {
    print "\n\nAt least one connection method worked. Would you like to proceed with backup? (y/n): ";
    my $answer = <STDIN>;
    chomp $answer;
    
    if (lc($answer) eq 'y') {
        # Prefer SSL if it's available
        if ($ssl_success) {
            print "\nProceeding with SSL backup...\n";
            run_backup($imap_server, $ssl_port, $email, $password, 1);
        } else {
            print "\nProceeding with non-SSL backup...\n";
            run_backup($imap_server, $non_ssl_port, $email, $password, 0);
        }
    } else {
        print "\nBackup cancelled by user.\n";
    }
} else {
    print "\n\nBoth connection methods failed. Please check your server settings and try again.\n";
    exit 1;
}