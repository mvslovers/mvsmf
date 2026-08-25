# Write PDS Member

Writes content to a member in a partitioned dataset (PDS) in text or binary mode. Handles both chunked transfer encoding and Content-Length based transfers. `X-IBM-Data-Type: record` is accepted on read but **not implemented on write** — see below.

## HTTP Method
PUT

## URL Path
`/zosmf/restfiles/ds/{dataset-name}({member-name})`

> **There is no `-({volume-serial})` form.** That route was withdrawn in #336:
> it accepted the volume operand and discarded it, so a request naming the
> wrong volume was answered as if it had named the right one. Such a URL is
> answered 404. Restoring it needs a volume-addressed SCRATCH/RENAME in
> libc370 (mvslovers/libc370#143) for the delete and rename paths.

## Path Parameters
- `dataset-name`: Name of the partitioned dataset
- `member-name`: Name of the member to write

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
- `If-Match` (optional): An `ETag` from an earlier read. The write proceeds
  only if the member still matches it (see **Conditional writes** below).
- `X-IBM-Return-Etag` (optional): `true` returns the `ETag` of the member as
  it stands after the write.

## Response
On successful completion, this request returns HTTP status code 204 (No Content).

## Error Responses
- HTTP 400 (Bad Request)
    - Missing Content-Length or Transfer-Encoding header
- HTTP 404 (Not Found)
    - Dataset not cataloged (`reason` 4)
- HTTP 412 (Precondition Failed)
    - `If-Match` was supplied and the member no longer matches it
      (`reason` 10, `The resource was modified since the supplied ETag was
      created`). Nothing was written.
- HTTP 500 (Internal Server Error)
    - The dataset exists but cannot be opened for writing (I/O error)
    - I/O error during write
    - The library ran out of space or directory blocks mid-upload. The write
      abends, the router's recovery closes and frees the DD, and the message
      names the abend: `Internal server error (abend SB37: out of space on the
      volume)`, `SD37: primary extent full, no secondary allocation` or
      `SE37: extent limit reached` (issue #256). Any other handler abend
      carries its code the same way, e.g. `(abend S0C4)`.

Only a missing *dataset* is an error here. A member that does not exist yet is
what a create looks like, and it is written normally.

## Conditional writes (optimistic locking)

Without `If-Match`, a PUT is last-write-wins: whoever saves last wins, and the
edit that was overwritten is gone with no indication that it happened.

`If-Match` closes that hole. Read the member with `X-IBM-Return-Etag: true`,
keep the `ETag`, and send it back when saving. The handler re-reads the member
and compares before opening anything for output:

- Still matching → the write proceeds as normal, 204.
- No longer matching → **412**, and nothing is written. The member on disk is
  untouched, so the client can reload, re-apply its change and save again.

Details that matter in practice:

- **The check runs before the member is opened for output.** That is why a 412
  leaves the previous content intact, unlike the truncation case under
  *Limitations*.
- **Send `X-IBM-Return-Etag: true` on the PUT as well** if the client intends to
  save more than once. The write normalizes what it stores (records split at
  newlines, F/FB padded to LRECL) and the read normalizes back, so the stamp of
  the stored member is generally *not* the stamp of the body that was sent. The
  ETag in the PUT response is computed by re-reading the member afterwards and
  is the one the next `If-Match` must carry. Reusing the pre-save stamp fails.
- **Accepted forms**: bare (`If-Match: 7F3A…`), quoted (`"7F3A…"`), weak
  (`W/"7F3A…"`), a comma-separated list of any of those, and `*`.
- **`*` asserts only that the member exists.** On a member that does not, the
  request fails 412 — that is the "someone deleted it while I was editing" case.
- A **missing data set** is still 404, not 412: the more specific answer wins.
- Without `If-Match` nothing changes; existing clients are unaffected.

## Text mode framing
- A record ends at LF, CR or CRLF. The terminator is not part of the record.
- A line of exactly LRECL characters is accepted. A longer line is **truncated
  to LRECL** — the overflow is discarded, the record is written, the rest of the
  body is written after it, and the request then answers 500 "Record truncated
  to the record length of the data set". It is never silently split across two
  records. Until issue #233 the usable length was LRECL-2, so 80-column source
  could not be uploaded into an FB80 library at all.
- For RECFM=V the usable line length is LRECL-4: the record descriptor word is
  not content. A longer line used to be split into a second record without
  notice, and is now truncated like any other.
- A blank line is written as a record of blanks — it used to disappear (#233).
- A body whose last line carries no terminator still produces that record, and
  a body ending in a newline does not gain a trailing blank one.
- With `Transfer-Encoding: chunked` a line split across two chunks stays one
  record; a chunk boundary is a transport boundary, not a record boundary.

## Limitations
- Binary mode: the final incomplete record is padded with binary zeros to LRECL
- A request that produces **no record at all** leaves the member exactly as it
  was — a dropped connection, a body that never arrives. The member is not
  opened for output until there is a record to put in it, and it is CLOSE that
  stows the new directory entry over the old one, so an unopened member is an
  untouched member (issue #246). An over-long first line is no longer such a
  case: it is truncated to LRECL and written like any other record.
- **A failed write does not roll back, and real z/OSMF does not roll back
  either.** Measured on version 29 (#243): a body whose second of three lines is
  200 characters lands in an FB/80 member as three records of 5, 80 and 6, the
  previous content replaced, and answers 500. A rejected PUT to a member that
  did not exist yet also leaves the member behind, on both. mvsMF matches that.
  Staging under a temporary name would spend a directory entry per write and
  would not buy conformance, because there is nothing to conform to.
- An empty body is a truncate, not a no-op: `Content-Length: 0` empties the
  member.

There is no fixed upper bound on the record size: the write buffer is sized
from the dataset's own DCB (LRECL, or BLKSIZE for RECFM=U). Records above
1024 bytes used to overrun a fixed stack buffer and abend the handler
(issue #198) — the binary path was affected as well as text.

## Authorization

Requires **UPDATE** on the library in class `DATASET` (issue #228). The check runs
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
  --data-binary @myjob.jcl \
  http://mvs:1080/zosmf/restfiles/ds/MIKE.TEST.JCL\(MYJOB\)

# Binary mode
curl -X PUT \
  -H "X-IBM-Data-Type: binary" \
  --data-binary @mypgm.bin \
  http://mvs:1080/zosmf/restfiles/ds/MIKE.LOAD.LIB\(MYPGM\)

# Conditional write: read, edit, save only if nobody else did
ETAG=$(curl -sD - -o myjob.jcl -H "X-IBM-Return-Etag: true" \
  http://mvs:1080/zosmf/restfiles/ds/MIKE.TEST.JCL\(MYJOB\) \
  | grep -i '^ETag:' | tr -d '\r' | sed 's/^[^ ]* //')

curl -X PUT \
  -H "If-Match: ${ETAG}" \
  -H "X-IBM-Return-Etag: true" \
  --data-binary @myjob.jcl \
  http://mvs:1080/zosmf/restfiles/ds/MIKE.TEST.JCL\(MYJOB\)
# -> 204 and a new ETag, or 412 if the member changed in the meantime
```

### Using Zowe CLI
```bash
zowe files upload ftds myjob.jcl "MIKE.TEST.JCL(MYJOB)"
```
