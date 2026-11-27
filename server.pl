#!/usr/bin/env perl

use strict;
use warnings;
use FindBin qw($Bin);
use lib $Bin;
use IO::Socket::INET;
use File::Path qw(make_path);
use POSIX ();
use helpers qw(format_response handle_request);

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
# Processor children are not waited for; ignoring SIGCHLD stops them becoming zombies.
$SIG{CHLD} = 'IGNORE';
print "Listening on http://127.0.0.1:3000\n";

while (my $client = $server->accept()) {
    binmode $client;
    send_response($client, handle_request($client, {
        upload_dir    => $upload_dir,
        max_file_size => $max_file_size,
        on_upload     => \&start_processor,
    }));
    close $client;
}

sub send_response {
    my ($client, $status, $body, $extra_header) = @_;
    print {$client} format_response($status, $body, $extra_header);
}

# Starts process_uploads.pl for one saved upload in the background, so the
# client gets its response without waiting for the encode.
sub start_processor {
    my ($name) = @_;
    my $pid = fork;
    if (!defined $pid) {
        warn "Could not start processor for $name: $!\n";
        return;
    }
    return if $pid;

    open STDIN, '<', '/dev/null';
    exec $^X, "$Bin/process_uploads.pl", $name;
    warn "Could not run process_uploads.pl: $!\n";
    # Leave without running END blocks or destructors shared with the server.
    POSIX::_exit(1);
}
