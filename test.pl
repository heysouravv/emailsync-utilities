#!/usr/bin/perl

use strict;
use warnings;
use Socket;
use Net::DNS;
use IO::Socket::SSL;
use Net::SMTP;
use Term::ANSIColor;
use Data::Dumper;
use Time::HiRes qw(time sleep);
use MIME::Base64;

# Configuration
my $DOMAIN = 
my $MAIL_DOMAIN = "mail.$DOMAIN";
my $EXPECTED_IP = 
my $SMTP_USER = 
my $SMTP_PASS =

# DNS Servers to check
my @DNS_SERVERS = (
    { name => "Google DNS", ip => "8.8.8.8" },
    { name => "Cloudflare", ip => "1.1.1.1" },
    { name => "OpenDNS", ip => "208.67.222.222" },
    { name => "Quad9", ip => "9.9.9.9" }
);

# Mail ports to check
my @MAIL_PORTS = (
    { port => 25, service => "SMTP", protocol => "tcp" },
    { port => 465, service => "SMTPS", protocol => "ssl" },
    { port => 587, service => "SMTP Submission", protocol => "tcp" },
    { port => 993, service => "IMAPS", protocol => "ssl" },
    { port => 995, service => "POP3S", protocol => "ssl" }
);

sub print_header {
    my ($text) = @_;
    print "\n", color('bold blue'), "=== $text ===", color('reset'), "\n";
}

sub print_result {
    my ($test, $result, $details) = @_;
    my $color = $result ? 'green' : 'red';
    my $status = $result ? "PASS" : "FAIL";
    printf "%-40s [%s] %s\n", 
        $test, 
        colored($status, $color),
        ($details ? "($details)" : "");
}

sub check_dns_propagation {
    print_header("DNS Propagation Check");
    
    my $res = Net::DNS::Resolver->new;
    my %results;
    
    foreach my $dns (@DNS_SERVERS) {
        $res->nameservers($dns->{ip});
        my $query = $res->search($DOMAIN, 'A');
        
        if ($query) {
            foreach my $rr ($query->answer) {
                next unless $rr->type eq 'A';
                my $ip = $rr->address;
                $results{$dns->{name}} = {
                    ip => $ip,
                    match => ($ip eq $EXPECTED_IP)
                };
            }
        }
    }
    
    foreach my $dns (@DNS_SERVERS) {
        my $result = $results{$dns->{name}};
        if ($result) {
            print_result(
                $dns->{name}, 
                $result->{match},
                $result->{ip}
            );
        } else {
            print_result($dns->{name}, 0, "Query failed");
        }
    }
    
    return \%results;
}

sub check_reverse_dns {
    print_header("Reverse DNS Check");
    
    my $res = Net::DNS::Resolver->new;
    my $query = $res->query($EXPECTED_IP, "PTR");
    
    if ($query) {
        foreach my $rr ($query->answer) {
            if ($rr->type eq 'PTR') {
                my $ptr = $rr->ptrdname;
                print_result(
                    "PTR Record", 
                    ($ptr =~ /$DOMAIN/i),
                    $ptr
                );
                return $ptr;
            }
        }
    }
    print_result("PTR Record", 0, "No PTR record found");
    return undef;
}

sub check_mx_records {
    print_header("MX Records Check");
    
    my $res = Net::DNS::Resolver->new;
    my $query = $res->search($DOMAIN, 'MX');
    my $has_valid_mx = 0;
    
    if ($query) {
        foreach my $rr ($query->answer) {
            next unless $rr->type eq 'MX';
            my $mx = $rr->exchange;
            my $preference = $rr->preference;
            $has_valid_mx = 1 if $mx =~ /$DOMAIN/i;
            print_result(
                "MX Record", 
                ($mx =~ /$DOMAIN/i),
                "Preference: $preference, Server: $mx"
            );
        }
    }
    
    print_result("MX Records", 0, "No MX records found") unless $has_valid_mx;
    return $has_valid_mx;
}

sub check_spf_record {
    print_header("SPF Record Check");
    
    my $res = Net::DNS::Resolver->new;
    my $query = $res->search($DOMAIN, 'TXT');
    my $has_spf = 0;
    
    if ($query) {
        foreach my $rr ($query->answer) {
            next unless $rr->type eq 'TXT';
            my $txt = $rr->txtdata;
            if ($txt =~ /^v=spf1/i) {
                $has_spf = 1;
                print_result(
                    "SPF Record", 
                    1,
                    $txt
                );
            }
        }
    }
    
    print_result("SPF Record", 0, "No SPF record found") unless $has_spf;
    return $has_spf;
}

sub check_dkim_record {
    print_header("DKIM Record Check");
    
    my $res = Net::DNS::Resolver->new;
    my $selector = "default"; # Common selector, might need to be configurable
    my $dkim_domain = "$selector._domainkey.$DOMAIN";
    my $query = $res->search($dkim_domain, 'TXT');
    my $has_dkim = 0;
    
    if ($query) {
        foreach my $rr ($query->answer) {
            next unless $rr->type eq 'TXT';
            my $txt = $rr->txtdata;
            if ($txt =~ /v=DKIM1/i) {
                $has_dkim = 1;
                print_result(
                    "DKIM Record", 
                    1,
                    "Found for selector '$selector'"
                );
            }
        }
    }
    
    print_result("DKIM Record", 0, "No DKIM record found") unless $has_dkim;
    return $has_dkim;
}

