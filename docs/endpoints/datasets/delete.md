# Delete Dataset

Deletes a sequential or partitioned dataset. The dataset is uncataloged and scratched.

## HTTP Method
DELETE

## URL Path
`/zosmf/restfiles/ds/{dataset-name}`

or with explicit volume:

`/zosmf/restfiles/ds/-({volume-serial})/{dataset-name}`

## Path Parameters
- `dataset-name`: Name of the dataset to delete
- `volume-serial` (optional): Volume serial number

## Response
On successful completion, this request returns HTTP status code 204 (No Content).

## Error Responses
- HTTP 400 (Bad Request)
    - Missing dataset name
- HTTP 404 (Not Found)
    - Dataset not found in catalog
- HTTP 500 (Internal Server Error)
    - Delete operation failed

## Examples

### Using curl
```bash
# Delete a dataset
curl -X DELETE \
  http://mvs:1080/zosmf/restfiles/ds/MIKE.DUMMY.DATA

# Delete with explicit volume
curl -X DELETE \
  http://mvs:1080/zosmf/restfiles/ds/-(PUB001)/MIKE.DUMMY.DATA
```

### Using Zowe CLI
```bash
zowe files delete ds "MIKE.DUMMY.DATA" -f
```
