# Operator Messages

Every console message mvsMF can write, in one place. The literals live in
[`include/mvsmfmsg.h`](../include/mvsmfmsg.h) — that header is the source of
record, this page is its operator-facing form. Keep the two in step.

## What is on the console and what is not

mvsMF writes a WTO only for **what an operator can act on or must know**.

Anything the client caused — a missing parameter, an unknown route, a data set
that is not there, a malformed job card, a Host header that will not parse — is
reported in the HTTP response and **nowhere else**. Those errors are the
client's to fix, and the operator cannot do anything about them.

That is not only tidiness. `consapi.c` reads the **Master Trace Table**, so
every line mvsMF writes comes straight back out of
`/zosmf/restconsoles/consoles/{name}/solmsgs/{key}` and
`/zosmf/restconsoles/v1/log`. A chatty CGI pollutes its own console API, and a
client that polls a 404 turns one message into a flood.

## Conventions

- **Ids are `MVSMFnnn` + a severity letter**, three digits, one text per id. Two
  call sites that need different wording need different ids; a varying detail
  becomes an argument.
- **Severity is `I`, `W` or `E`.** No `D`, no `T`.
- **Literals are uppercase** — 3270 console convention. Substituted values are
  passed through unchanged: most are MVS names and already uppercase, but USS
  paths and free user text must not be folded.

Ranges:

| Range | Area |
|---|---|
| `MVSMF0xx` | router, CGI entry, shared request handling |
| `MVSMF1xx` | data sets (`restfiles/ds`) |
| `MVSMF2xx` | jobs (`restjobs`) |
| `MVSMF3xx` | USS (`restfiles/fs`) — none yet |
| `MVSMF4xx` | consoles (`restconsoles`) — none yet |
| `MVSMF9xx` | abend recovery and diagnostics |

## MVSMF0xx — router, CGI entry, shared request handling

| Id | Text | Meaning and action |
|---|---|---|
| `MVSMF001E` | `ROUTE TABLE FULL, LIMIT n REACHED` | More routes were registered than `MAX_ROUTES`. Endpoints past the limit do not exist and answer 404. A build problem — raise `MAX_ROUTES` in `router.h`. |
| `MVSMF002E` | `INVALID ROUTE DEFINITION, PATTERN OR HANDLER MISSING` | `add_route()` was called without a pattern or without a handler. The route is skipped; a build problem. |
| `MVSMF003E` | `MIDDLEWARE TABLE FULL, LIMIT n REACHED` | As `MVSMF001E`, for the middleware chain. Middlewares past the limit — including identity — do not run. |
| `MVSMF004E` | `ROUTER OR SESSION POINTER IS NULL` | Internal: `handle_request()` was reached without a router or session. The request is rejected. |
| `MVSMF005E` | `pgm MUST BE CALLED BY THE HTTPD SERVER` | MVSMF was started from TSO or batch instead of as a CGI under httpd. It returns 12. |
| `MVSMF006E` | `STORAGE ALLOCATION FAILED FOR what` | GETMAIN/`malloc` failed. The region is too small or the address space is leaking — see the httpd notes on CGI storage. `what` names the allocation (request body, JCL text, JCL line table). |
| `MVSMF007W` | `RECEIVE TIMED OUT AFTER n RETRIES` | A client stopped sending in the middle of a request body and the read gave up. The worker was tied up for the whole wait. Isolated occurrences are a client or network problem; a steady stream means workers are being consumed. |
| `MVSMF008W` | `SEND TIMED OUT AFTER n RETRIES` | The mirror image on the way out: the client stopped reading, so the socket send buffer stayed full for the whole 10 second budget (100 retries of 100 ms) and the response was abandoned. The connection is dropped and the worker released — before the fix for #298 that same condition spun the worker at 100% CPU forever, so this message replaces a hang. A stopping server (`P HTTPD`) is **not** reported here; it fails the send at once and silently. |

## MVSMF1xx — data sets

All five are server-side failures that carry a return code or `errno` the HTTP
error body does not surface. Client mistakes (missing name, data set not found,
member not found, record too long) produce **no** console message.

