# Purge Job

Purges a job from the JES2 system.

## HTTP Method
DELETE

## URL Path
`/zosmf/restjobs/jobs/{job-name}/{jobid}`

## Path Parameters
- `job-name`: Name of the job to be deleted
- `jobid`: ID of the job to be deleted (e.g. JOB00123)

## Response
On successful completion, this request returns HTTP status code 200 (OK) and a JSON object with the following properties:

```json
{
    "owner": "string",           // Owner of the job
    "jobid": "string",           // Job ID
    "original-jobid": "string",  // Same as jobid
    "message": "string",         // Success message
    "jobname": "string",         // Name of the job
    "status": 0                  // Status of the delete operation
}
```

`job-correlator` is not emitted — MVS 3.8j has no job correlators.

The job is looked up before it is purged. That lookup is what supplies `owner`
(it cannot be read afterwards, the job is gone) and what makes an unknown job
answer 404 the same way `GET /jobs/{name}/{id}` does.

## Error Responses
- HTTP 400 (Bad Request)
    - Missing required parameters (jobname/jobid)
- HTTP 403 (Forbidden)
    - No permission (e.g. attempt to delete HTTPD itself)
- HTTP 404 (Not Found)
    - Job not found. This also covers a jobid JES2 rejects as malformed —
      on 3.8j anything outside `JOB00001`–`JOB09999`, e.g. `JOB99999`, or a
      non-conforming string. `jescanj()` reports those as `CANJ_SYNTX`, which
      used to surface as 500 (issue #190).
- HTTP 500 (Internal Server Error)
    - JES2 system error
    - VSAM error

## Limitations
- Cannot purge the currently running HTTPD server
- Cannot purge active STCs (Started Tasks)
- Cannot purge active TSO users
- Job must exist and be accessible
- No support for job correlator IDs

## Examples

### Using curl
```bash
curl -X DELETE http://mvs:1080/zosmf/restjobs/jobs/TESTJOB/JOB00123
```

### Using mmf client
```bash
mmf job purge TESTJOB JOB00123
```

### Success Response
```json
{
    "owner": "MIKE",
    "jobid": "JOB00123",
    "job-correlator": "",
    "message": "Request was successful.",
    "jobname": "TESTJOB",
    "status": 0
}
``` 