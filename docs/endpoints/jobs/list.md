# List Jobs

Returns a list of jobs matching the specified filters.

## HTTP Method
GET

## URL Path
`/zosmf/restjobs/jobs`

## Query Parameters
- `owner` (optional): Filter by job owner. Use `*` for all owners. Default: current authenticated user.
- `prefix` (optional): Filter by job name prefix. Use `*` for all jobs.
- `jobid` (optional): Filter by specific job ID.
- `status` (optional): Filter by job status (`INPUT`, `ACTIVE`, `OUTPUT`). Use `*` for all.
- `max-jobs` (optional): Maximum number of jobs to return (1-1000). Default: 1000.

## Response
On successful completion, this request returns HTTP status code 200 (OK) and a JSON array of job objects:

```json
[
    {
        "subsystem": "JES2",
        "jobname": "string",
        "jobid": "string",
        "owner": "string",
        "type": "JOB|STC|TSU",
        "class": "string",
        "url": "string",
        "files-url": "string",
        "status": "INPUT|ACTIVE|OUTPUT",
        "retcode": "CC nnnn|ABEND Sxxx|ABEND Unnnn|JCL ERROR|null"
    }
]
```

## Error Responses
- HTTP 500 (Internal Server Error)
    - JES2 system error

## Limitations
- Maximum 1000 jobs returned per request
- Owner filter defaults to current user if not specified
- See [status.md](status.md) for limitations on the `retcode` field

## Examples

### Using curl
```bash
# List own jobs
curl http://mvs:1080/zosmf/restjobs/jobs

# List all jobs
curl "http://mvs:1080/zosmf/restjobs/jobs?owner=*"

# List jobs with prefix filter
curl "http://mvs:1080/zosmf/restjobs/jobs?prefix=TEST*"

# List jobs by job ID
curl "http://mvs:1080/zosmf/restjobs/jobs?jobid=JOB00123"
```

### Using Zowe CLI
```bash
zowe jobs list jobs
zowe jobs list jobs --owner "*" --prefix "TEST*"
```

### Success Response
```json
[
    {
        "subsystem": "JES2",
        "jobname": "TESTJOB",
        "jobid": "JOB00123",
        "owner": "MIKE",
        "type": "JOB",
        "class": "A",
        "url": "/zosmf/restjobs/jobs/TESTJOB/JOB00123",
        "files-url": "/zosmf/restjobs/jobs/TESTJOB/JOB00123/files",
        "status": "OUTPUT",
        "retcode": "CC 0000"
    }
]
```
