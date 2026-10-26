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
    "file": "//'USER.JCL(MYJOB)'"
}
```

The name is written `//'DSN'` or `//'DSN(MEMBER)'`, as on z/OSMF. Zowe CLI wraps a
name the user typed in quotes once more and sends `//''DSN(MEMBER)''`; that form
is accepted too (#493). The data set name is at most 44 characters and the
member at most 8, so the name can be up to 54 characters long.

## Response
On successful completion, this request returns HTTP status code 200 (OK) and the job status as a JSON object (same format as the [status](status.md) endpoint).

`exec-data=Y` is honoured here too, since the response is built by the same code, but it is of little use: a job that has just been submitted has usually not started yet, so `exec-started` and `exec-ended` are typically `null`. A very short job can already have run by the time the response is built, in which case they carry real instants — do not rely on either outcome. `exec-system` and `exec-member` are known as soon as the job is read in and are filled right away.

`owner` is the submitting userid, and on this endpoint it is answered locally
rather than read from JES2. The owner of a batch job lives in `JCTUSEID`, which
JES2 fills in during conversion — a second or two after the internal reader
closes, so at the instant this response is built it is still blank and the
job's internal text is not on the spool to fall back on either (#210). mvsMF
supplies the userid whose `USER=` it put on the job card, which is the same
answer JES2 arrives at moments later. Once JES2 has written a userid, that one
is reported; nothing overwrites it.

The [status](status.md) endpoint has no such knowledge and does not do this, so
a status poll issued inside that same window can still show an empty `owner`.

## Error Responses
- HTTP 400 (Bad Request)
    - Invalid internal reader parameters
    - No valid JOB card in the submitted JCL or the referenced dataset
    - `JOB card cannot be continued: no room for the comma that joins it to the NOTIFY, USER and PASSWORD operands mvsMF adds` (reason 12) — the card cannot be given the comma that joins it to the card mvsMF adds. Three cases: the last line of the JOB card has data past column 71 and does not end in a comma (sequence numbers in columns 73-80 count; trailing blanks do not), or it ends in column 71 and holds no comma outside quotes and parentheses to cut at (a single operand, say a long quoted name), or the operand it would move is too wide for a continuation card of its own. A card that merely ends in column 70 or 71 is accepted, see [Limitations](#limitations) (#395)
    - Unsupported `Content-Type` (anything other than `application/json` or `text/plain`)
    - Missing `file` field in JSON body
    - A `file` value that is not of the form `//'DSN'`, `//'DSN(MEMBER)'` or the doubly quoted `//''DSN(MEMBER)''`, whose data set name is longer than 44 characters, or whose member is empty, longer than 8 characters or missing its closing parenthesis (#477)
    - Failed to read request content: a malformed `Content-Length`, or a client that stopped sending
- HTTP 413 (Request entity too large)
    - `Content-Length` of 16 MB or more -- more than 24-bit storage can hold. Nothing is read, and the connection is closed
- HTTP 500 (Internal Server Error)
    - `Storage for the request body could not be obtained` (category 7, rc 16). The body is read to its end before the answer goes out, so the answer reaches the client; until #412 the client saw the connection close instead
    - No storage for the JCL line table, or the internal reader refused a card (category 7, rc 16). Until #412 these ended the request with no answer at all
    - Failed to open internal reader
    - Failed to process job card

## Limitations
- USER and PASSWORD are automatically injected into the job card from the authenticated user's credentials. **A `USER=` or `PASSWORD=` already on the submitted card is removed first** — the authenticated identity always wins (#365). Until that fix the injection ran regardless, so such a card got two `USER=` operands and JES2 failed it with `IEF452I JOB NOT RUN - JCL ERROR` / `IEF652I MUTUALLY EXCLUSIVE KEYWORDS`.

  This is a deliberate deviation from z/OSMF, which passes the card through untouched — measured on the reference, a card carrying `USER=` came back out of JESJCL byte for byte and the job ran under that userid. It can do that because there the submitter's identity is propagated and SAF checks the card against it. MVS 3.8j has no propagation, so a card-supplied `USER=` with no validated password would not run the job as that user at all: it would lose the identity and run as the PROD default. Consistently running as whoever authenticated the request is the better of the two answers available here, and it is the identity the response reports as the `owner`.

  The practical consequence: you cannot submit work under a second identity by putting its credentials on the card. Authenticate as that user instead.
 They go on a continuation card mvsMF appends to the JOB statement, ending in a `GENERATED BY MVSMF` comment:

  ```jcl
  //         USER=MIKE,PASSWORD=xxxxxxxx   GENERATED BY MVSMF
  ```

  With an injected `NOTIFY` the card reads `//         NOTIFY=$MVSMF,USER=MIKE,PASSWORD=xxxxxxxx   BY MVSMF`. `NOTIFY` goes first and the comment shortens because the operands have to fit in columns 1-71 (column 72 is the continuation column) and `PASSWORD=` has to stay last — JES2 masks it in listings from that position.
- **A JOB card that fills its last line is continued, not refused (#395).** The continuation card above needs a comma behind the last operand of your card, and a comma is data only up to column 71 (column 72 is the continuation column). So: a last line that already ends in a comma is left as it is; one that ends in column 70 or earlier gets the comma appended; and one that ends in column 71 itself has no room for it, so mvsMF moves the **last operand of that line** (the part behind the last comma outside quotes and parentheses) onto a continuation card of its own, in front of the one it adds. This applies to the last line of the card only, and to both ways of submitting: JCL in the body and `file=//'DSN'`. Blanks at the end of a line, as in a fixed 80-column record, are ignored. The card below is 71 columns long:

  ```jcl
  //MBTENQD JOB (1),'ENQ PROBE CLEANUP',CLASS=A,MSGCLASS=H,MSGLEVEL=(1,1)
  ```

  reaches JES2 as

  ```jcl
  //MBTENQD JOB (1),'ENQ PROBE CLEANUP',CLASS=A,MSGCLASS=H,
  //         MSGLEVEL=(1,1),
  //         NOTIFY=$MVSMF,USER=MIKE,PASSWORD=xxxxxxxx   BY MVSMF
  ```

  The operands and their order are the ones you wrote; the JCL does not reach JES2 byte for byte, though: the line break moved, because no comma can stand behind column 71. Such a card is still refused (reason 12, see [Error Responses](#error-responses)) when there is nothing to cut at — a column-71 line without a comma outside quotes and parentheses — when the last operand is too wide for a continuation card (more than 59 characters), or when the line has data past column 71.
- The `NOTIFY` parameter in the job card is updated with the authenticated user's ID if `&SYSUID` is present. `&SYSUID` may appear in any position on the job card (e.g. `NOTIFY=&SYSUID,REGION=0K`); parameters following it are preserved. Trailing blanks from fixed 80-column records are ignored during this rewrite.
- **`NOTIFY=$MVSMF` is added when the card has none.** MVS records a job's completion code only for jobs that requested a notify, so a card without one used to yield `"retcode": null` for the whole life of the job — however it ended — and clients that poll for a completion code, such as `zowe jobs submit --wait-for-output`, waited forever. Since #307 the generated continuation card carries a `NOTIFY` whenever the submitted card names none of its own; a card that already has one is left alone.

  **The userid is a placeholder, not the caller.** `$MVSMF` is a syntactically valid userid — `$` is a national character — that nobody allocates, and that is the point. JES2 answers a notify with `SE '$HASP165 …',LOGON,USER=(x)`, and a *defined* userid consumes a `SYS1.BRODCAST` mail record per job. That pool is small and fixed (1440 records on the reference stand), and 84 records piled up in a single afternoon of running this project's test suite. An undefined userid consumes none and provokes no message; the MTT cost is identical either way. Measured, see [Job Status → Limitations](status.md#why-the-notify-names-a-placeholder-and-not-the-caller).

  If you *want* to be notified, write `NOTIFY` on the card yourself — mvsMF never touches one that is already there.
- The whole feature needs JES2 usermod **`SYZJ201`** to be installed; see [Prerequisites](../../../README.md#the-syzj201-usermod).
- **The JOB statement needs a programmer name.** It is the second positional
  operand, and a card carrying only accounting information — `//MYJOB JOB
  'SOME TEXT',CLASS=A` — has none: the quoted string is the accounting field.
  mvsMF accepts such a job, JES2 gives it a jobid, and MVS then flushes it with
  `IEF633I PROGRAMMER NAME MISSING ON THE JOB STATEMENT` / `IEF452I JOB NOT RUN
  - JCL ERROR`. The submit response cannot report this — the job has not run
  yet — so it arrives as `"retcode": "JCL ERROR"` on the next status poll, and
  the message itself is in `JESYSMSG`. Write the card as `//MYJOB JOB
  (ACCT),'SOME NAME',CLASS=A`. Whether the name is mandatory is an installation
  setting; on the reference stand it is.

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
  -d '{"file":"//'\''USER.JCL(MYJOB)'\''"}' \
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
