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
| `MVSMF3xx` | USS (`restfiles/fs`) |
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
| `MVSMF006E` | `STORAGE ALLOCATION FAILED FOR what` | GETMAIN/`malloc` failed. The region is too small or the address space is leaking — see the httpd notes on CGI storage. `what` names the allocation (request body, JCL line table, spool block, `THE DATA SET LIST`, `THE MEMBER LIST`). For the two lists the shortage hit libc370's list builder, which answers NULL for an empty result and for a failed allocation alike; the catalog or directory is not known to be empty, so the request is not answered with an empty list or a 404 (#360). The request is answered 500. For `THE REQUEST BODY` the body is read to its end first, so the answer reaches the client; until #412 the client saw the connection close instead. |
| `MVSMF007W` | `RECEIVE TIMED OUT AFTER n RETRIES` | A client stopped sending in the middle of a request body and the read gave up. The worker was tied up for the whole wait. Isolated occurrences are a client or network problem; a steady stream means workers are being consumed. |
| `MVSMF008W` | `SEND TIMED OUT AFTER n RETRIES` | The mirror image on the way out: the client stopped reading, so the socket send buffer stayed full for the whole 10 second budget (100 retries of 100 ms) and the response was abandoned. The connection is dropped and the worker released — before the fix for #298 that same condition spun the worker at 100% CPU forever, so this message replaces a hang. A server that is stopping (`P HTTPD`) does not wait out the budget: a send that stalls is abandoned at once and silently, and is not reported here. |

## MVSMF1xx — data sets

All seven are server-side failures that carry a return code or `errno` the HTTP
error body does not surface. Client mistakes (missing name, data set not found,
member not found, record too long) produce **no** console message.

