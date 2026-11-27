#!/usr/bin/env perl

# Encodes uploaded MP4 files to WebM.
#
#   perl process_uploads.pl [NAME ...]
#
# With names, processes those files from uploads/; without, processes every
# file currently in uploads/. Results go to encoded/, sources are moved to
# processed/ when done or to failed/ if encoding fails. Set FFMPEG to use a
# different ffmpeg binary.

use strict;
use warnings;
use FindBin qw($Bin);
use lib $Bin;
use File::Path qw(make_path);
use encoder qw(pending_uploads process_upload);

# The server ignores SIGCHLD and that is inherited across exec; restore it so
# system() can collect ffmpeg's exit status.
$SIG{CHLD} = 'DEFAULT';
$| = 1;

my %config = (
    upload_dir => "$Bin/uploads",
    output_dir => "$Bin/encoded",
    done_dir   => "$Bin/processed",
    failed_dir => "$Bin/failed",
    ffmpeg     => $ENV{FFMPEG} || 'ffmpeg',
);
for my $dir (@config{qw(upload_dir output_dir done_dir failed_dir)}) {
    make_path($dir) if !-d $dir;
    die "Not a directory: $dir\n" if !-d $dir;
}

my @names = @ARGV ? @ARGV : pending_uploads($config{upload_dir});
my $failures = 0;
for my $name (@names) {
    my ($output, $error) = process_upload($name, \%config);
    if (defined $error) {
        warn "$name: $error\n";
        $failures++;
    } else {
        print "$name: encoded to $output\n";
    }
}
exit($failures ? 1 : 0);
