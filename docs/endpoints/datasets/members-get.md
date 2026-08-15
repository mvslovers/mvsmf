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
- `X-IBM-Return-Etag` (optional): `true` returns an `ETag` for the member. Any
  other value, or an absent header, returns none.

## Response
On successful completion, this request returns HTTP status code 200 (OK) with the member content. In text mode, trailing space padding on F/FB records is stripped so the output matches VB-style line endings.

## ETag

With `X-IBM-Return-Etag: true` the response carries an `ETag` header — a
16-hex-digit stamp of the member's current content. Passing it back on a
subsequent PUT as `If-Match` makes that write conditional: it succeeds only if
the member still holds the state that was read, and fails with 412 otherwise.
That is what keeps two editors from silently overwriting each other. See
[members-put.md](members-put.md) for the write side.

The value is opaque — clients must echo it, never parse it. Two properties are
guaranteed and are the only ones to rely on:

- Reading the same unchanged member twice yields the same stamp.
- The stamp does not depend on `X-IBM-Data-Type`: a text read and a binary read
  of the same member return the same value, because it is computed over the
  stored records rather than over the converted bytes that go on the wire.

It is opt-in because it costs a second read pass over the member. Requests
without the header are unaffected.

The header is emitted unquoted, the way z/OSMF emits it. `Access-Control-Expose-Headers: ETag`
accompanies it so a cross-origin client can read the value at all.

## Error Responses
- HTTP 404 (Not Found)
    - Dataset not cataloged (`reason` 4, `Dataset not found`)
    - Dataset exists but has no such member (`reason` 5, `PDS member not found`)
- HTTP 500 (Internal Server Error)
    - The member exists but cannot be opened (I/O error)
    - Memory allocation failed

A failed open used to be reported as 500 whatever the cause, so a member that
was simply not there looked like a broken server (issue #191). The two cases are
now told apart by a catalog lookup and a filtered directory read.

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
