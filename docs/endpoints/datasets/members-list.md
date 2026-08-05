# List PDS Members

Returns a list of members in a partitioned dataset (PDS).

## HTTP Method
GET

## URL Path
`/zosmf/restfiles/ds/{dataset-name}/member`

or with explicit volume:

`/zosmf/restfiles/ds/-({volume-serial})/{dataset-name}/member`

## Path Parameters
- `dataset-name`: Name of the partitioned dataset
- `volume-serial` (optional): Volume serial number

## Query Parameters
- `start` (optional): Starting member name for pagination
- `pattern` (optional): Member name filter pattern

## Response
On successful completion, this request returns HTTP status code 200 (OK) and a JSON object:

```json
{
    "items": [
        {
            "member": "string"
        }
    ],
    "returnedRows": 0,
    "JSONversion": 1
}
```

## Error Responses
- HTTP 400 (Bad Request)
    - The dataset is not partitioned (use the dataset endpoint instead)
- HTTP 404 (Not Found)
    - Dataset not cataloged (`reason` 4)
- HTTP 500 (Internal Server Error)
    - I/O error while reading the directory

The target is checked against the catalog and the DSCB before the directory is
read. `__listpd()` reads it with BPAM, and against a data set that is not
partitioned that is an S001 abend rather than an error return — so the check
has to happen first (issue #193). A dataset that was not cataloged used to be
answered with an empty `items` list and 200, which reads as "this PDS has no
members".

## Limitations
- No member statistics (TTR, size, dates) are returned yet
- `start` and `pattern` query parameters are accepted but not yet implemented

## Examples

### Using curl
```bash
curl http://mvs:1080/zosmf/restfiles/ds/MIKE.TEST.JCL/member
```

### Using Zowe CLI
```bash
zowe files list all-members "MIKE.TEST.JCL"
```

### Success Response
```json
{
    "items": [
        { "member": "MYJOB" },
        { "member": "TESTPGM" },
        { "member": "LINKJOB" }
    ],
    "returnedRows": 3,
    "JSONversion": 1
}
```
