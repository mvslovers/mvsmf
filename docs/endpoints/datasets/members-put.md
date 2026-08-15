# Write PDS Member

Writes content to a member in a partitioned dataset (PDS). Supports text, binary, and record modes. Handles both chunked transfer encoding and Content-Length based transfers.

## HTTP Method
PUT

## URL Path
`/zosmf/restfiles/ds/{dataset-name}({member-name})`

or with explicit volume:

`/zosmf/restfiles/ds/-({volume-serial})/{dataset-name}({member-name})`

## Path Parameters
- `dataset-name`: Name of the partitioned dataset
- `member-name`: Name of the member to write
- `volume-serial` (optional): Volume serial number

## Request Headers
- `Content-Length` or `Transfer-Encoding: chunked`: One of these is required
- `X-IBM-Data-Type` (optional): Data transfer mode
    - `text` (default): ASCII-to-EBCDIC conversion, records split at newlines
    - `binary`: Raw bytes written without conversion, split at LRECL boundaries
    - `record`: Each record preceded by 4-byte big-endian length prefix

## Response
On successful completion, this request returns HTTP status code 204 (No Content).

## Error Responses
- HTTP 400 (Bad Request)
    - Missing Content-Length or Transfer-Encoding header
- HTTP 404 (Not Found)
    - Dataset not cataloged (`reason` 4)
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

## Text mode framing
- A record ends at LF, CR or CRLF. The terminator is not part of the record.
- A line of exactly LRECL characters is accepted. Only a longer line is
  rejected, with "Record too long"; it is never silently split across two
  records. Until issue #233 the usable length was LRECL-2, so 80-column source
  could not be uploaded into an FB80 library at all.
- For RECFM=V the usable line length is LRECL-4: the record descriptor word is
  not content. A longer line used to be split into a second record without
  notice and is now rejected.
- A blank line is written as a record of blanks — it used to disappear (#233).
- A body whose last line carries no terminator still produces that record, and
  a body ending in a newline does not gain a trailing blank one.
- With `Transfer-Encoding: chunked` a line split across two chunks stays one
  record; a chunk boundary is a transport boundary, not a record boundary.

## Limitations
- Binary mode: the final incomplete record is padded with binary zeros to LRECL
- A rejected upload does not leave the previous member content in place. The
  member is opened for output before the body is read, so on "Record too long"
  the records written up to that line are already stored and the previous
  content is gone.

There is no fixed upper bound on the record size: the write buffer is sized
from the dataset's own DCB (LRECL, or BLKSIZE for RECFM=U). Records above
1024 bytes used to overrun a fixed stack buffer and abend the handler
(issue #198) — the binary path was affected as well as text.

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
```

### Using Zowe CLI
```bash
zowe files upload ftds myjob.jcl "MIKE.TEST.JCL(MYJOB)"
```