| Id | Text | Meaning and action |
|---|---|---|
| `MVSMF101E` | `OPEN FOR WRITE FAILED dsn ERRNO=n` | `fopen()` for write failed on an existing data set. Not a client error: enqueue held by another job, no space, or a security failure. |
| ~~`MVSMF102E`~~ | *retired (#317)* | Was issued for every failed data set create. Both reachable causes are client errors — a name the caller may not allocate under, or parameters that do not fit — so it is reported in the HTTP response only. A denial still appears on the console as RAKF's own `RAKF0005`/`RAKF000A`. The id is not reused. |
| `MVSMF103E` | `DELETE FAILED name RC=n ERRNO=n` | Scratch/uncatalog failed after the data set was found. `name` is the data set, or `DSN(MEMBER)` for a member delete. |
| `MVSMF104E` | `RENAME old TO new FAILED RC=n` | Data set rename failed after the target was confirmed free. |
| `MVSMF105E` | `RENAME dsn(old) TO (new) FAILED RC=n` | Member rename failed after the target was confirmed free. |

## MVSMF2xx — jobs

| Id | Text | Meaning and action |
|---|---|---|
| `MVSMF201E` | `UNABLE TO OPEN THE JES2 CHECKPOINT AND SPOOL DATA SETS` | JES2 is down, or mvsMF cannot open its data sets. Every job endpoint fails while this lasts. Check JES2. |
| `MVSMF202W` | `SPOOL READ jobname(jobid) DSID n: reason` | A spool read broke **after** the first record had gone to the client, so the response was already committed to 200. The records already sent are valid; the rest is missing. `reason` is free text and stays mixed case. |
| `MVSMF203I` | `JOB jobname(jobid) SUBMITTED` | A job entered the system through mvsMF. The audit trail for web-submitted work — `$HASP100` does not say where it came from. mvsMF's own tooling goes through the same door, so a deploy produces a short burst of these (`MBTDEPL`, `MVSMFACT`); that is not client traffic. |
| `MVSMF204E` | `UNABLE TO OPEN THE JES2 INTERNAL READER` | `jesiropn()` failed. No job can be submitted until this clears. |
| `MVSMF205E` | `WRITE TO THE JES2 INTERNAL READER FAILED` | A `jesirput()` failed part-way. The job is incomplete and is not queued. |
| `MVSMF206E` | `CLOSE OF THE JES2 INTERNAL READER FAILED` | `jesircls()` failed. The job may or may not have been queued — check the JES2 queue before resubmitting. |
| `MVSMF207E` | `JESCANJ RETURNED RC=n` | A purge returned a code this build does not know. The client got a 500. Worth reporting with the `RC`. |

## MVSMF9xx — abend recovery and diagnostics

| Id | Text | Meaning and action |
|---|---|---|
| `MVSMF901E` | `HANDLER ABEND Sxxx Unnnn FOR method path` | A handler abended and the router's ESTAE caught it. The client gets a 500 naming the abend code (issue #256). The method and path say which request did it. |
| `MVSMF902W` | `HEADERS ALREADY SENT, NO ERROR RESPONSE POSSIBLE` | The abend came after the response had started, so the client sees a truncated body rather than an error. Always follows a `MVSMF901E`. |
| `MVSMF903W` | `SESSION FILE TABLE FULL, FILE NOT TRACKED` | More data sets are open in one request than `MAX_SESSION_FILES`. The untracked file is not closed if the handler abends. |
| `MVSMF904I` | `RECOVERY CLOSING dsn (DD:ddname)` | Recovery is closing a data set the abending handler left open. Informational; it accompanies a `MVSMF901E`. |
| `MVSMF905W` | `RECOVERY FCLOSE ABENDED FOR SLOT n` | The recovery close abended in turn. The DD stays allocated and its storage stays held for the life of the address space. |
| `MVSMF906W` | `FORCING S0C1 TO EXERCISE THE ESTAE RECOVERY` | `/zosmf/test?fn=abend` is about to abend the worker **on purpose**. Only reachable with `MVSMF_ABEND_TEST=1` in the server environment. Not a fault. |
| `MVSMF907I` | `ENV[n] "name"="value"` | CGI environment dump, one line per variable. Only written when `logging_middleware` is registered — it is not by default. A developer aid, not an operator message. |
| `MVSMF908I` | `RECOVERY CLOSING THE JES SPOOL HANDLE` | Recovery is closing the JES2 spool handle an abending handler left open. Informational; it accompanies a `MVSMF901E`. Its absence after a jobs-API abend is the leak of issue #286. |
| `MVSMF909W` | `RECOVERY JESCLOSE ABENDED, SPOOL DATA SETS STAY OPEN` | The recovery `jesclose()` abended in turn. The JES2 spool data sets stay allocated and their storage stays held for the life of the address space. |
| `MVSMF910W` | `SESSION ALREADY HOLDS A JES HANDLE, THIS ONE NOT TRACKED` | A request opened a second JES handle while the first was still held. No path does this today; the second handle is not closed if the handler abends. Report it — it means a code change broke the one-at-a-time assumption in `Session`. |

## Adding a message

1. Add the literal to `include/mvsmfmsg.h`, in id order, with a doc comment.
   Pick the next free number in the range for the area.
2. Check it against the rule at the top: if the client caused it, do not write
   it. If it duplicates an existing text, reuse that id and make the difference
   an argument.
3. Add a row to the table above.
