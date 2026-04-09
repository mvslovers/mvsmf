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
- HTTP 500 (Internal Server Error)
    - Dataset not found or not a PDS

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
