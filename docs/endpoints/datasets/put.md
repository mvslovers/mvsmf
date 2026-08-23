# Write Dataset

Writes content to a sequential dataset in text or binary mode. Handles both chunked transfer encoding and Content-Length based transfers. `X-IBM-Data-Type: record` is accepted on read but **not implemented on write** — see below.

## HTTP Method
PUT

## URL Path
`/zosmf/restfiles/ds/{dataset-name}`

or with explicit volume:

`/zosmf/restfiles/ds/-({volume-serial})/{dataset-name}`

## Path Parameters
- `dataset-name`: Name of the dataset to write
- `volume-serial` (optional): Volume serial number

## Request Headers
- `Content-Length` or `Transfer-Encoding: chunked`: One of these is required
- `X-IBM-Data-Type` (optional): Data transfer mode
    - `text` (default): ASCII-to-EBCDIC conversion, records split at newlines
    - `binary`: Raw bytes written without conversion, split at LRECL boundaries
    - `record`: **accepted but not implemented on write — do not use.** The read
      path emits a 4-byte big-endian length before every record; the write path
      frames nothing. `record` is sent down the *text* loop, which cuts the body
      at newlines, so the four bytes then taken as a length are one only by
      accident: the request stores garbage or answers 500. **A body produced by
      a `GET` with `X-IBM-Data-Type: record` cannot be written back** — use
      `binary` for a byte-exact round trip. Whether this becomes a
      length-prefixed reader or an outright 400 is issue #245.
- `If-Match` (optional): An `ETag` from an earlier read; the write proceeds only
  if the dataset still matches it.
- `X-IBM-Return-Etag` (optional): `true` returns the `ETag` of the dataset as it
  stands after the write.

Both behave exactly as on the member endpoint, including the requirement to
take the next `If-Match` from the PUT response rather than reusing the
pre-save value — see
[members-put.md](members-put.md#conditional-writes-optimistic-locking).

## Response
On successful completion, this request returns HTTP status code 204 (No Content).

## Error Responses
- HTTP 400 (Bad Request)
    - Dataset is a PDS (use the member endpoint instead)
    - Missing Content-Length or Transfer-Encoding header
- HTTP 412 (Precondition Failed)
    - `If-Match` was supplied and the dataset no longer matches it (`reason` 10).
      Nothing was written.
- HTTP 500 (Internal Server Error)
    - Dataset not found or cannot be opened for writing
    - I/O error during write
    - The dataset ran out of space mid-upload. The write abends, the router's
      recovery closes and frees the DD, and the message names the abend:
      `Internal server error (abend SB37: out of space on the volume)`,
      `SD37: primary extent full, no secondary allocation` or
      `SE37: extent limit reached` (issue #256). Any other handler abend
      carries its code the same way, e.g. `(abend S0C4)`. The dataset is left
      as the abend left it — the upload is not retried.

## Text mode framing
- A record ends at LF, CR or CRLF. The terminator is not part of the record.
- A line of exactly LRECL characters is accepted. A longer line is **truncated
  to LRECL** — the overflow is discarded, the record is written, the rest of the
  body is written after it, and the request then answers 500 "Record truncated
  to the record length of the data set". It is never silently split across two
  records. Until issue #233 the usable length was LRECL-2, so 80-column source
  could not be uploaded into an FB80 dataset at all.
- For RECFM=V the usable line length is LRECL-4: the record descriptor word is
  not content. A longer line used to be split into a second record without
  notice, and is now truncated like any other.
- A blank line is written as a record of blanks — it used to disappear (#233).
- A body whose last line carries no terminator still produces that record, and
  a body ending in a newline does not gain a trailing blank one.
- With `Transfer-Encoding: chunked` a line split across two chunks stays one
  record; a chunk boundary is a transport boundary, not a record boundary.

## Limitations
- Only sequential (PS) datasets are supported; PDS datasets return HTTP 400
- Binary mode: the final incomplete record is padded with binary zeros to LRECL
- A request that produces **no record at all** leaves the dataset exactly as it
  was — a dropped connection, a body that never arrives. The dataset is not
  opened for output until there is a record to put in it (issue #246). An
  over-long first line is no longer such a case: it is truncated to LRECL and
  written like any other record.
- **A failed write does not roll back, and real z/OSMF does not roll back
  either.** Measured on version 29 (#243): a body whose second of three lines is
  200 characters lands in an FB/80 data set as three records of 5, 80 and 6, the
  previous content replaced, and answers 500. mvsMF matches that. Staging the
  write elsewhere and swapping it in would turn a PUT into
  allocate/write/delete/rename and would not buy conformance, because there is
  nothing to conform to.
- An empty body is a truncate, not a no-op: `Content-Length: 0` empties the
  dataset.

There is no fixed upper bound on the record size: the write buffer is sized
from the dataset's own DCB (LRECL, or BLKSIZE for RECFM=U). Records above
1024 bytes used to overrun a fixed conversion buffer and abend the handler
(issue #198).

## Authorization

Requires **UPDATE** on the data set (ALTER on both names for a rename) in class `DATASET` (issue #228). The check runs
before any catalog, VTOC or data set access, so a refusal is indistinguishable
from "does not exist".

A refusal answers **HTTP 500** with `category 4`, `rc 8`, `reason 0` and the
explanation in `details[]` — the shape a real z/OSMF sends; 403 is not a z/OSMF
status. See [authorization.md](authorization.md).

## Examples

### Using curl
```bash
# Text mode (default)
curl -X PUT \
  -H "Content-Type: application/octet-stream" \
  --data-binary @mydata.txt \
  http://mvs:1080/zosmf/restfiles/ds/MIKE.TEST.DATA

# Binary mode
curl -X PUT \
  -H "X-IBM-Data-Type: binary" \
  --data-binary @upload.xmi \
  http://mvs:1080/zosmf/restfiles/ds/MIKE.LOAD.XMI
```

### Using Zowe CLI
```bash
zowe files upload ftds mydata.txt "MIKE.TEST.DATA"
zowe files upload ftds upload.xmi "MIKE.LOAD.XMI" -b
```
