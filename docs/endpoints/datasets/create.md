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

Required **unless `like` is given** — with a model, every one of them becomes an
optional override:

- `dsorg`: Dataset organization (`PS` for sequential, `PO` for partitioned)
- `recfm`: Record format (e.g. `FB`, `VB`, `U`)
- `lrecl`: Logical record length
- `blksize`: Block size
- `primary`: Primary space allocation

### Optional Fields
- `like`: Model the new data set on an existing one (see below)
- `secondary`: Secondary space allocation (default: 0)
- `dirblk`: Directory blocks for PDS (default: 0)
- `alcunit`: Allocation unit — `TRK`, `CYL`, or `BLK` (default: `TRK`)

## `like` — model on an existing data set

```json
{"like": "MY.MODEL.PDS"}
{"like": "MY.MODEL.PDS", "blksize": 800}
```

This is what `zowe files cp ds` sends when it creates the copy target.

**DSORG, RECFM, LRECL and BLKSIZE come from the model**, read off its DSCB by
MVS itself through the SVC 99 `DALDCBDS` text unit — the same mechanism as JCL
`DCB=(dsname)`. Any of those fields present in the body overrides the model.

**Space does not come from the model in the same way.** `DCB=` never copied
`SPACE`; the thing that does is DFSMS `LIKE=`, which MVS 3.8j has no equivalent
for. mvsMF derives it instead:

| | with `like`, field absent |
|---|---|
| `primary` | the model's total allocated tracks, in `TRK` |
| `secondary` | the model's secondary quantity, converted to tracks |
| `alcunit` | forced to `TRK`, because the two above are track counts |
| `dirblk` | `20` when the model is partitioned — see below |

Supplying `primary` yourself leaves your `alcunit` alone.

`dirblk` is the one value with no source at all: a DSCB records no directory
quantity, so there is nothing to model. 20 blocks is roughly 100 members once
ISPF statistics are present, which covers the copy case and costs about 5 KB.
Send `dirblk` explicitly when you know better.

A `like` naming a data set that is not cataloged answers **404**, not the
generic allocation 500 — otherwise nothing would say it was the *model* that
was missing.

## Response
On successful completion, this request returns HTTP status code 201 (Created).

## Error Responses
- HTTP 400 (Bad Request)
    - Missing or invalid allocation parameters, or a `like` name longer than 44
      characters
- HTTP 404 (Not Found)
    - The data set named by `like` is not cataloged
- HTTP 500 (Internal Server Error)
    - `{"category":8,"rc":900,"reason":7,"message":"Dynamic allocation Error"}`
      — every allocation failure, whatever the cause: the name already exists,
      no space, parameters that do not fit, or no authority for the name. The
      reference answers all of them identically; see the *Authorization* section.

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
