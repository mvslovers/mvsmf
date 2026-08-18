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

`exec-data=Y` is honoured here too, since the response is built by the same code, but it is of little use: a job that has just been submitted has usually not started yet, so `exec-started` and `exec-ended` are typically `null`. A very short job can already have run by the time the response is built, in which case they carry real instants — do not rely on either outcome.

## Error Responses
- HTTP 400 (Bad Request)
    - Invalid internal reader parameters
    - Unsupported `Content-Type` (anything other than `application/json` or `text/plain`)
    - Missing `file` field in JSON body
    - Failed to read request content
    - JCL memory allocation failure
- HTTP 500 (Internal Server Error)
    - Failed to open internal reader
    - Failed to process job card

## Limitations
- USER and PASSWORD are automatically injected into the job card from the authenticated user's credentials
- The `NOTIFY` parameter in the job card is updated with the authenticated user's ID if `&SYSUID` is present. `&SYSUID` may appear in any position on the job card (e.g. `NOTIFY=&SYSUID,REGION=0K`); parameters following it are preserved. Trailing blanks from fixed 80-column records are ignored during this rewrite.
- **`NOTIFY` is not added when the card has none, and the submitted job then never reports a `retcode`.** MVS records a job's completion code only for jobs that requested a notify, so a card without one yields `"retcode": null` for the whole life of the job — however it ends. Clients that poll for a completion code, such as `zowe jobs submit --wait-for-output`, wait forever. Add `NOTIFY=&SYSUID` to the card to avoid it; the mechanism, and whether mvsMF should inject one, are covered in [Job Status → Limitations](status.md#retcode-is-null-for-jobs-submitted-without-notify).
- The whole feature needs JES2 usermod **`SYZJ201`** to be installed; see [Prerequisites](../../../README.md#the-syzj201-usermod).

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
