package helpers;

use strict;
use warnings;
use Exporter qw(import);

our @EXPORT_OK = qw(extract_uploaded_file format_response read_request read_request_body);

sub read_request {
    my ($client) = @_;

    my $request_line = <$client>;
    return if !defined $request_line
        || $request_line !~ /\A(\S+)\s+(\S+)\s+HTTP\/\d(?:\.\d)?\r?\n\z/;
    my ($method, $path) = ($1, $2);

    my $content_length = 0;
    my $content_type;
    my $content_length_seen = 0;
    my $transfer_encoding_seen = 0;

    while (my $line = <$client>) {
        last if $line eq "\r\n" || $line eq "\n";

        if ($line =~ /\AContent-Length:\s*(\d+)\s*\r?\n\z/i) {
            return if $content_length_seen;
            $content_length = $1;
            $content_length_seen = 1;
        } elsif ($line =~ /\AContent-Type:\s*(.*?)\s*\r?\n\z/i) {
            $content_type = $1;
        } elsif ($line =~ /\ATransfer-Encoding:/i) {
            $transfer_encoding_seen = 1;
        } elsif ($line !~ /\A[^:\r\n]+:\s*.*\r?\n\z/) {
            return;
        }
    }

    return {
        method                  => $method,
        path                    => $path,
        content_length          => $content_length,
        content_length_seen     => $content_length_seen,
        content_type            => $content_type,
        transfer_encoding_seen  => $transfer_encoding_seen,
    };
}

sub read_request_body {
    my ($client, $content_length) = @_;
    my $body = '';
    my $remaining = $content_length;

    while ($remaining > 0) {
        my $buffer;
        my $read = read($client, $buffer, $remaining);
        return if !defined($read) || $read == 0;
        $body .= $buffer;
        $remaining -= $read;
    }

    return $body;
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

sub format_response {
    my ($status, $body, $extra_header) = @_;
    my $headers = "HTTP/1.1 $status\r\n"
        . "Content-Type: text/plain; charset=utf-8\r\n"
        . 'Content-Length: ' . length($body) . "\r\n"
        . "Connection: close\r\n";
    $headers .= "$extra_header\r\n" if defined $extra_header;
    return $headers . "\r\n" . $body;
}

1;
