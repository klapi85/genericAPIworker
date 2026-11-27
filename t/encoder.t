# Tests for encoder.pm: building the ffmpeg command, listing pending uploads,
# and moving files through the upload -> encoded/processed/failed directories.
# A small Perl script stands in for ffmpeg so the tests do not need it installed.

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/..";
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use Test::More;
use encoder qw(encode_command pending_uploads process_upload);

# The command matches the requested encode settings and ends with the output path.
is_deeply([encode_command('ffmpeg', 'in.mp4', 'out.part')], [
    'ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error', '-y',
    '-i', 'in.mp4',
    '-c:v', 'libvpx-vp9', '-b:v', '0', '-crf', '32',
    '-c:a', 'libopus', '-b:a', '128k',
    '-f', 'webm', 'out.part',
], 'builds the VP9/Opus WebM command');

my $root = tempdir(CLEANUP => 1);
my %config = map { $_ => "$root/$_" } qw(upload_dir output_dir done_dir failed_dir);
make_path(values %config);

# Fake ffmpeg: copies the input (the argument after -i) to the output (last
# argument), prefixed with "webm:". Fails when the input contains "bad".
my $fake_ffmpeg = "$root/fake-ffmpeg";
open my $script, '>', $fake_ffmpeg or die "Cannot write $fake_ffmpeg: $!";
print {$script} <<'SCRIPT';
#!/usr/bin/env perl
my ($input) = map { $ARGV[$_ + 1] } grep { $ARGV[$_] eq '-i' } 0 .. $#ARGV;
open my $in, '<', $input or exit 2;
my $data = do { local $/; <$in> };
exit 1 if $data =~ /bad/;
open my $out, '>', $ARGV[-1] or exit 3;
print {$out} "webm:$data";
SCRIPT
close $script;
chmod 0755, $fake_ffmpeg;
$config{ffmpeg} = $fake_ffmpeg;

sub write_file {
    my ($path, $data) = @_;
    open my $fh, '>', $path or die "Cannot write $path: $!";
    print {$fh} $data;
    close $fh;
}

sub read_file {
    my ($path) = @_;
    open my $fh, '<', $path or die "Cannot read $path: $!";
    return do { local $/; <$fh> };
}

write_file("$config{upload_dir}/upload-good", 'video');
write_file("$config{upload_dir}/upload-bad", 'bad video');
write_file("$config{upload_dir}/.hidden", 'x');
make_path("$config{upload_dir}/subdir");

# pending_uploads: regular files only, no dotfiles or directories.
is_deeply([pending_uploads($config{upload_dir})], ['upload-bad', 'upload-good'],
    'lists pending regular files');

# A successful encode writes the result and moves the source to done_dir.
my ($output, $error) = process_upload('upload-good', \%config);
is($error, undef, 'good file encodes without error');
is($output, "$config{output_dir}/upload-good.webm", 'returns the output path');
is(read_file($output), 'webm:video', 'output holds the encoded data');
ok(!-e "$config{upload_dir}/upload-good", 'source is removed from uploads');
ok(-f "$config{done_dir}/upload-good", 'source is moved to done_dir');
ok(!-e "$output.part", 'no partial file is left behind');

# A failed encode moves the source to failed_dir and leaves no output.
($output, $error) = process_upload('upload-bad', \%config);
is($output, undef, 'failed encode returns no output');
like($error, qr/ffmpeg failed with status 1/, 'reports the ffmpeg exit status');
ok(-f "$config{failed_dir}/upload-bad", 'failed source is moved to failed_dir');
ok(!-e "$config{output_dir}/upload-bad.webm", 'no output for a failed encode');
ok(!-e "$config{output_dir}/upload-bad.webm.part", 'partial output is removed');

# Names must be plain file names inside upload_dir.
like((process_upload('../etc/passwd', \%config))[1], qr/Invalid file name/,
    'rejects path traversal');
like((process_upload('.hidden', \%config))[1], qr/Invalid file name/,
    'rejects dotfiles');
like((process_upload('missing', \%config))[1], qr/Cannot open/,
    'reports a missing upload');

is_deeply([pending_uploads($config{upload_dir})], [], 'nothing left to process');

done_testing();
