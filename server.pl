#!/usr/bin/env perl

use strict;
use warnings;
use FindBin qw($Bin);
use IO::Socket::INET;
use File::Path qw(make_path);
use File::Temp qw(tempfile);

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

sub extract_uploaded_file {
    my ($body, $content_type) = @_;
    return (undef, 'Content-Type must be multipart/form-data')
        if !defined($content_type)
        || $content_type !~ /\Amultipart\/form-data\b/i;

    my ($quoted_boundary, $unquoted_boundary) =
        $content_type =~ /\bboundary=(?:"([^"]+)"|([^;\s]+))/i;
    my $boundary = defined($quoted_boundary) ? $quoted_boundary : $unquoted_boundary;
    return (undef, 'Invalid multipart boundary')
        if !defined($boundary) || $boundary !~ /\A[A-Za-z0-9'()+_,.\/:=?-]{1,70}\z/;

    my $marker = "--$boundary";
    return (undef, 'Malformed multipart body')
        if substr($body, 0, length($marker) + 2) ne "$marker\r\n";

    my $position = length($marker) + 2;
    my $uploaded_file;
    while (1) {
        my ($separator, $after_marker, $suffix);
        my $search_position = $position;
        while (1) {
            $separator = index($body, "\r\n$marker", $search_position);
            return (undef, 'Malformed multipart body') if $separator < 0;

            $after_marker = $separator + 2 + length($marker);
            $suffix = substr($body, $after_marker, 2);
            last if $suffix eq '--' || $suffix eq "\r\n";
            $search_position = $separator + 2;
        }

        my $part = substr($body, $position, $separator - $position);
        my $header_end = index($part, "\r\n\r\n");
        return (undef, 'Malformed multipart part') if $header_end < 0;

        my $part_headers = substr($part, 0, $header_end);
        my $part_data = substr($part, $header_end + 4);
        my $is_file_field = 0;
        for my $header (split /\r\n/, $part_headers) {
            if ($header =~ /\AContent-Disposition:\s*form-data\b(.*)\z/i) {
                my $attributes = $1;
                $is_file_field = 1
                    if $attributes =~ /(?:\A|;)\s*name="file"(?:;|\s*\z)/i
                    && $attributes =~ /(?:\A|;)\s*filename="[^"]*"/i;
            }
        }

        if ($is_file_field) {
            return (undef, 'Only one file field named "file" is allowed')
                if defined $uploaded_file;
            $uploaded_file = $part_data;
        }

        if ($suffix eq '--') {
            my $ending = substr($body, $after_marker + 2);
            return (undef, 'Malformed multipart ending')
                if $ending ne '' && $ending ne "\r\n";
            last;
        }
        $position = $after_marker + 2;
    }

    return (undef, 'Multipart request must include a file field named "file"')
        if !defined $uploaded_file;
    return ($uploaded_file, undef);
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
