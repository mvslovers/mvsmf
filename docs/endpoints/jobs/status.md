# Job Status

Returns status and properties of a specific job.

## HTTP Method
GET

## URL Path
`/zosmf/restjobs/jobs/{job-name}/{jobid}`

## Path Parameters
- `job-name`: Name of the job
- `jobid`: ID of the job (e.g. JOB00123)

## Query Parameters
- `exec-data` (optional): `Y` adds `exec-started` and `exec-ended` to the job object, exactly as for [list](list.md#execution-timestamps). Any other value (or omitting the parameter) returns the object unchanged.

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

With `exec-data=Y`, two further fields follow `retcode`:

```json
    "exec-started": "2026-08-07T18:57:10.000Z",
    "exec-ended": "2026-08-07T18:57:10.000Z"
```

Format, `null` semantics and the missing `exec-submitted` are described under
[Execution timestamps](list.md#execution-timestamps).

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
    "url": "http://mvs:1080/zosmf/restjobs/jobs/TESTJOB/JOB00123",
    "files-url": "http://mvs:1080/zosmf/restjobs/jobs/TESTJOB/JOB00123/files",
    "status": "OUTPUT",
    "retcode": "CC 0000"
}
```

`url` and `files-url` are absolute. Their host comes from the request's `Host` header and
their scheme from `X-Forwarded-Proto` (`https` when a reverse proxy reports it, `http`
otherwise) — mvsMF itself only ever sees plain HTTP behind a TLS-terminating proxy.
