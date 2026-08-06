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

Only a missing *dataset* is an error here. A member that does not exist yet is
what a create looks like, and it is written normally.

## Limitations
- Text mode: a line longer than the dataset's LRECL is rejected with an error
  ("Record too long"); it is not silently split across two records
- Binary mode: the final incomplete record is padded with binary zeros to LRECL

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
