# Job Spool File Records

Retrieves the content (records) of a specific spool file for a job.

## HTTP Method
GET

## URL Path
`/zosmf/restjobs/jobs/{job-name}/{jobid}/files/{ddid}/records`

## Path Parameters
- `job-name`: Name of the job
- `jobid`: ID of the job (e.g. JOB00123)
- `ddid`: Spool file ID (from the `id` field in the files list)

## Response
On successful completion, this request returns HTTP status code 200 (OK) with Content-Type `text/plain`. The response body contains the spool file records as plain text. When more than one DD is emitted, the outputs are separated by a dashed line (never trailing).

For SYSIN datasets (e.g. `JESJCLIN`), the response contains exactly `record-count` records: JES2 pre-formats a "JOB DELETED BY JES2 OR CANCELLED BY OPERATOR BEFORE EXECUTION" line into the JCLIN spool chain behind the real records, and the handler caps the output at the PDDB record count so this line does not leak into every response. SYSOUT datasets are not capped, because their record counts may lag while a job is active.

## Error Responses
- HTTP 400 (Bad Request)
    - Invalid DDID parameter
- HTTP 404 (Not Found)
    - Job not found
- HTTP 500 (Internal Server Error)
    - JES2 system error

## Examples

### Using curl
```bash
curl http://mvs:1080/zosmf/restjobs/jobs/TESTJOB/JOB00123/files/2/records
```

### Using Zowe CLI
```bash
zowe jobs view spool-file-by-id JOB00123 2
```
