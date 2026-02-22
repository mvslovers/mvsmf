# Submit Job

Submits a job for execution. Supports two modes: inline JCL (text/plain) and dataset reference (application/json).

## HTTP Method
PUT

## URL Path
`/zosmf/restjobs/jobs`

## Request Headers
- `Content-Type`: Either `text/plain` (inline JCL) or `application/json` (dataset reference)
- `X-IBM-Intrdr-Mode` (optional): Validated if present, must be `TEXT`
- `X-IBM-Intrdr-Lrecl` (optional): Validated if present, must be `80`
- `X-IBM-Intrdr-Recfm` (optional): Validated if present, must be `F`

## Request Body

### Inline JCL (Content-Type: text/plain)
The request body contains the JCL directly as plain text.

```
//MYJOB  JOB (ACCT),'DESC',CLASS=A,MSGCLASS=H
//STEP1  EXEC PGM=IEFBR14
```

### Dataset Reference (Content-Type: application/json)
The request body is a JSON object referencing a dataset containing JCL:

```json
{
    "file": "'USER.JCL(MYJOB)'"
}
```

## Response
On successful completion, this request returns HTTP status code 200 (OK) and the job status as a JSON object (same format as the [status](status.md) endpoint).

## Error Responses
- HTTP 400 (Bad Request)
    - Invalid internal reader parameters
    - Missing `file` field in JSON body
    - Failed to read request content
    - JCL memory allocation failure
- HTTP 500 (Internal Server Error)
    - Failed to open internal reader
    - Failed to process job card

## Limitations
- USER and PASSWORD are automatically injected into the job card from the authenticated user's credentials
- The `NOTIFY` parameter in the job card is updated with the authenticated user's ID if `&SYSUID` is present

## Examples

### Using curl (inline JCL)
```bash
curl -X PUT \
  -H "Content-Type: text/plain" \
  --data-binary @myjob.jcl \
  http://mvs:1080/zosmf/restjobs/jobs
```

### Using curl (dataset reference)
```bash
curl -X PUT \
  -H "Content-Type: application/json" \
  -d '{"file":"'\''USER.JCL(MYJOB)'\''"}' \
  http://mvs:1080/zosmf/restjobs/jobs
```

### Using Zowe CLI
```bash
zowe jobs submit data-set "USER.JCL(MYJOB)"
zowe jobs submit local-file myjob.jcl
```

### Success Response
```json
{
    "subsystem": "JES2",
    "jobname": "MYJOB",
    "jobid": "JOB00456",
    "owner": "MIKE",
    "type": "JOB",
    "class": "A",
    "url": "/zosmf/restjobs/jobs/MYJOB/JOB00456",
    "files-url": "/zosmf/restjobs/jobs/MYJOB/JOB00456/files",
    "status": "INPUT",
    "retcode": null
}
```
