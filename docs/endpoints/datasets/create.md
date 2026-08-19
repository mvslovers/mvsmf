# Create Dataset

Creates a new sequential or partitioned dataset with the specified allocation parameters.

## HTTP Method
POST

## URL Path
`/zosmf/restfiles/ds/{dataset-name}`

## Path Parameters
- `dataset-name`: Name of the dataset to create

## Request Headers
- `Content-Type: application/json` (optional)

## Request Body (JSON)

### Required Fields
- `dsorg`: Dataset organization (`PS` for sequential, `PO` for partitioned)
- `recfm`: Record format (e.g. `FB`, `VB`, `U`)
- `lrecl`: Logical record length
- `blksize`: Block size
- `primary`: Primary space allocation

### Optional Fields
- `secondary`: Secondary space allocation (default: 0)
- `dirblk`: Directory blocks for PDS (default: 0)
- `alcunit`: Allocation unit — `TRK`, `CYL`, or `BLK` (default: `TRK`)

## Response
On successful completion, this request returns HTTP status code 201 (Created).

## Error Responses
- HTTP 400 (Bad Request)
    - Missing or invalid allocation parameters
- HTTP 500 (Internal Server Error)
    - Dataset allocation failed (e.g. dataset already exists, no space)

## Authorization

**No check of its own — but not unprotected.** Allocation goes through
`__dsalcf()` (SVC 99) rather than an open, so it was not part of the pre-check
work in #228. RAKF gates DADSM regardless: measured, an ordinary userid
allocating under a foreign qualifier is refused, nothing is created, and
`RAKF0005` is logged.

What is wrong is the report. A refusal and a request for more space than the
volume has answer **byte for byte the same** —
`500 {"rc":8,"category":6,"reason":2,"message":"Dataset allocation failed"}` — so
a client cannot tell "you may not create here" from "there is no room", and both
also write `MVSMF102E` to the console. Tracked as #317.

## Examples

### Using curl
```bash
# Create a sequential dataset
curl -X POST \
  -H "Content-Type: application/json" \
  -d '{"dsorg":"PS","recfm":"FB","lrecl":80,"blksize":3120,"alcunit":"TRK","primary":1,"secondary":1}' \
  http://mvs:1080/zosmf/restfiles/ds/MIKE.TEST.SEQ

# Create a PDS
curl -X POST \
  -H "Content-Type: application/json" \
  -d '{"dsorg":"PO","recfm":"FB","lrecl":80,"blksize":3120,"alcunit":"TRK","primary":1,"secondary":1,"dirblk":5}' \
  http://mvs:1080/zosmf/restfiles/ds/MIKE.TEST.PDS
```

### Using Zowe CLI
```bash
# Create a sequential dataset
zowe files create ps "MIKE.TEST.SEQ" --recfm FB --lrecl 80 --blksize 3120 --size 1TRK

# Create a PDS
zowe files create pds "MIKE.TEST.PDS" --recfm FB --lrecl 80 --blksize 3120 --size 1TRK --dirblk 5
```
