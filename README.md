# genericAPIworker
Perl experiment to implement serwer-side file processing.

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
