#!/usr/bin/env perl

use strict;
use warnings;
use FindBin qw($Bin);
use lib $Bin;
use IO::Socket::INET;
use File::Path qw(make_path);
use File::Temp qw(tempfile);
use helpers qw(extract_uploaded_file format_response);

my $max_file_size = 5 * 1000 * 1000;
my $upload_dir = "$Bin/uploads";
if (!-d $upload_dir) {
    make_path($upload_dir);
}
die "Upload path is not a directory: $upload_dir\n" if !-d $upload_dir;

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
    my $content_type;
    my $content_length_seen = 0;
    my $transfer_encoding_seen = 0;

    while (my $line = <$client>) {
        last if $line eq "\r\n" || $line eq "\n";

        if ($line =~ /\AContent-Length:\s*(\d+)\s*\r?\n\z/i) {
            if ($content_length_seen) {
                $headers_valid = 0;
            }
            $content_length = $1;
            $content_length_seen = 1;
        } elsif ($line =~ /\AContent-Type:\s*(.*?)\s*\r?\n\z/i) {
            $content_type = $1;
        } elsif ($line =~ /\ATransfer-Encoding:/i) {
            $transfer_encoding_seen = 1;
        } elsif ($line !~ /\A[^:\r\n]+:\s*.*\r?\n\z/) {
            $headers_valid = 0;
        }
    }

    if (!$headers_valid) {
        send_response($client, '400 Bad Request', "Bad Request\n");
    } elsif ($transfer_encoding_seen) {
        send_response($client, '501 Not Implemented', "Transfer-Encoding is not supported\n");
    } elsif ($method ne 'POST') {
        send_response($client, '405 Method Not Allowed', "Method Not Allowed\n",
            'Allow: POST');
    } elsif ($path eq '/hello') {
        send_response($client, '200 OK', 'Hello World');
    } elsif ($path eq '/process-file') {
        my $max_request_size = $max_file_size + 64 * 1024;
        if (!$content_length_seen) {
            send_response($client, '411 Length Required', "Content-Length is required\n");
        } elsif ($content_length > $max_request_size) {
            send_response($client, '413 Content Too Large', "Request is too large\n");
        } else {
            my $body = '';
            my $remaining = $content_length;
            while ($remaining > 0) {
                my $buffer;
                my $read = read($client, $buffer, $remaining);
                last if !defined($read) || $read == 0;
                $body .= $buffer;
                $remaining -= $read;
            }

            if ($remaining > 0) {
                send_response($client, '400 Bad Request', "Bad Request\n");
            } else {
                my ($file_data, $parse_error) = extract_uploaded_file($body, $content_type);
                if (defined $parse_error) {
                    send_response($client, '400 Bad Request', "$parse_error\n");
                } elsif (length($file_data) > $max_file_size) {
                    send_response($client, '413 Content Too Large',
                        "File must not be larger than 5 MB\n");
                } else {
                    my ($file_handle, $file_path) = tempfile(
                        'upload-XXXXXXXX',
                        DIR    => $upload_dir,
                        UNLINK => 0,
                    );
                    binmode $file_handle;
                    my $write_ok = print {$file_handle} $file_data;
                    my $close_ok = close $file_handle;
                    if (!$write_ok || !$close_ok) {
                        my $error = $!;
                        unlink $file_path;
                        warn "Could not save uploaded file: $error\n";
                        send_response($client, '500 Internal Server Error',
                            "Could not save uploaded file\n");
                    } else {
                        my ($saved_name) = $file_path =~ m{([^/]+)\z};
                        send_response($client, '201 Created',
                            "File uploaded as $saved_name\n");
                    }
                }
            }
        }
    } else {
        send_response($client, '404 Not Found', "Not Found\n");
    }

    close $client;
}

sub send_response {
    my ($client, $status, $body, $extra_header) = @_;
    print {$client} format_response($status, $body, $extra_header);
}
