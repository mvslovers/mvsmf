# Read PDS Member

Retrieves the content of a member in a partitioned dataset (PDS).

## HTTP Method
GET

## URL Path
`/zosmf/restfiles/ds/{dataset-name}({member-name})`

or with explicit volume:

`/zosmf/restfiles/ds/-({volume-serial})/{dataset-name}({member-name})`

## Path Parameters
- `dataset-name`: Name of the partitioned dataset
- `member-name`: Name of the member to read
- `volume-serial` (optional): Volume serial number

## Request Headers
- `X-IBM-Data-Type` (optional): Data transfer mode
    - `text` (default): EBCDIC-to-ASCII conversion, Content-Type: `text/plain`
    - `binary`: Raw bytes without conversion, Content-Type: `application/octet-stream`
    - `record`: Like binary, but each record prefixed with 4-byte big-endian length, Content-Type: `application/octet-stream`

## Response
On successful completion, this request returns HTTP status code 200 (OK) with the member content.

## Error Responses
- HTTP 500 (Internal Server Error)
    - Dataset or member not found
    - Memory allocation failed

## Limitations
- Binary/record mode: no DSCB-based record count limit (reads until fread returns 0). This works correctly for PDS members but may include padding for the last block.

## Examples

### Using curl
```bash
# Text mode (default)
curl http://mvs:1080/zosmf/restfiles/ds/MIKE.TEST.JCL\(MYJOB\)

# Binary mode
curl -H "X-IBM-Data-Type: binary" \
  http://mvs:1080/zosmf/restfiles/ds/MIKE.LOAD.LIB\(MYPGM\) \
  -o mypgm.bin
```

### Using Zowe CLI
```bash
zowe files download ds "MIKE.TEST.JCL(MYJOB)"
```
