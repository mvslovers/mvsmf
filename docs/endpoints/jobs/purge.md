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

`owner` therefore comes back empty for a job purged in the seconds before JES2
writes `JCTUSEID` — the same window the submit response used to expose (#210).
Submit closes it by answering from the userid whose `USER=` it put on the job
card; **this endpoint deliberately does not**: the caller may purge a job of
another owner, and filling the field from the caller's identity would report a
userid that never submitted the job. An empty owner is the honest answer here.

## Authorization

A job of the caller's own userid is always purgeable. A job of another owner
needs UPDATE on the RACF class JESSPOOL, resource `<owner>.<jobname>.<jobid>`:

| Access of the caller | Answer |
|----------------------|--------|
| no profile, `NONE` | HTTP 404, identical to a job that does not exist |
| `READ` | HTTP 500, category 4, "Authorization failed - You may not purge this job." |
| `UPDATE` or better | the job is purged |

The job that is purged is the one that was looked up and checked, not the
strings of the request. The job id is compared whole; no wildcard matches. See
[Job spool authorization](../../jesspool.md).

## Error Responses
- HTTP 400 (Bad Request)
    - Missing required parameters (jobname/jobid)
    - Refusing to purge a started task, `reason` `REASON_STC_PURGE` — e.g. an
      attempt to delete HTTPD itself. This answered 403 until #250; 403 is not
      a z/OSMF status, and the refusal is about what was asked for rather than
      about who asked.
- HTTP 404 (Not Found)
    - Job not found, or a foreign job the caller may not see (no profile or
      `NONE`): the two answers are identical. This also covers a jobid JES2
      rejects as malformed — on 3.8j anything outside `JOB00001`–`JOB09999`, e.g. `JOB99999`, or a
      non-conforming string. `jescanj()` reports those as `CANJ_SYNTX`, which
      used to surface as 500 (issue #190).
- HTTP 500 (Internal Server Error)
    - A foreign job the caller may read but not purge (READ without UPDATE),
      category 4, the shape of the data set authorization denial.
    - JES2 system error
    - VSAM error

## Limitations
- Cannot purge the currently running HTTPD server
- Cannot purge active STCs (Started Tasks)
- Cannot purge active TSO users
- Job must exist and be purgeable by the caller (own job, or UPDATE on its JESSPOOL profile)
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