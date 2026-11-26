use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/..";
use Test::More;
use helpers qw(extract_uploaded_file format_response read_request read_request_body);

sub input_handle {
    my ($data) = @_;
    open my $handle, '<', \$data or die "Could not open scalar input: $!";
    binmode $handle;
    return $handle;
}

my $request_reader = input_handle(
    "POST /process-file HTTP/1.1\r\n"
        . "Content-Length: 42\r\n"
        . "Content-Type: multipart/form-data; boundary=example\r\n"
        . "\r\n",
);
my $request = read_request($request_reader);
is_deeply(
    $request,
    {
        method                 => 'POST',
        path                   => '/process-file',
        content_length         => 42,
        content_length_seen    => 1,
        content_type           => 'multipart/form-data; boundary=example',
        transfer_encoding_seen => 0,
    },
    'parses the request line and headers',
);

my $bad_request_reader = input_handle("POST /hello\r\n\r\n");
ok(!defined read_request($bad_request_reader), 'rejects a malformed request line');

my $bad_headers_reader = input_handle(
    "POST /hello HTTP/1.1\r\n"
        . "Content-Length: 1\r\n"
        . "Content-Length: 2\r\n"
        . "\r\n",
);
ok(!defined read_request($bad_headers_reader), 'rejects duplicate Content-Length headers');

my $transfer_reader = input_handle(
    "POST /hello HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
);
my $transfer_request = read_request($transfer_reader);
ok($transfer_request->{transfer_encoding_seen}, 'records Transfer-Encoding headers');

my $binary_request_body = "data\0with binary\r\n";
my $body_reader = input_handle($binary_request_body);
is(
    read_request_body($body_reader, length $binary_request_body),
    $binary_request_body,
    'reads the complete request body without changing binary data',
);

my $short_body_reader = input_handle('short');
ok(!defined read_request_body($short_body_reader, 10), 'rejects an incomplete request body');

my $boundary = 'test-boundary';
sub multipart_part {
    my ($field_name, $filename, $file_data, $boundary_value) = @_;
    return qq(Content-Disposition: form-data; name="$field_name"; filename="$filename"\r\n)
        . "Content-Type: application/octet-stream\r\n\r\n"
        . $file_data;
}

sub multipart_body {
    my ($field_name, $filename, $file_data, $boundary_value) = @_;
    return "--$boundary_value\r\n"
        . multipart_part($field_name, $filename, $file_data, $boundary_value)
        . "\r\n--$boundary_value--\r\n";
}

my $binary_data = "hello\0world\r\n--${boundary}x";
my $body = multipart_body('file', 'sample.bin', $binary_data, $boundary);
my ($file_data, $error) = extract_uploaded_file(
    $body,
    "multipart/form-data; boundary=$boundary",
);
is($file_data, $binary_data, 'extracts a binary file without altering its contents');
ok(!defined $error, 'successful extraction has no error');

my ($quoted_data, $quoted_error) = extract_uploaded_file(
    multipart_body('file', 'quoted.txt', 'contents', $boundary),
    qq(multipart/form-data; boundary="$boundary"),
);
is($quoted_data, 'contents', 'accepts a quoted multipart boundary');
ok(!defined $quoted_error, 'quoted boundary extraction has no error');

my ($missing_data, $missing_error) = extract_uploaded_file(
    multipart_body('other', 'sample.bin', 'contents', $boundary),
    "multipart/form-data; boundary=$boundary",
);
ok(!defined $missing_data, 'does not extract an incorrectly named field');
like($missing_error, qr/must include a file field named "file"/, 'reports a missing file field');

my $duplicate_body = "--$boundary\r\n"
    . multipart_part('file', 'first.txt', 'one', $boundary)
    . "\r\n--$boundary\r\n"
    . multipart_part('file', 'second.txt', 'two', $boundary)
    . "\r\n--$boundary--\r\n";
my ($duplicate_data, $duplicate_error) = extract_uploaded_file(
    $duplicate_body,
    "multipart/form-data; boundary=$boundary",
);
ok(!defined $duplicate_data, 'does not extract duplicate file fields');
like($duplicate_error, qr/Only one file field/, 'reports duplicate file fields');

my ($not_multipart_data, $not_multipart_error) =
    extract_uploaded_file('', 'text/plain');
ok(!defined $not_multipart_data, 'rejects non-multipart requests');
like($not_multipart_error, qr/multipart\/form-data/, 'reports expected content type');

my ($malformed_data, $malformed_error) =
    extract_uploaded_file('not a multipart body', "multipart/form-data; boundary=$boundary");
ok(!defined $malformed_data, 'rejects malformed multipart bodies');
like($malformed_error, qr/Malformed multipart body/, 'reports malformed multipart body');

my $response = format_response('405 Method Not Allowed', "Method Not Allowed\n", 'Allow: POST');
like($response, qr/\AHTTP\/1\.1 405 Method Not Allowed\r\n/, 'formats the status line');
like($response, qr/Content-Length: 19\r\n/, 'formats the response content length');
like($response, qr/Allow: POST\r\n/, 'includes an optional response header');
like($response, qr/\r\n\r\nMethod Not Allowed\n\z/, 'separates headers from response body');

done_testing();
