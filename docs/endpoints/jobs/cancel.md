# Cancel Job

Cancels a job that has not finished. JES2 ends it the way the operator command
`$C` does, and the job's output **stays on the spool**: the job moves to the
output queue (`status` `OUTPUT`) and its spool files can still be read. Use
[Purge Job](purge.md) to remove the job and its output.

## HTTP Method
PUT

## URL Path
`/zosmf/restjobs/jobs/{job-name}/{jobid}`

## Path Parameters
- `job-name`: Name of the job to be cancelled
- `jobid`: ID of the job to be cancelled (e.g. JOB00123), in upper case: it is compared whole and case-sensitively

## Request Body
A JSON object whose `request` member names the operation:

```json
{ "request": "cancel", "version": "2.0" }
```

| Member | Meaning |
|--------|---------|
| `request` | `cancel`. Required. Compared exactly: `CANCEL` or `Cancel` is an unknown request. |
| `version` | Accepted and ignored. mvsMF always answers synchronously, for `"1.0"` and for `"2.0"` alike. |

The route is shared by every update of a job and told apart by `request`.
`hold` and `release` are known names but are **not implemented** yet (#424):
they answer HTTP 400, reason 15. Any other member of the body is ignored.

The body is a JSON object in CP037; only the top-level `request` member
counts. A `"request"` nested in another object, or inside a string, is not the
request. A body that is not exactly one complete JSON object (cut off, a comma
before the closing brace, anything but white space after it) carries no
request and answers 400, reason 4.

## Response
On successful completion, this request returns HTTP status code 200 (OK) and a
JSON object with the shape of the [purge](purge.md) response:

```json
{
    "owner": "string",           // Owner of the job
    "jobid": "string",           // Job ID
    "original-jobid": "string",  // Same as jobid
    "message": "string",         // Success message
    "jobname": "string",         // Name of the job
    "status": 0                  // Status of the cancel operation
}
```

`job-correlator` is not emitted — MVS 3.8j has no job correlators.

The job is looked up before it is cancelled, as for a purge; `owner` comes from
that lookup. The shape of this body has not been compared with a reference
z/OSMF: it follows the purge response.

## Authorization

A cancel is judged by the rule of the purge. A job of the caller's own userid
can always be cancelled. A job of another owner needs UPDATE on the RACF class
JESSPOOL, resource `<owner>.<jobname>.<jobid>`:

| Access of the caller | Answer |
|----------------------|--------|
| no profile, `NONE` | HTTP 404, identical to a job that does not exist |
| `READ` | HTTP 500, category 4, "Authorization failed - You may not cancel this job." |
| `UPDATE` or better | the job is cancelled |

The job that is cancelled is the one that was looked up and checked, not the
strings of the request. See [Job spool authorization](../../jesspool.md).

## Error Responses
- HTTP 400 (Bad Request)
    - The body is empty, is not a JSON object, or has no `request` member:
      reason 4 (`REASON_INVALID_REQUEST`), "Request does not contain a valid job
      update request".
    - `request` is anything but `cancel`, `hold` or `release`: reason 4,
      "Update request is not 'cancel', 'hold' or 'release'".
    - `request` is `hold` or `release`: reason 15, "Update request 'hold' is not
      implemented".
    - The job is a started task or a TSO user: reason 13 (`REASON_STC_CANCEL`),
      "Cannot cancel a started task or a TSO user". The refusal is JES2's.
    - The job has finished and is on the output queue: reason 14
      (`REASON_JOB_ON_OUTPUT_QUEUE`), "Job 'NAME(JOBID)' is on the output queue
      and is not running". Cancelling it a second time is this answer.
- HTTP 404 (Not Found)
    - Job not found, or a foreign job the caller may not see: the two answers
      are identical. This also covers a jobid JES2 rejects as malformed (on
      3.8j anything outside `JOB00001`–`JOB09999`).
- HTTP 413 (Request Entity Too Large)
    - The request body is too large.
- HTTP 500 (Internal Server Error)
    - A foreign job the caller may read but not cancel (READ without UPDATE),
      category 4.
    - JES2 system error. An unexpected return code of the cancel is also
      reported to the operator console (`MVSMF207E`, see [messages](../../messages.md)).

## Limitations
- A job that is waiting for an operator reply (for example an allocation
  message) stays cancel-pending until that reply is given: JES2 has accepted the
  cancel, but the job does not end by itself.
- Cannot cancel started tasks or TSO users.
- Hold and release are not implemented (#424).
- No support for job correlator IDs.

## Examples

### Using curl
```bash
curl -X PUT -H "Content-Type: application/json" \
     -H "X-CSRF-ZOSMF-HEADER: x" \
     --data '{"request":"cancel","version":"2.0"}' \
     http://mvs:1080/zosmf/restjobs/jobs/TESTJOB/JOB00123
```

### Using Zowe CLI
```bash
zowe zos-jobs cancel job JOB00123
```

### Success Response
```json
{
    "jobid": "JOB00123",
    "message": "Request was successful.",
    "original-jobid": "JOB00123",
    "jobname": "TESTJOB",
    "owner": "MIKE",
    "status": 0
}
```
