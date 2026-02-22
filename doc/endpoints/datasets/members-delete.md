# Delete PDS Member

Deletes a member from a partitioned dataset (PDS).

## HTTP Method
DELETE

## URL Path
`/zosmf/restfiles/ds/{dataset-name}({member-name})`

or with explicit volume:

`/zosmf/restfiles/ds/-({volume-serial})/{dataset-name}({member-name})`

## Path Parameters
- `dataset-name`: Name of the partitioned dataset
- `member-name`: Name of the member to delete
- `volume-serial` (optional): Volume serial number

## Response
On successful completion, this request returns HTTP status code 204 (No Content).

## Error Responses
- HTTP 400 (Bad Request)
    - Missing dataset or member name
    - Dataset or member name too long
- HTTP 404 (Not Found)
    - Member not found
- HTTP 500 (Internal Server Error)
    - Delete operation failed

## Examples

### Using curl
```bash
# Delete a PDS member
curl -X DELETE \
  http://mvs:1080/zosmf/restfiles/ds/MIKE.TEST.JCL\(MYJOB\)

# Delete with explicit volume
curl -X DELETE \
  http://mvs:1080/zosmf/restfiles/ds/-(PUB001)/MIKE.TEST.JCL\(MYJOB\)
```

### Using Zowe CLI
```bash
zowe files delete ds "MIKE.TEST.JCL(MYJOB)" -f
```
