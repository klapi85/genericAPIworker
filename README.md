# genericAPIworker
Perl experiment to implement serwer-side file processing.

## Hello World API

The API uses only Perl core modules and listens on `127.0.0.1:3000`.

Start the server:

```sh
perl server.pl
```

In another terminal, send a POST request:

```sh
curl -X POST http://127.0.0.1:3000/
```

The response body is:

```text
Hello World
```
