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

### `retcode` needs the `SYZJ201` usermod

The `retcode` field is derived from `JCTCNVRC` in the JES2 Job Control Table (JCT). After execution, a completion code with high byte `0x77` is written back there, from which the condition code or ABEND code is decoded.

That write-back is not part of MVS. It comes from JES2 usermod **`SYZJ201`** (source member `SYZYGY1A`), and mvsMF reports `null` for every job on a system without it — see [Prerequisites](../../../README.md#the-syzj201-usermod), which also covers why the `IEFACTRT` SMF exit is *not* required.

### `retcode` needs `NOTIFY` — which mvsMF now adds for you

`SYZYGY1A` is COPYed into `HASPSSSM` at sequence `T2269950` — inside the block guarded by

```
CLI   JCTTSUAF,0          WAS NOTIFY REGUESTED
BE    HJE005              IF NOT SKIP NOTIFY
```

so it runs only for a job whose card carries `NOTIFY`. The same guard covers JES2's own writes to `JCTJTFLG` and `JCTJTCC`. Without `NOTIFY`, therefore, *every* one of these fields stays at 0 and `retcode` is `null` — even for a job that completed normally, and even for one that failed.

Measured, two jobs differing only in the job card: with `NOTIFY` the RC 12 arrives as `JCTCNVRC=7700000C` → `"CC 0012"`; without it the field stays `00000000` → `null`, although the step ran and returned 12 either way.

No z/OSMF client adds `NOTIFY` — on z/OS none needs to — so this made `retcode` null for essentially every job submitted through the API, and `zowe jobs submit --wait-for-output` polls until `retcode` is non-null and so never returned. Since #307, **`PUT /zosmf/restjobs/jobs` adds `NOTIFY=$MVSMF` to any card that carries none**, on the same continuation card it already generates for `USER=`/`PASSWORD=`; see [Submit Job → Limitations](submit.md#limitations). A card that already names a `NOTIFY` is untouched.

### Why the notify names a placeholder and not the caller

It named the caller first. JES2 answers the notify with

```
SE '$HASP165 JOB 1395  NTFYRL ENDED- MAX COND CODE 0012  ',LOGON,USER=(IBMUSER)
```

and `LOGON` means: if that userid has a `SYS1.BRODCAST` mail slot, queue the
message there until it next logs on. `SYS1.BRODCAST` is a fixed-size direct
data set — 1440 records of 129 bytes on the reference stand — and every
API-submitted job consumes one. **One afternoon of running the test suite
filled it**: 84 messages queued, and from then on every further notify was
discarded without a word, including those from real TSO sessions.

`$MVSMF` has no mail slot, so it consumes nothing. Measured on MVS 3.8j, three
otherwise identical jobs, `SYS1.BRODCAST` dumped with `IDCAMS PRINT` before and
after each:

| `NOTIFY=` | userid defined | `JCTCNVRC` | `retcode` | BRODCAST record | MTT lines |
|---|---|---|---|---|---|
| `IBMUSER` | yes | `7700000C` | `CC 0012` | **yes** | 8 |
| `MVSCE01` | yes | — | — | **yes** | 8 |
| `NOTIFYX` | no | `7700000C` | `CC 0012` | **no** | 8 |

No `IKJ*`/`IEE*`/`IEA*` message appeared for the undefined userid in a ten
minute window — an unknown notify target is not an error, it is a no-op. The
MTT cost is the same in every row, so nothing is traded away: the `SE` line is
written whether or not the target exists.

`$` is a national character, so `$MVSMF` is a valid userid as far as the
converter is concerned — verified, it converts and records the code — while
being one nobody allocates. If it ever became a real user, that user would
start collecting exactly the mail this avoids.

Two further consequences:

- **A caller who wants the notification can still have it** by writing `NOTIFY`
  on the card. mvsMF only fills in a card that has none, so the choice stays
  with the submitter rather than being made for them in the noisier direction.
- A job that reaches MVS by any other route — a card punched to the internal
  reader by another program, a job submitted from TSO without `NOTIFY` — still
  reports `null`. The gate is JES2's, and mvsMF can only rewrite what it
  submits itself.

### A job that failed before any step ran reports `JCL ERROR`

With `NOTIFY` present, a job that dies during job selection — an allocation
failure, `IEF453I JOB FAILED - JCL ERROR` — leaves `JCTCNVRC` at `0x77000000`.
That value is truthful: `SYZYGY1A` stores the highest `SCTSEXEC` over the
steps, and no step ran, so the highest is zero. It is byte-for-byte identical
to a clean run.

The failure is carried in `JCTJTFLG` instead, whose `JF` bit HASPSSSM sets at
`T2269500` under the comment `SET JCL ERROR FLAG`. mvsMF reports `JCL ERROR`
when that byte is exactly the `JF` bit — the same equality test the usermod
itself uses in `SYZYGY1B` before printing its `- MAX COND CODE nnnn` line. A
job that failed its `COND` carries `JF|CF` and keeps its condition code.

Measured on MVS 3.8j, all with `NOTIFY`:

| ended as | `JCTCNVRC` | `JCTJTFLG` | `retcode` |
|---|---|---|---|
| clean | `77000000` | `00` | `CC 0000` |
| `IEF451I ENDED BY CC 0012` | `7700000C` | `C0` | `CC 0012` |
| `IEF450I ABEND S806` | `77806000` | `20` | `ABEND S806` |
| `IEF453I JOB FAILED - JCL ERROR` | `77000000` | `80` | `JCL ERROR` |
| `IEF452I JOB NOT RUN - JCL ERROR` | `00000004` | `00` | `JCL ERROR` |

`/zosmf/test?fn=job&jobname=NAME` reports these fields directly.

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
