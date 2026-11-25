use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/..";
use File::Temp qw(tempdir);
use Test::More;
use helpers qw(handle_request parse_request_line read_body read_headers);

sub fh_for {
    my ($data) = @_;
    open my $fh, '<', \$data or die "Cannot open in-memory filehandle: $!";
    binmode $fh;
    return $fh;
}

my $upload_dir = tempdir(CLEANUP => 1);
my %options = (upload_dir => $upload_dir, max_file_size => 100);

sub request {
    my ($raw, $opts) = @_;
    return handle_request(fh_for($raw), $opts || \%options);
}

# parse_request_line
is_deeply([parse_request_line("POST /hello HTTP/1.1\r\n")], ['POST', '/hello'],
    'parses a valid request line');
is_deeply([parse_request_line("GET / HTTP/1.0\n")], ['GET', '/'],
    'accepts bare LF request lines');
is_deeply([parse_request_line("garbage\r\n")], [], 'rejects a malformed request line');
is_deeply([parse_request_line(undef)], [], 'rejects a missing request line');

# read_headers
my $headers = read_headers(fh_for(
    "Content-Length: 12\r\nContent-Type: text/plain \r\nX-Other: yes\r\n\r\nbody"));
is($headers->{content_length}, 12, 'reads Content-Length');
ok($headers->{content_length_seen}, 'marks Content-Length as seen');
is($headers->{content_type}, 'text/plain', 'reads and trims Content-Type');
ok($headers->{valid}, 'valid headers are marked valid');

ok(!read_headers(fh_for("Content-Length: 1\r\nContent-Length: 1\r\n\r\n"))->{valid},
    'duplicate Content-Length is invalid');
ok(!read_headers(fh_for("not a header\r\n\r\n"))->{valid},
    'malformed header line is invalid');
ok(read_headers(fh_for("Transfer-Encoding: chunked\r\n\r\n"))->{transfer_encoding_seen},
    'detects Transfer-Encoding');

my $after_headers = fh_for("A: b\r\n\r\nrest");
read_headers($after_headers);
is(do { local $/; <$after_headers> }, 'rest', 'stops reading at the blank line');

# read_body
is(read_body(fh_for("abcdef"), 4), 'abcd', 'reads exactly the requested length');
is(read_body(fh_for(''), 0), '', 'reads an empty body');
ok(!defined read_body(fh_for("abc"), 10), 'returns undef on a short body');

# handle_request routing
is((request("garbage\r\n\r\n"))[0], '400 Bad Request', 'bad request line -> 400');
is((request("POST /hello HTTP/1.1\r\nbad\r\n\r\n"))[0], '400 Bad Request',
    'bad header -> 400');
is((request("POST /hello HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"))[0],
    '501 Not Implemented', 'Transfer-Encoding -> 501');

my @not_allowed = request("GET /hello HTTP/1.1\r\n\r\n");
is($not_allowed[0], '405 Method Not Allowed', 'non-POST -> 405');
is($not_allowed[2], 'Allow: POST', '405 includes Allow header');

is_deeply([request("POST /hello HTTP/1.1\r\n\r\n")], ['200 OK', 'Hello World'],
    'POST /hello -> Hello World');
is((request("POST /missing HTTP/1.1\r\n\r\n"))[0], '404 Not Found', 'unknown path -> 404');

# /process-file
my $boundary = 'b0undary';
sub upload_request {
    my ($file_data, %args) = @_;
    my $body = $args{body} // "--$boundary\r\n"
        . qq(Content-Disposition: form-data; name="file"; filename="a.bin"\r\n\r\n)
        . $file_data
        . "\r\n--$boundary--\r\n";
    my $length = $args{content_length} // length($body);
    my $content_type = $args{content_type} // "multipart/form-data; boundary=$boundary";
    my $length_header = $args{no_length} ? '' : "Content-Length: $length\r\n";
    return "POST /process-file HTTP/1.1\r\n"
        . $length_header
        . "Content-Type: $content_type\r\n\r\n"
        . $body;
}

my ($status, $message) = request(upload_request("hello\0world"));
is($status, '201 Created', 'valid upload -> 201');
my ($saved_name) = $message =~ /File uploaded as (\S+)/;
ok(defined $saved_name, 'response names the saved file');
my $saved_path = "$upload_dir/$saved_name";
open my $saved_fh, '<:raw', $saved_path or die "Cannot open $saved_path: $!";
is(do { local $/; <$saved_fh> }, "hello\0world", 'saved file matches uploaded bytes');
close $saved_fh;

is((request(upload_request('x', no_length => 1)))[0], '411 Length Required',
    'missing Content-Length -> 411');
is((request(upload_request('x', content_length => 100 + 64 * 1024 + 1)))[0],
    '413 Content Too Large', 'oversized request -> 413');
is((request(upload_request('x', content_length => 500)))[0], '400 Bad Request',
    'truncated body -> 400');

my @wrong_type = request(upload_request('x', content_type => 'text/plain'));
is($wrong_type[0], '400 Bad Request', 'non-multipart upload -> 400');
like($wrong_type[1], qr/multipart\/form-data/, 'reports the parse error');

my @too_big = request(upload_request('x' x 101));
is($too_big[0], '413 Content Too Large', 'file over max_file_size -> 413');
like($too_big[1], qr/File must not be larger/, 'reports the file size limit');

done_testing();
