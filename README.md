# genericAPIworker
Perl exercise to implement server-side file processing.

## API

The API uses only Perl core modules and listens on `127.0.0.1:3000`. On startup,
it creates an `uploads/` directory next to `server.pl` if one does not already
exist.

Start the server:

```sh
perl server.pl
```

In another terminal, send a POST request:

```sh
curl -X POST http://127.0.0.1:3000/hello
```

The response body is:

```text
Hello World
```

Upload a file with a multipart `file` field:

```sh
curl -X POST -F "file=@/path/to/file" http://127.0.0.1:3000/process-file
```

Uploaded files are saved in `uploads/` with generated names. Files larger than
5 MB (5,000,000 bytes) are rejected.

## Video processing

After each successful upload, the server starts `process_uploads.pl` in the
background for the new file. It encodes the MP4 to WebM (VP9 video, Opus audio)
with `ffmpeg`, which must be installed:

```sh
ffmpeg -i upload-XXXXXXXX -c:v libvpx-vp9 -b:v 0 -crf 32 -c:a libopus -b:a 128k upload-XXXXXXXX.webm
```

- `encoded/` holds the finished `.webm` files.
- `processed/` receives the source file once it has been encoded.
- `failed/` receives the source file if `ffmpeg` fails, so it is not retried.

The processor can also be run by hand. With file names it processes those files
from `uploads/`; without, it processes everything still waiting there (for
example after a restart):

```sh
perl process_uploads.pl [upload-XXXXXXXX ...]
```

Set `FFMPEG=/path/to/ffmpeg` to use a different ffmpeg binary.

## Testing

Run the Perl helper tests from the repository root with:

```sh
prove -v
```
