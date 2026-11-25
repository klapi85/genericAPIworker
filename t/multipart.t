# Tests for extract_uploaded_file: parsing a multipart/form-data request body
# and pulling out the single file field named "file".

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/..";
use Test::More;
use helpers qw(extract_uploaded_file);

my $boundary = 'test-boundary';

# Builds one multipart part (headers + data) for a file field, without boundaries.
sub multipart_part {
    my ($field_name, $filename, $file_data, $boundary_value) = @_;
    return qq(Content-Disposition: form-data; name="$field_name"; filename="$filename"\r\n)
        . "Content-Type: application/octet-stream\r\n\r\n"
        . $file_data;
}

# Wraps a single part in opening and closing boundary lines to make a full body.
sub multipart_body {
    my ($field_name, $filename, $file_data, $boundary_value) = @_;
    return "--$boundary_value\r\n"
        . multipart_part($field_name, $filename, $file_data, $boundary_value)
        . "\r\n--$boundary_value--\r\n";
}

# The data contains NUL, CRLF and something that looks like the boundary,
# so this checks the parser only splits on a real boundary line.
my $binary_data = "hello\0world\r\n--${boundary}x";
my $body = multipart_body('file', 'sample.bin', $binary_data, $boundary);
my ($file_data, $error) = extract_uploaded_file(
    $body,
    "multipart/form-data; boundary=$boundary",
);
is($file_data, $binary_data, 'extracts a binary file without altering its contents');
ok(!defined $error, 'successful extraction has no error');

# The boundary may be quoted in the Content-Type header.
my ($quoted_data, $quoted_error) = extract_uploaded_file(
    multipart_body('file', 'quoted.txt', 'contents', $boundary),
    qq(multipart/form-data; boundary="$boundary"),
);
is($quoted_data, 'contents', 'accepts a quoted multipart boundary');
ok(!defined $quoted_error, 'quoted boundary extraction has no error');

# A file under any other field name is ignored, so the request has no "file" field.
my ($missing_data, $missing_error) = extract_uploaded_file(
    multipart_body('other', 'sample.bin', 'contents', $boundary),
    "multipart/form-data; boundary=$boundary",
);
ok(!defined $missing_data, 'does not extract an incorrectly named field');
like($missing_error, qr/must include a file field named "file"/, 'reports a missing file field');

# Two parts named "file" are rejected instead of picking one.
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

# Error cases: wrong Content-Type, and a body without the opening boundary.
my ($not_multipart_data, $not_multipart_error) =
    extract_uploaded_file('', 'text/plain');
ok(!defined $not_multipart_data, 'rejects non-multipart requests');
like($not_multipart_error, qr/multipart\/form-data/, 'reports expected content type');

my ($malformed_data, $malformed_error) =
    extract_uploaded_file('not a multipart body', "multipart/form-data; boundary=$boundary");
ok(!defined $malformed_data, 'rejects malformed multipart bodies');
like($malformed_error, qr/Malformed multipart body/, 'reports malformed multipart body');

done_testing();
