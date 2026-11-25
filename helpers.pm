package helpers;

use strict;
use warnings;
use Exporter qw(import);
use File::Temp qw(tempfile);

our @EXPORT_OK = qw(
    extract_uploaded_file
    format_response
    handle_request
    parse_request_line
    process_file_upload
    read_body
    read_headers
    save_upload
);

my @BAD_REQUEST = ('400 Bad Request', "Bad Request\n");

# Reads one HTTP request from $fh and returns the response as
# ($status, $body, $extra_header). $options needs upload_dir and max_file_size.
sub handle_request {
    my ($fh, $options) = @_;

    my ($method, $path) = parse_request_line(scalar <$fh>);
    return @BAD_REQUEST if !defined $method;

    my $headers = read_headers($fh);
    return @BAD_REQUEST if !$headers->{valid};
    return ('501 Not Implemented', "Transfer-Encoding is not supported\n")
        if $headers->{transfer_encoding_seen};
    return ('405 Method Not Allowed', "Method Not Allowed\n", 'Allow: POST')
        if $method ne 'POST';
    return ('200 OK', 'Hello World') if $path eq '/hello';
    return process_file_upload($fh, $headers, $options) if $path eq '/process-file';
    return ('404 Not Found', "Not Found\n");
}

sub parse_request_line {
    my ($line) = @_;
    return if !defined $line;
    return if $line !~ /\A(\S+)\s+(\S+)\s+HTTP\/\d(?:\.\d)?\r?\n\z/;
    return ($1, $2);
}

sub read_headers {
    my ($fh) = @_;
    my %headers = (
        content_length         => 0,
        content_length_seen    => 0,
        content_type           => undef,
        transfer_encoding_seen => 0,
        valid                  => 1,
    );

    while (my $line = <$fh>) {
        last if $line eq "\r\n" || $line eq "\n";

        if ($line =~ /\AContent-Length:\s*(\d+)\s*\r?\n\z/i) {
            $headers{valid} = 0 if $headers{content_length_seen};
            $headers{content_length} = $1;
            $headers{content_length_seen} = 1;
        } elsif ($line =~ /\AContent-Type:\s*(.*?)\s*\r?\n\z/i) {
            $headers{content_type} = $1;
        } elsif ($line =~ /\ATransfer-Encoding:/i) {
            $headers{transfer_encoding_seen} = 1;
        } elsif ($line !~ /\A[^:\r\n]+:\s*.*\r?\n\z/) {
            $headers{valid} = 0;
        }
    }

    return \%headers;
}

# Returns exactly $length bytes from $fh, or undef if the stream ends early.
sub read_body {
    my ($fh, $length) = @_;
    my $body = '';
    my $remaining = $length;
    while ($remaining > 0) {
        my $read = read($fh, my $buffer, $remaining);
        return undef if !$read;
        $body .= $buffer;
        $remaining -= $read;
    }
    return $body;
}

sub process_file_upload {
    my ($fh, $headers, $options) = @_;
    my $max_file_size = $options->{max_file_size};
    my $max_request_size = $max_file_size + 64 * 1024;

    return ('411 Length Required', "Content-Length is required\n")
        if !$headers->{content_length_seen};
    return ('413 Content Too Large', "Request is too large\n")
        if $headers->{content_length} > $max_request_size;

    my $body = read_body($fh, $headers->{content_length});
    return @BAD_REQUEST if !defined $body;

    my ($file_data, $parse_error) =
        extract_uploaded_file($body, $headers->{content_type});
    return ('400 Bad Request', "$parse_error\n") if defined $parse_error;
    return ('413 Content Too Large', "File must not be larger than 5 MB\n")
        if length($file_data) > $max_file_size;

    my ($saved_name, $save_error) = save_upload($options->{upload_dir}, $file_data);
    if (defined $save_error) {
        warn "Could not save uploaded file: $save_error\n";
        return ('500 Internal Server Error', "Could not save uploaded file\n");
    }
    return ('201 Created', "File uploaded as $saved_name\n");
}

# Writes $data to a new file in $dir. Returns ($saved_name, undef) or (undef, $error).
sub save_upload {
    my ($dir, $data) = @_;
    my ($file_handle, $file_path) = tempfile(
        'upload-XXXXXXXX',
        DIR    => $dir,
        UNLINK => 0,
    );
    binmode $file_handle;
    my $write_ok = print {$file_handle} $data;
    my $close_ok = close $file_handle;
    if (!$write_ok || !$close_ok) {
        my $error = "$!";
        unlink $file_path;
        return (undef, $error);
    }
    my ($saved_name) = $file_path =~ m{([^/]+)\z};
    return ($saved_name, undef);
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
