# Job Status

Returns status and properties of a specific job.

## HTTP Method
GET

## URL Path
`/zosmf/restjobs/jobs/{job-name}/{jobid}`

## Path Parameters
- `job-name`: Name of the job
- `jobid`: ID of the job (e.g. JOB00123)

## Response
On successful completion, this request returns HTTP status code 200 (OK) and a JSON object with the following properties:

```json
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
```

## Error Responses
- HTTP 400 (Bad Request)
    - Missing required parameters (jobname/jobid)
- HTTP 404 (Not Found)
    - Job not found

## Limitations

### `retcode` may be null for completed jobs

The `retcode` field is derived from the `JCTCNVRC` field in the JES2 Job Control Table (JCT). After execution, the initiator writes back a completion code with high byte `0x77`, from which the condition code or ABEND code is decoded.

On MVS 3.8j, this write-back only occurs when a SYSMOD is installed that supports it **and** the job card includes the `NOTIFY` parameter. Without `NOTIFY`, the JCT completion field remains at 0 (converter OK) and `retcode` will be `null` even though the job completed normally.

**Workaround:** Add `NOTIFY=&SYSUID` (or a specific userid) to the job card:

```jcl
//MYJOB  JOB (ACCT),'DESC',CLASS=A,MSGCLASS=A,NOTIFY=&SYSUID
```

This affects clients like Zowe CLI that use `--wait-for-output`, which polls job status until `retcode` is non-null.

## Examples

### Using curl
```bash
curl http://mvs:1080/zosmf/restjobs/jobs/TESTJOB/JOB00123
```

### Using mmf client
```bash
mmf job status TESTJOB JOB00123
```

### Success Response
```json
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
```