sub check_dmarc_record {
    print_header("DMARC Record Check");
    
    my $res = Net::DNS::Resolver->new;
    my $dmarc_domain = "_dmarc.$DOMAIN";
    my $query = $res->search($dmarc_domain, 'TXT');
    my $has_dmarc = 0;
    
    if ($query) {
        foreach my $rr ($query->answer) {
            next unless $rr->type eq 'TXT';
            my $txt = $rr->txtdata;
            if ($txt =~ /v=DMARC1/i) {
                $has_dmarc = 1;
                print_result(
                    "DMARC Record", 
                    1,
                    $txt
                );
            }
        }
    }
    
    print_result("DMARC Record", 0, "No DMARC record found") unless $has_dmarc;
    return $has_dmarc;
}

sub check_port_connectivity {
    print_header("Port Connectivity Check");
    
    my %results;
    foreach my $port_info (@MAIL_PORTS) {
        my $port = $port_info->{port};
        my $service = $port_info->{service};
        my $protocol = $port_info->{protocol};
        
        my $sock;
        if ($protocol eq 'ssl') {
            $sock = IO::Socket::SSL->new(
                PeerAddr => $MAIL_DOMAIN,
                PeerPort => $port,
                Timeout => 5,
                SSL_verify_mode => SSL_VERIFY_NONE
            );
        } else {
            $sock = IO::Socket::INET->new(
                PeerAddr => $MAIL_DOMAIN,
                PeerPort => $port,
                Timeout => 5,
                Proto => 'tcp'
            );
        }
        
        my $result = defined($sock) ? 1 : 0;
        $results{$port} = $result;
        
        print_result(
            "$service (Port $port)", 
            $result,
            $result ? "Open" : "Closed/Filtered"
        );
        
        close($sock) if $sock;
    }
    
    return \%results;
}

sub test_smtp_auth {
    print_header("SMTP Authentication Test");
    
    my @ports = (465, 587);
    my $auth_success = 0;
    
    foreach my $port (@ports) {
        print "\nTesting SMTP AUTH on port $port...\n";
        
        my $smtp;
        eval {
            if ($port == 465) {
                $smtp = Net::SMTP->new(
                    $MAIL_DOMAIN,
                    Port => $port,
                    SSL => 1,
                    Timeout => 10,
                );
            } else {
                $smtp = Net::SMTP->new(
                    $MAIL_DOMAIN,
                    Port => $port,
                    Timeout => 10,
                );
            }
        };
        
        if ($smtp) {
            my $result = 0;
            if ($port == 587) {
                $result = $smtp->starttls();
                print_result("STARTTLS", $result);
            }
            
            if ($smtp->auth($SMTP_USER, $SMTP_PASS)) {
                print_result(
                    "SMTP Auth (Port $port)", 
                    1,
                    "Authentication successful"
                );
                $auth_success = 1;
            } else {
                print_result(
                    "SMTP Auth (Port $port)", 
                    0,
                    "Authentication failed"
                );
            }
            $smtp->quit;
        } else {
            print_result(
                "SMTP Connection (Port $port)", 
                0,
                "Connection failed"
            );
        }
    }
    
    return $auth_success;
}

sub generate_summary {
    print_header("Analysis Summary");
    
    my $dns_results = check_dns_propagation();
    my $ptr_record = check_reverse_dns();
    my $mx_valid = check_mx_records();
    my $spf_valid = check_spf_record();
    my $dkim_valid = check_dkim_record();
    my $dmarc_valid = check_dmarc_record();
    my $port_results = check_port_connectivity();
    my $smtp_auth_works = test_smtp_auth();
    
    my @issues;
    my @recommendations;
    
    # Analyze DNS propagation
    my $dns_consistent = 1;
    foreach my $dns (@DNS_SERVERS) {
        if ($dns_results->{$dns->{name}} && !$dns_results->{$dns->{name}}->{match}) {
            $dns_consistent = 0;
            push @issues, "DNS not fully propagated at " . $dns->{name};
        }
    }
    
    # Check essential records
    push @issues, "Missing or invalid MX record" unless $mx_valid;
    push @issues, "Missing PTR record" unless $ptr_record;
    push @issues, "Missing SPF record" unless $spf_valid;
    push @issues, "Missing DKIM record" unless $dkim_valid;
    push @issues, "Missing DMARC record" unless $dmarc_valid;
    
    # Check port connectivity
    foreach my $port_info (@MAIL_PORTS) {
        unless ($port_results->{$port_info->{port}}) {
            push @issues, "Port " . $port_info->{port} . " (" . $port_info->{service} . ") is not accessible";
        }
    }
    
    # Check SMTP authentication
    push @issues, "SMTP authentication failed" unless $smtp_auth_works;
    
    # Generate recommendations
    if (!$dns_consistent) {
        push @recommendations, "Wait for DNS propagation to complete (can take up to 48 hours)";
    }
    if (!$ptr_record) {
        push @recommendations, "Set up PTR record with your hosting provider";
    }
    if (!$spf_valid) {
        push @recommendations, "Add SPF record: v=spf1 ip4:$EXPECTED_IP ~all";
    }
    if (!$dkim_valid) {
        push @recommendations, "Set up DKIM signing and add DKIM DNS record";
    }
    if (!$dmarc_valid) {
        push @recommendations, "Add DMARC record: v=DMARC1; p=none; rua=mailto:postmaster\@$DOMAIN";
    }
    
    # Print results
    print "\nIssues Found:\n";
    if (@issues) {
        foreach my $issue (@issues) {
            print colored("❌ $issue\n", 'red');
        }
    } else {
        print colored("✓ No issues found\n", 'green');
    }
    
    print "\nRecommendations:\n";
    if (@recommendations) {
        foreach my $rec (@recommendations) {
            print colored("➤ $rec\n", 'yellow');
        }
    } else {
        print colored("✓ No recommendations needed\n", 'green');
    }
}

# Main execution
print "Mail Server Analysis for $DOMAIN\n";
print "Started at: " . localtime() . "\n";
generate_summary();