| Id | Text | Meaning and action |
|---|---|---|
| `MVSMF101E` | `OPEN FOR WRITE FAILED dsn ERRNO=n` | `fopen()` for write failed on an existing data set. Not a client error: enqueue held by another job, no space, or a security failure. |
| ~~`MVSMF102E`~~ | *retired (#317)* | Was issued for every failed data set create. Both reachable causes are client errors — a name the caller may not allocate under, or parameters that do not fit — so it is reported in the HTTP response only. A denial still appears on the console as RAKF's own `RAKF0005`/`RAKF000A`. The id is not reused. |
| `MVSMF103E` | `DELETE FAILED name RC=n ERRNO=n` | Scratch/uncatalog failed after the data set was found. `name` is the data set, or `DSN(MEMBER)` for a member delete. |
| `MVSMF104E` | `RENAME old TO new FAILED RC=n` | Data set rename failed after the target was confirmed free. |
| `MVSMF105E` | `RENAME dsn(old) TO (new) FAILED RC=n` | Member rename failed after the target was confirmed free. |
| `MVSMF106E` | `I/O ERROR READING dsn ERRNO=n` | An uncorrectable I/O error on a read — bad track, wrong-length record, device error. Since libc370 1.0.4 that no longer abends the request, so this message is the only place it announces itself. The client gets a broken transfer, never a short reply that looks complete (until #421 a data set read could still end cleanly). Check the volume — and the data set: one that was allocated and never written has no end-of-file mark, so reading it runs into whatever earlier data sets left on its tracks, and one whose label does not match its blocks fails the same way. Neither is a hardware fault; rewriting or reallocating the data set clears it. |
| `MVSMF107E` | `OUT OF SPACE WRITING dsn - RECORDS LOST` | The data set filled while a PUT was writing it. Since libc370 1.0.6 an out-of-space write is a return code rather than ABEND SD37, so the request no longer dies into the router's ESTAE and this is the only console record of it. The client is answered 500. **The data set is left short and its previous content is already gone** — the write does not stage (#243), so there is nothing to roll back to. Add space, then have the client repeat the upload. The message also covers the *last, partial block* of a PUT, which reaches the volume only when the data set is closed (#371) -- including a member smaller than one block, written into a full library. |

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

## MVSMF3xx — USS

| Id | Text | Meaning and action |
|---|---|---|
| `MVSMF301E` | `I/O ERROR READING path RC=n` | A USS file read failed after the reply had started, so the file was **not** delivered whole. `path` is the absolute path as UFSD sees it (not case-folded), `n` the UFSD return code of the failed read (`52` I/O error, also reported when a failed request carried no code of its own; `56` bad file descriptor; `-1` UFSD is not reachable — it was stopped while the file was being read). The `200` and the headers were already on the wire, so the client is told by the connection closing in the middle of the body — curl exits 18 (`transfer closed with outstanding read data remaining`) — never by a body that ends cleanly. Check UFSD and the volume behind the file system; the next read of the same file may succeed. Until #423 this ended as a complete-looking `200` with a truncated file and no message. |

## MVSMF9xx — abend recovery and diagnostics

| Id | Text | Meaning and action |
|---|---|---|
| `MVSMF901E` | `HANDLER ABEND Sxxx Unnnn FOR method path` | A handler abended and the router's ESTAE caught it. The client gets a 500 naming the abend code (issue #256) — except for **S913**, insufficient authority to open, which is a refusal rather than a failure and is answered with the authorization report instead (#315). The message is still issued for it: an abend costs the CGI its storage subpool whatever caused it. The method and path say which request did it. |
| `MVSMF902W` | `HEADERS ALREADY SENT, NO ERROR RESPONSE POSSIBLE` | The abend came after the response had started, so the client sees a truncated body rather than an error. Always follows a `MVSMF901E`. |
| `MVSMF903W` | `SESSION FILE TABLE FULL, FILE NOT TRACKED` | More data sets are open in one request than `MAX_SESSION_FILES`. The untracked file is not closed if the handler abends. |
| `MVSMF904I` | `RECOVERY CLOSING dsn (DD:ddname)` | Recovery is closing a data set the abending handler left open. Informational; it accompanies a `MVSMF901E`. |
| `MVSMF905W` | `RECOVERY FCLOSE ABENDED FOR SLOT n` | The recovery close abended in turn. The DD stays allocated and its storage stays held for the life of the address space. |
| `MVSMF906W` | `FORCING S0C1 TO EXERCISE THE ESTAE RECOVERY` | `/zosmf/test?fn=abend` is about to abend the worker **on purpose**. Not a fault. A build that does not want the diagnostic endpoint at all leaves it out with `-DMVSMF_NO_TEST_ENDPOINT` (#343). |
| `MVSMF907I` | `ENV[n] "name"="value"` | CGI environment dump, one line per variable. Only written when `logging_middleware` is registered — it is not by default. A developer aid, not an operator message. |
| `MVSMF908I` | `RECOVERY CLOSING THE JES SPOOL HANDLE` | Recovery is closing the JES2 spool handle an abending handler left open. Informational; it accompanies a `MVSMF901E`. Its absence after a jobs-API abend is the leak of issue #286. |
| `MVSMF909W` | `RECOVERY JESCLOSE ABENDED, SPOOL DATA SETS STAY OPEN` | The recovery `jesclose()` abended in turn. The JES2 spool data sets stay allocated and their storage stays held for the life of the address space. |
| `MVSMF910W` | `SESSION ALREADY HOLDS A JES HANDLE, THIS ONE NOT TRACKED` | A request opened a second JES handle while the first was still held. No path does this today; the second handle is not closed if the handler abends. Report it — it means a code change broke the one-at-a-time assumption in `Session`. |
| `MVSMF911I` | `RECOVERY RELEASING THE CONSOLE CORRELATION LOCK` | An abending handler held the console serialization ENQ (#214); recovery is releasing it. Informational, and it accompanies a `MVSMF901E`. Its absence after a console-API abend would mean every later console command waits its full acquire budget and then answers 429. |
| `MVSMF912W` | `RECOVERY DEQ ABENDED, CONSOLE COMMANDS WILL BE REFUSED` | The recovery DEQ abended in turn, so the console correlation lock stays held for the life of the address space. `PUT /zosmf/restconsoles/consoles/{name}` will answer `429` from now on; other endpoints are unaffected. Restart the server. |
| `MVSMF913I` | `PSW pppppppp pppppppp ILC n INTC iiii: INSTRUCTION AT EP±X'off', R14 AT EP±X'off'` | Where the abend of the `MVSMF901E` just before it happened (#425). It shows the PSW at the time of error, its instruction length code and interruption code (`0001` operation, `0004` protection, `0007` data, `000D` an `ABEND` SVC), the failing instruction, and R14. For segment and page translation (`0010`/`0011`, an `S0C4` on storage that is not allocated) the PSW already points at the failing instruction, and the message reports it unchanged; for every other code the instruction starts ILC × 2 bytes before the PSW address. R14 is the return address of the last call the failing code made. Only when the fault is in a prologue or in a function that has called nothing yet (as in #425) is it the return address into the caller. Both addresses are given as signed offsets from the module's entry point, because the load address changes from one load to the next. To find the code, add the offset to the `entry=` that `file370 -v` prints for the deployed module, and look that module offset up in the link map. The map must belong to the same build (`fn=version`). If entry + offset is negative or beyond the module's length, the abend was not in MVSMF at all: it was in HTTPD, reached through the httpx vector (`http_printf()` and friends), or in a system routine (an SVC or LPA module; `S913` from OPEN is the usual one). Do not look such an offset up in MVSMF's map. An instruction offset that lands on a function's first instruction while the abend is `S0C1` or `S0C7` means the code there is not what was linked. Issued only when the PSW is known. Report it with the `MVSMF901E` line and the build (`fn=version`). |
| `MVSMF914I` | `STORAGE AT INSTRUCTION-8: xxxxxxxx xxxxxxxx *xxxxxxxx xxxxxxxx` | The 16 bytes around the failing instruction of the `MVSMF913I` just before it: 8 bytes before it, then, after the `*`, 8 bytes starting at it. Compare them with the same offset in the module (`dasm370` on the object, or the link map). If they differ, the code was overwritten while it was loaded, and the bytes that do not belong show what wrote them (#425). Issued only together with `MVSMF913I`, and only when all 16 bytes lie inside the running copy of MVSMF (its extent from the CDE whose entry point is MVSMF's own). Anywhere else the bytes could belong to a buffer with another session's request or credentials, and the console is readable by every authenticated user through `/zosmf/restconsoles`. Also not issued when the read itself fails: it runs under its own recovery. |
| `MVSMF915I` | `RECOVERY RELEASING THE DATA SET LIST LOCK` | An abending handler held the lock that makes data set lists (`GET /zosmf/restfiles/ds`, `fn=listds`) take turns (#436); recovery is releasing it. Informational, and it accompanies a `MVSMF901E`. Its absence after an abend inside a data set list would mean every later list waits for the lock for the life of the address space. |
| `MVSMF916W` | `RECOVERY DEQ ABENDED, DATA SET LISTS WILL WAIT` | The recovery DEQ abended in turn, so the data set list lock stays held for the life of the address space. Every `GET /zosmf/restfiles/ds` waits for it from now on, until the client gives up; other endpoints are unaffected. Restart the server. |

## Adding a message

1. Add the literal to `include/mvsmfmsg.h`, in id order, with a doc comment.
   Pick the next free number in the range for the area.
2. Check it against the rule at the top: if the client caused it, do not write
   it. If it duplicates an existing text, reuse that id and make the difference
   an argument.
3. Add a row to the table above.
