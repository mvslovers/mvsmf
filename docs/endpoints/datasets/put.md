# Write Dataset

Writes content to a sequential dataset. Supports text, binary, and record modes. Handles both chunked transfer encoding and Content-Length based transfers.

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
    - `record`: Each record preceded by 4-byte big-endian length prefix

## Response
On successful completion, this request returns HTTP status code 204 (No Content).

## Error Responses
- HTTP 400 (Bad Request)
    - Dataset is a PDS (use the member endpoint instead)
    - Missing Content-Length or Transfer-Encoding header
- HTTP 500 (Internal Server Error)
    - Dataset not found or cannot be opened for writing
    - I/O error during write

## Text mode framing
- A record ends at LF, CR or CRLF. The terminator is not part of the record.
- A line of exactly LRECL characters is accepted. Only a longer line is
  rejected, with "Record too long"; it is never silently split across two
  records. Until issue #233 the usable length was LRECL-2, so 80-column source
  could not be uploaded into an FB80 dataset at all.
- For RECFM=V the usable line length is LRECL-4: the record descriptor word is
  not content. A longer line used to be split into a second record without
  notice and is now rejected.
- A blank line is written as a record of blanks — it used to disappear (#233).
- A body whose last line carries no terminator still produces that record, and
  a body ending in a newline does not gain a trailing blank one.
- With `Transfer-Encoding: chunked` a line split across two chunks stays one
  record; a chunk boundary is a transport boundary, not a record boundary.

## Limitations
- Only sequential (PS) datasets are supported; PDS datasets return HTTP 400
- Binary mode: the final incomplete record is padded with binary zeros to LRECL
- A rejected upload does not leave the previous content in place. The dataset
  is opened for output before the body is read, so on "Record too long" the
  records written up to that line are already in the dataset and everything
  that was there before is gone.

There is no fixed upper bound on the record size: the write buffer is sized
from the dataset's own DCB (LRECL, or BLKSIZE for RECFM=U). Records above
1024 bytes used to overrun a fixed conversion buffer and abend the handler
(issue #198).

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
