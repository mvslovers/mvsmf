# Delete PDS Member

Deletes a member from a partitioned dataset (PDS).

## HTTP Method
DELETE

## URL Path
`/zosmf/restfiles/ds/{dataset-name}({member-name})`

> **There is no `-({volume-serial})` form.** That route was withdrawn in #336:
> it accepted the volume operand and discarded it, so a request naming the
> wrong volume was answered as if it had named the right one. Such a URL is
> answered 404. Restoring it needs a volume-addressed SCRATCH/RENAME in
> libc370 (mvslovers/libc370#143) for the delete and rename paths.

## Path Parameters
- `dataset-name`: Name of the partitioned dataset
- `member-name`: Name of the member to delete

## Response
On successful completion, this request returns HTTP status code 204 (No Content).

## Error Responses
- HTTP 400 (Bad Request)
    - Missing dataset or member name
    - Dataset or member name too long
- HTTP 404 (Not Found)
    - Member not found
- HTTP 500 (Internal Server Error)
    - `{"rc":8,"category":6,"reason":11,"message":"Dataset delete failed"}` —
      the STOW delete failed after the member was found. The caller was authorized and the target existed, so what is left
      is an enqueue held elsewhere or an I/O error; `MVSMF103E` carries the
      detail to the operator. (Reason 11 since #319; it reported the allocation
      failure's reason 2 before, which was never right for a delete.)

## Authorization

Requires **UPDATE** on the library in class `DATASET` (issue #228). The check runs
before any catalog, VTOC or data set access, so a refusal is indistinguishable
from "does not exist".

A refusal answers **HTTP 500** with `category 4`, `rc 8`, `reason 0` and the
explanation in `details[]` — the shape a real z/OSMF sends; 403 is not a z/OSMF
status. See [authorization.md](authorization.md).

## Examples

### Using curl
```bash
# Delete a PDS member
curl -X DELETE \
  http://mvs:1080/zosmf/restfiles/ds/MIKE.TEST.JCL\(MYJOB\)
```

### Using Zowe CLI
```bash
zowe files delete ds "MIKE.TEST.JCL(MYJOB)" -f
```
