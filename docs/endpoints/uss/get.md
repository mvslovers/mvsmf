# GET /zosmf/restfiles/fs/{filepath} — Read File

Reads the content of a USS file.

## Request

```
GET /zosmf/restfiles/fs/{filepath}
```

### Path Parameters

| Parameter  | Description |
|------------|-------------|
| `filepath` | Absolute path to the file (wildcard capture, includes `/`) |

### Headers

| Header               | Required | Default | Description |
|----------------------|----------|---------|-------------|
| `X-IBM-Data-Type`    | No       | `text`  | `text` or `binary` |
| `X-IBM-Return-Etag`  | No       | —       | `true` returns an `ETag` for the file, for use as `If-Match` on a later write |
| `If-None-Match`      | No       | —       | Makes the read conditional — a file that still holds the stamped state is answered 304 (Not Modified) with the `ETag` and no body |

## Response (200 OK)

### Text Mode (default)

- Content-Type: `text/plain`
- File content is converted from EBCDIC to ASCII (IBM-1047) before it is sent
- Streamed in 4 KB chunks

### Binary Mode

- Content-Type: `application/octet-stream`
- Raw bytes, no encoding conversion

## ETag

With `X-IBM-Return-Etag: true` the response carries an `ETag` header — a
16-hex-digit stamp over the file's content as stored. Sending it back on a
subsequent PUT as `If-Match` makes that write conditional: it succeeds only if
the file still holds the state that was read. See
[put.md](put.md) for the write half.

```
ETag: 3F5C1A9B0000002B
Access-Control-Expose-Headers: ETag
```

Three properties worth relying on:

- **The stamp is over the stored bytes**, not over what the response sends. A
  text read and a binary read of the same file therefore return the *same*
  ETag, even though their bodies differ by the codepage translation.
- **It is a byte-stream stamp**, computed independently of how the file is
  chunked while reading. Nothing about the buffer size or the UFS block layout
  reaches the value.
- **It is opt-in.** Computing it costs a second read pass over the file, so a
  request without the header gets no `ETag` and pays nothing.

`Access-Control-Expose-Headers` is sent alongside because `ETag` is not
CORS-safelisted: without it a cross-origin client reads `null` and cannot tell
that apart from a server with no ETag support.

## Conditional reads (If-None-Match)

Sending the stamp back as `If-None-Match` makes the read conditional. If the
file still holds that state, the answer is **304 Not Modified** with no body;
otherwise it is the normal 200 with the content.

```bash
# First read: keep the stamp
ETAG=$(curl -s -D - -o hello.txt -u IBMUSER:sys1 \
  -H "X-IBM-Return-Etag: true" \
  "http://mvs:1080/zosmf/restfiles/fs/home/ibmuser/hello.txt" \
  | grep -i '^ETag:' | tr -d '\r' | sed 's/^[Ee][Tt][Aa][Gg]: *//')

# Later: 304 while unchanged, 200 with the new content once it changes
curl -s -o hello.txt -w '%{http_code}\n' -H "If-None-Match: ${ETAG}" \
  -u IBMUSER:sys1 "http://mvs:1080/zosmf/restfiles/fs/home/ibmuser/hello.txt"
```

The header takes the same forms as `If-Match`: a bare stamp, a quoted one, a
weak one (`W/"…"`), a comma-separated list, and `*`. **`*` answers 304 for any
file that exists** — per RFC 9110 the wildcard fails the `If-None-Match`
condition whenever a representation is there, and a failed condition on a GET
is a 304. (The opposite reading, "only if it does not exist", is the
conditional-create semantic of a PUT, which this endpoint does not implement.)

Two things it does not do:

- **A request carrying `If-None-Match` gets the `ETag` back either way** — on
  the 304 and on the 200 that follows a change — without `X-IBM-Return-Etag`
  being sent. The stamp had to be computed to answer at all, and a reader
  polling on `If-None-Match` alone would otherwise have no validator to ask
  about the next change with.
- **A 304 saves the transfer, not the read.** The stamp is computed by reading
  the file, so the server does the same work either way; what the client is
  spared is the body on the wire.

A file that cannot be read gets no 304 — the open then produces the real
diagnosis, which is the more specific answer. So a missing file is **404**, and
a directory is **400** (`Is a directory`), exactly as an unconditional read of
either would be.

Since the stamp is over the stored bytes, it does not depend on
`X-IBM-Data-Type`: a stamp taken from a text read still answers 304 on a binary
read of the same unchanged file.

## Error Responses

| Status | Condition |
|--------|-----------|
| 400    | Missing filepath or path is a directory |
| 404    | File not found |
| 414    | Path name too long |
| 500    | I/O error |
| 503    | UFSD subsystem not available |

## Max File Size

64 KB (UFSD Phase 1 — direct blocks only). Reads beyond this limit
will return partial data up to the UFSD_RC_NOSPACE boundary.

## Examples

### Read a text file with curl

```bash
curl -u IBMUSER:sys1 \
  "http://mvs:1080/zosmf/restfiles/fs/home/ibmuser/hello.txt"
```

### Read a binary file with curl

```bash
curl -u IBMUSER:sys1 \
  -H "X-IBM-Data-Type: binary" \
  -o output.bin \
  "http://mvs:1080/zosmf/restfiles/fs/home/ibmuser/data.bin"
```

### Read with Zowe CLI

```bash
zowe files download uf "/home/ibmuser/hello.txt" -f hello.txt
```

## Limitations vs Real z/OSMF

- No `Content-Length` header in response (streamed without prior size calculation)
- No `X-IBM-Intrdr-*` headers for record-mode reading
- No `search` query parameter for in-file searching

## Handler

- Function: `ussGetHandler`
- Source: `src/ussapi.c`
- ASM label: `UAPI0002`
