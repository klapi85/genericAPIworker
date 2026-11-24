#!/usr/bin/env perl

use strict;
use warnings;
use IO::Socket::INET;

my $server = IO::Socket::INET->new(
    LocalAddr => '127.0.0.1',
    LocalPort => 3000,
    Listen    => 10,
    ReuseAddr => 1,
) or die "Could not start server on 127.0.0.1:3000: $!\n";

$| = 1;
print "Listening on http://127.0.0.1:3000\n";

while (my $client = $server->accept()) {
    binmode $client;

    my $request_line = <$client>;
    if (!defined $request_line
        || $request_line !~ /\A(\S+)\s+(\S+)\s+HTTP\/\d(?:\.\d)?\r?\n\z/) {
        send_response($client, '400 Bad Request', "Bad Request\n");
        close $client;
        next;
    }

    my ($method, $path) = ($1, $2);
    my $content_length = 0;
    my $headers_valid = 1;

    while (my $line = <$client>) {
        last if $line eq "\r\n" || $line eq "\n";

        if ($line =~ /\AContent-Length:\s*(\d+)\s*\r?\n\z/i) {
            $content_length = $1;
        } elsif ($line !~ /\A[^:\r\n]+:\s*.*\r?\n\z/) {
            $headers_valid = 0;
        }
    }

    if (!$headers_valid) {
        send_response($client, '400 Bad Request', "Bad Request\n");
    } elsif ($method ne 'POST') {
        send_response($client, '405 Method Not Allowed', "Method Not Allowed\n",
            'Allow: POST');
    } elsif ($path ne '/') {
        send_response($client, '404 Not Found', "Not Found\n");
    } else {
        my $remaining = $content_length;
        while ($remaining > 0) {
            my $buffer;
            my $read = read($client, $buffer, $remaining);
            last if !defined($read) || $read == 0;
            $remaining -= $read;
        }

        if ($remaining > 0) {
            send_response($client, '400 Bad Request', "Bad Request\n");
        } else {
            send_response($client, '200 OK', 'Hello World');
        }
    }

    close $client;
}

sub send_response {
    my ($client, $status, $body, $extra_header) = @_;
    my $headers = "HTTP/1.1 $status\r\n"
        . "Content-Type: text/plain; charset=utf-8\r\n"
        . 'Content-Length: ' . length($body) . "\r\n"
        . "Connection: close\r\n";
    $headers .= "$extra_header\r\n" if defined $extra_header;
    print {$client} $headers . "\r\n" . $body;
}
