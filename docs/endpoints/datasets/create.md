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

A refusal and a request for more space than the volume has answer **byte for
byte the same**, and that is correct: measured, a real z/OSMF answers both with

```
500 {"category":8,"rc":900,"reason":7,"message":"Dynamic allocation Error"}
```

mvsMF sends exactly that since #317. It *can* tell the two apart — `__dsalcf()`
returns different codes — and deliberately does not, because the reference does
not. Do not "improve" this into a distinct authorization error; the suite asserts
the sameness.

Nothing is written to the console for either case (#317 retired `MVSMF102E`).
A denial still shows up as RAKF's own `RAKF0005`/`RAKF000A`.

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
