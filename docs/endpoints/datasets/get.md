# Read Dataset

Retrieves the content of a sequential dataset.

## HTTP Method
GET

## URL Path
`/zosmf/restfiles/ds/{dataset-name}`

> **There is no `-({volume-serial})` form.** That route was withdrawn in #336:
> it accepted the volume operand and discarded it, so a request naming the
> wrong volume was answered as if it had named the right one. Such a URL is
> answered 404. Restoring it needs a volume-addressed SCRATCH/RENAME in
> libc370 (mvslovers/libc370#143) for the delete and rename paths.

## Path Parameters
- `dataset-name`: Name of the dataset to read

## Request Headers
- `X-IBM-Data-Type` (optional): Data transfer mode
    - `text` (default): EBCDIC-to-ASCII conversion, Content-Type: `text/plain`
    - `binary`: Raw bytes without conversion, Content-Type: `application/octet-stream`
    - `record`: Like binary, but each record prefixed with 4-byte big-endian length, Content-Type: `application/octet-stream`
- `X-IBM-Return-Etag` (optional): `true` returns an `ETag` for the dataset, for
  use as `If-Match` on a later write. Identical in behaviour to the member
  endpoint — see [members-get.md](members-get.md#etag).
- `If-None-Match` (optional): makes the read conditional — a dataset that still
  holds the stamped state is answered 304 (Not Modified) with the `ETag` and no
  body. Same header forms and same wildcard rule as the member endpoint, see
  [Conditional reads](members-get.md#conditional-reads-if-none-match).

## Response
On successful completion, this request returns HTTP status code 200 (OK) with the dataset content, or 304 (Not Modified) when `If-None-Match` still holds.

- **Text mode**: Each record is sent after EBCDIC-to-ASCII conversion. For F/FB datasets, trailing space padding (added by MVS to fill each record to LRECL) is stripped so the output matches VB-style line endings.
- **Binary mode**: Raw record data without conversion. For FB datasets, the exact record count is calculated from VTOC (DSCB1/DSCB4) to avoid reading past logical end-of-data.
- **Record mode**: Each record is preceded by a 4-byte big-endian length prefix

## Error Responses
- HTTP 400 (Bad Request)
    - Dataset is a PDS (use the member endpoint instead)
- HTTP 404 (Not Found)
    - Dataset not cataloged (`reason` 4)
- HTTP 500 (Internal Server Error)
    - The dataset exists but cannot be opened (I/O error)
    - Memory allocation failed

## Limitations
- Only sequential (PS) datasets are supported; PDS datasets return HTTP 400
- Binary/record mode for FB datasets uses DSCB-based record count calculation to determine exact end-of-data
- Binary/record mode for PDS members reads until fread returns 0 (no DSCB-based limit)

## Authorization

Requires **READ** on the data set in class `DATASET` (issue #228). The check runs
before any catalog, VTOC or data set access, so a refusal is indistinguishable
from "does not exist".

A refusal answers **HTTP 500** with `category 4`, `rc 8`, `reason 0` and the
explanation in `details[]` — the shape a real z/OSMF sends; 403 is not a z/OSMF
status. See [authorization.md](authorization.md).

## Examples

### Using curl
```bash
# Text mode (default)
curl http://mvs:1080/zosmf/restfiles/ds/MIKE.TEST.DATA

# Binary mode
curl -H "X-IBM-Data-Type: binary" \
  http://mvs:1080/zosmf/restfiles/ds/MIKE.LOAD.XMI \
  -o download.xmi
```

### Using Zowe CLI
```bash
zowe files download ds "MIKE.TEST.DATA"
zowe files download ds "MIKE.LOAD.XMI" -b -f download.xmi
```
