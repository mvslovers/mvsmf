# Job Spool Files

Returns a list of spool (DD) files for a specific job.

## HTTP Method
GET

## URL Path
`/zosmf/restjobs/jobs/{job-name}/{jobid}/files`

## Path Parameters
- `job-name`: Name of the job
- `jobid`: ID of the job (e.g. JOB00123)

## Response
On successful completion, this request returns HTTP status code 200 (OK) and a JSON array of spool file objects:

```json
[
    {
        "jobname": "string",
        "recfm": "string",
        "lrecl": 0,
        "byte-count": 0,
        "record-count": 0,
        "jobid": "string",
        "ddname": "string",
        "id": 0,
        "stepname": "string",
        "procstep": "string",
        "class": "string",
        "records-url": "string"
    }
]
```

## Error Responses
- HTTP 404 (Not Found)
    - Job not found
- HTTP 500 (Internal Server Error)
    - JES2 system error

## Examples

### Using curl
```bash
curl http://mvs:1080/zosmf/restjobs/jobs/TESTJOB/JOB00123/files
```

### Using Zowe CLI
```bash
zowe jobs list spool-files-by-jobid JOB00123
```

### Success Response
```json
[
    {
        "jobname": "TESTJOB",
        "recfm": "UA",
        "lrecl": 133,
        "byte-count": 1024,
        "record-count": 10,
        "jobid": "JOB00123",
        "ddname": "JESMSGLG",
        "id": 2,
        "stepname": "JES2",
        "procstep": "",
        "class": "H",
        "records-url": "/zosmf/restjobs/jobs/TESTJOB/JOB00123/files/2/records"
    },
    {
        "jobname": "TESTJOB",
        "recfm": "V",
        "lrecl": 136,
        "byte-count": 2048,
        "record-count": 20,
        "jobid": "JOB00123",
        "ddname": "JESJCL",
        "id": 3,
        "stepname": "JES2",
        "procstep": "",
        "class": "H",
        "records-url": "/zosmf/restjobs/jobs/TESTJOB/JOB00123/files/3/records"
    }
]
```
