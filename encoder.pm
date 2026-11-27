package encoder;

use strict;
use warnings;
use Exporter qw(import);
use Fcntl qw(:flock);
use File::Copy qw(move);

our @EXPORT_OK = qw(
    encode_command
    pending_uploads
    process_upload
);

# Returns the ffmpeg command (as a list, so no shell is involved) that encodes
# $input to VP9/Opus WebM at $output. The format is given explicitly because
# $output is a temporary name without a .webm extension.
sub encode_command {
    my ($ffmpeg, $input, $output) = @_;
    return (
        $ffmpeg, '-nostdin', '-hide_banner', '-loglevel', 'error', '-y',
        '-i', $input,
        '-c:v', 'libvpx-vp9', '-b:v', '0', '-crf', '32',
        '-c:a', 'libopus', '-b:a', '128k',
        '-f', 'webm', $output,
    );
}

# Lists the names of regular files waiting in $dir, skipping dotfiles.
sub pending_uploads {
    my ($dir) = @_;
    opendir my $dh, $dir or die "Cannot open $dir: $!\n";
    my @names = sort grep { !/\A\./ && -f "$dir/$_" } readdir $dh;
    closedir $dh;
    return @names;
}

# Encodes one uploaded file. $config needs upload_dir, output_dir, done_dir,
# failed_dir and ffmpeg. On success the result is written to
# output_dir/<name>.webm and the source is moved to done_dir; on failure the
# source is moved to failed_dir so it is not retried forever.
# Returns ($output_path, undef) on success or (undef, $error).
sub process_upload {
    my ($name, $config) = @_;
    # Only plain names inside upload_dir, never paths.
    return (undef, "Invalid file name: $name")
        if $name !~ /\A[A-Za-z0-9_-][A-Za-z0-9._-]*\z/;

    my $source = "$config->{upload_dir}/$name";
    # Lock the source so two processor runs never encode the same file.
    open my $lock, '<', $source or return (undef, "Cannot open $source: $!");
    return (undef, "$name is already being processed")
        if !flock($lock, LOCK_EX | LOCK_NB);
    # Another run may have finished and moved the file while we waited.
    return (undef, "$name was already processed") if !-f $source;

    my $output = "$config->{output_dir}/$name.webm";
    # Encode to a temporary name so output_dir only ever holds finished files.
    my $partial = "$output.part";
    my $exit = system(encode_command($config->{ffmpeg}, $source, $partial));
    if ($exit != 0) {
        my $reason = $exit == -1
            ? "Could not run $config->{ffmpeg}: $!"
            : 'ffmpeg failed with status ' . ($? >> 8);
        unlink $partial;
        move($source, "$config->{failed_dir}/$name")
            or $reason .= "; could not move source to $config->{failed_dir}: $!";
        return (undef, $reason);
    }

    rename $partial, $output
        or return (undef, "Could not rename $partial to $output: $!");
    move($source, "$config->{done_dir}/$name")
        or return (undef, "Encoded $output but could not move source: $!");
    return ($output, undef);
}

1;
