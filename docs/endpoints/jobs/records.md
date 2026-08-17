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

A spool file that exists but holds nothing returns 200 with an empty body.

## Purged spool output (HTTP 404, reason 10)

The JES2 checkpoint keeps advertising a spool data set after JES2 has printed and purged it —
with a non-zero record count — while its tracks have already been reallocated to other jobs.
Reading such a data set lands on a block belonging to a foreign job and yields no records at
all. That is a loss, not an empty data set, and this endpoint reports it as **404 with
`reason: 10`** (`REASON_SPOOL_GONE`) and a message naming the job and DSID.

**Read the `reason`, not the status.** This answered `410 Gone` between #187 and #250, which
said the same thing in the status line. 410 is not one of the status codes z/OSMF uses, so it
was aligned to the enumerated list and the distinction moved into the error report, where it
costs no conformance. A 404 from this endpoint is therefore either a spool file that is not
there at all, or one whose output was purged — `reason` is what separates them.

The distinction rests on the walk statistics libc370's `jesprint()` reports
(mvslovers/libc370#31):

| Outcome | Meaning | Response |
|---|---|---|
| `JESPR_END` | data set read in full | 200 |
| `JESPR_OPENEND` | foreign block **after** accepted blocks: the data set is still open, everything written so far was read | 200 |
| `JESPR_EMPTY` | the PDDB carries no MTTR — nothing was ever written | 200, empty body |
| `JESPR_FOREIGN`, `record-count > 0` | the **first** block is foreign: nothing was read, and the checkpoint promises records the spool no longer holds | **404**, `reason: 10` |
| `JESPR_FOREIGN`, `record-count = 0` | nothing was ever written; the allocated-but-unwritten track carries a foreign key too | 200, empty body |
| `JESPR_DSID`, `JESPR_IOERR`, `JESPR_LOOP`, `JESPR_CAP`, `JESPR_NOBUF`, `JESPR_NOMEM` | spool read failed or was truncated | 500 |

`JESPR_OPENEND` is why a foreign block alone does not mean "gone": the last written block of an
open data set chains to a track that is allocated but not yet written, so it carries somebody
else's key. Every running job reads that way — measured on the target, HTTPD's `JESMSGLG`
stopped on a foreign block after 350 correctly read lines.

Once the first record has been written to the socket the response is committed to 200. A walk
that goes wrong after that is reported to the operator as `MVSMF202W`, not turned into an error
body — the records already sent are valid.

## Error Responses
- HTTP 400 (Bad Request)
    - Invalid DDID parameter
- HTTP 404 (Not Found)
    - Job not found
    - The spool data set was purged by JES2 and the checkpoint entry is stale —
      distinguished by `reason: 10` (`REASON_SPOOL_GONE`)
- HTTP 500 (Internal Server Error)
    - JES2 system error, or a spool read that failed before any record was sent

## Examples

### Using curl
```bash
curl http://mvs:1080/zosmf/restjobs/jobs/TESTJOB/JOB00123/files/2/records
```

### Using Zowe CLI
```bash
zowe jobs view spool-file-by-id JOB00123 2
```
