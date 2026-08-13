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
- `status` (optional): Filter by job status (`INPUT`, `ACTIVE`, `OUTPUT`). Use `*` for all. See [Status filter](#status-filter).
- `max-jobs` (optional): Maximum number of jobs **returned** (1-1000). Default: 1000. The filters are applied first, so `max-jobs` caps the matching jobs, not the checkpoint entries scanned.
- `exec-data` (optional): `Y` adds the execution timestamps to each job object. Any other value (or omitting the parameter) returns the object unchanged. The Zowe CLI sends `exec-data=Y` for `zowe jobs list jobs --exec-data`.

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

With `exec-data=Y`, two further fields follow `retcode`:

```json
        "exec-started": "2026-08-07T18:57:10.000Z",
        "exec-ended": "2026-08-07T18:57:10.000Z"
```

See [Execution timestamps](#execution-timestamps).

## Status filter

`status` is compared against the value the job reports in its own `status`
field — the same derivation, so the filter can never disagree with the response.
The comparison is case insensitive (`status=active` works), and `*` or an
omitted parameter means no filtering.

JES2 on 3.8j has queues z/OSMF does not name, so besides `INPUT`, `ACTIVE` and
`OUTPUT` a job can report `XMIT`, `SETUP`, `RECEIVE` or `UNKNOWN`; those values
can be filtered on as well. The queue flags are not exclusive — a job on the
execution and the output queue at once reports `ACTIVE` — so a job matches
exactly one status.

A value that names no status (`status=NOSUCH`) is not an error: it simply
matches nothing, and the request returns HTTP 200 with an empty array.

The filter is applied by mvsMF while walking the checkpoint, not by JES2 —
unlike `prefix` and `jobid`, which become the JES filter for the scan itself.

## Execution timestamps

`exec-started` and `exec-ended` are ISO 8601 instants in **UTC**, with a
millisecond fraction and a literal `Z` — the format real z/OSMF uses. JES2
records these with second resolution, so the fraction is always `.000`; z/OSMF
itself reports `exec-submitted` the same way, so this is compatible rather than
a compromise.

A job that has not reached that stage yet returns `null` for the field, not a
placeholder date. An active job therefore has `exec-started` set and
`exec-ended` null.

The timestamps are always UTC and never local time: the server cannot know the
caller's timezone, so a local string would be unlabelled and the client could
not tell which zone it received. Zowe and browsers localise the instant
themselves.

**`exec-submitted` is not implemented.** JES2 records it as `JCTRDRON` /
`JCTRDTON` (time and date on the input processor), which libc370's `JESJOB`
does not carry — tracked in mvslovers/libc370#79. The field is omitted rather
than guessed.

`exec-system` and `exec-member` are likewise not implemented (mvslovers/mvsmf#209).

### Provenance of the format

The conversion was validated against httpd's `/jes/status`, which emitted the
same instants in the same format after mvslovers/httpd#151 — the two agreed to
the second on the same job.

**Do not reach for that comparison again:** httpd retires `/jes/*` (and `/dsl/*`)
in 4.0.0, since these endpoints are what mvsMF replaces. The reference is
recorded here because it is how the timezone handling was verified, not as a
check to re-run.

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

# List only the jobs currently executing
curl "http://mvs:1080/zosmf/restjobs/jobs?owner=*&status=ACTIVE"

# List jobs with execution timestamps
curl "http://mvs:1080/zosmf/restjobs/jobs?prefix=TEST*&exec-data=Y"
```

### Using Zowe CLI
```bash
zowe jobs list jobs
zowe jobs list jobs --owner "*" --prefix "TEST*"
zowe jobs list jobs --prefix "TEST*" --exec-data
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
        "url": "http://mvs:1080/zosmf/restjobs/jobs/TESTJOB/JOB00123",
        "files-url": "http://mvs:1080/zosmf/restjobs/jobs/TESTJOB/JOB00123/files",
        "status": "OUTPUT",
        "retcode": "CC 0000"
    }
]
```

`url` and `files-url` are absolute. Their host comes from the request's `Host` header and
their scheme from `X-Forwarded-Proto` (`https` when a reverse proxy reports it, `http`
otherwise).
