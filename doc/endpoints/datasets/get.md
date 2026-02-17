# Read Dataset

Retrieves the content of a sequential dataset.

## HTTP Method
GET

## URL Path
`/zosmf/restfiles/ds/{dataset-name}`

or with explicit volume:

`/zosmf/restfiles/ds/-({volume-serial})/{dataset-name}`

## Path Parameters
- `dataset-name`: Name of the dataset to read
- `volume-serial` (optional): Volume serial number

## Request Headers
- `X-IBM-Data-Type` (optional): Data transfer mode
    - `text` (default): EBCDIC-to-ASCII conversion, Content-Type: `text/plain`
    - `binary`: Raw bytes without conversion, Content-Type: `application/octet-stream`
    - `record`: Like binary, but each record prefixed with 4-byte big-endian length, Content-Type: `application/octet-stream`

## Response
On successful completion, this request returns HTTP status code 200 (OK) with the dataset content.

- **Text mode**: Each record is sent as-is after EBCDIC-to-ASCII conversion
- **Binary mode**: Raw record data without conversion. For FB datasets, the exact record count is calculated from VTOC (DSCB1/DSCB4) to avoid reading past logical end-of-data.
- **Record mode**: Each record is preceded by a 4-byte big-endian length prefix

## Error Responses
- HTTP 400 (Bad Request)
    - Dataset is a PDS (use the member endpoint instead)
- HTTP 500 (Internal Server Error)
    - Dataset not found or cannot be opened
    - Memory allocation failed

## Limitations
- Only sequential (PS) datasets are supported; PDS datasets return HTTP 400
- Binary/record mode for FB datasets uses DSCB-based record count calculation to determine exact end-of-data
- Binary/record mode for PDS members reads until fread returns 0 (no DSCB-based limit)

## Examples

### Using curl
```bash
# Text mode (default)
curl http://mvs:1080/zosmf/restfiles/ds/MIKE.TEST.DATA

# Binary mode
curl -H "X-IBM-Data-Type: binary" \
  http://mvs:1080/zosmf/restfiles/ds/MIKE.LOAD.XMI \
  -o download.xmi

# With explicit volume
curl http://mvs:1080/zosmf/restfiles/ds/-(PUB001)/MIKE.TEST.DATA
```

### Using Zowe CLI
```bash
zowe files download ds "MIKE.TEST.DATA"
zowe files download ds "MIKE.LOAD.XMI" -b -f download.xmi
```
