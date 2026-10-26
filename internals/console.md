# Console services (z/OSMF restconsoles)

Moved verbatim from `CLAUDE.md` on 2026-10-19; `CLAUDE.md` keeps the rules every session needs and points here.

Read before working on `consapi.c`. The RENT constraint stays in `CLAUDE.md`.

## Console Services (z/OSMF restconsoles)

> **Docs:** `docs/endpoints/console/` (issue-command, collect, detections, hardcopy-log).
> **Status:** all four endpoints implemented (Issues #142–#145).

### Architecture

- All handlers live in `consapi.c` / `consapi.h`.
- **Data source is the Master Trace Table (MTT)**, read via libc370 `clibmtt`
  (`cmtt_new()` snapshot → `cmtt_get_array()`). MVS 3.8j has no EMCS consoles,
  no OPERLOG, and the active SYSLOG on the JES2 spool is **not browsable**
  (records=0) — the MTT is the in-memory tail of the hardcopy log.
- Commands are issued with **SVC 34 (MGCR)** under the caller's ACEE.
- Console error body is `{return-code, reason-code, reason}` (different from
  restfiles' `category`/`rc`/`message`) — use `send_console_error()`.

### Handler ASM labels

```
consoleIssueHandler    PUT  /restconsoles/consoles/{name}                   asm("CAPI0001")
consoleCollectHandler  GET  /restconsoles/consoles/{name}/solmsgs/{key}     asm("CAPI0002")
consoleDetectHandler   GET  /restconsoles/consoles/{name}/detections/{key}  asm("CAPI0003")
consoleLogHandler      GET  /restconsoles/v1/log                            asm("CAPI0004")
```

### A failed MTT snapshot is a failure, not "no matches" (#251, #407)

`cmtt_new()` returns NULL when it cannot allocate the copy of the table, and
the copy is the largest allocation on these paths. An empty table still gives
an array with no entries (`cmtt_get_array()` returns NULL only for a NULL handle
or table), so **no array is the failure and zero entries is an answer**.
`mtt_snap_open()` (`src/mttsnap.c`) draws that line once; its failure value is
`MTT_SNAP_FAILED` (-1), which `correlate_once()`, `mtt_detect_anchor()` and
`mtt_detect_since()` return
in place of a count. Folding it into 0 does not just answer emptily, it answers
*wrongly*:

- a detection anchored on nothing makes the first healthy poll report `detected`
  with a message that was in the table before the command;
- a cursor stored with 0 lines and `echo_secs = -1` makes collect anchor on the
  newest echo of the command — #214's mis-anchor, reopened by an allocation
  failure.

What each caller does with it:

| Caller | On `MTT_SNAP_FAILED` |
|---|---|
| `capture_response()` | skips that poll (no stability step, outputs left as the last good poll set them); `CONS_CAPTURE_FAILED` only if no poll got a copy |
| issue, capture failed | 500 `8/14`, the command **was issued** |
| issue, `unsol-key` baseline | 500 `8/14`; nothing is armed |
| issue, sync `unsol-key` wait | a failed poll is retried; 500 `8/14` if the **last** look at the deadline failed (`timeout` would claim absence) |
| `consoleCollectHandler` | 500 `8/1`; cursor rewritten unchanged (kept alive, not advanced). Also when the 32 KB response buffer cannot be allocated (#475), which is checked before the table is read; both go through `collect_poll()` (`src/collpoll.c`) |
| `consoleDetectHandler` | 500 `8/1`; the detection stays armed |
| `consoleLogHandler` | 500 `8/1` (#251) |

`8/14` is the issue command's post-issue "cannot get the response" code (the
allocation failure for the response buffer already used it); `8/15` stays
"issued, poll abandoned" and is a 503 for a server that is quiescing. `8/1` is
the retrieval error the log uses.

**No WTO**, for any of them: the console API reads the MTT back out, and a
client polling through a storage shortage would write one line per poll into
the table it is reading.

The failure cannot be provoked on MVS. `test/host/tstmtsn.c` runs the real
`mtt_snap_open()`, `mtt_detect_anchor()` and `mtt_detect_since()` against a
fake `cmtt_new()` that fails. `test/host/tstcolpl.c` runs the real
`collect_poll()` against a `malloc` that fails and a correlator that reports
`MTT_SNAP_FAILED`: both give `COLLECT_POLL_FAILED`, the delivered count stays as
it was and nothing is left to free. That the handler answers 500 `8/1` on it, and what `correlate_once()`
does with its snapshot, is checked by review (consapi.c does not compile on
the host).

Collect answered an empty `200` for the buffer until #475: the allocation sat
in the handler ahead of the table, so it was the one failure the #407 fix did
not reach.

### Detection is an anchor, not a count (#195)

`consoleDetectHandler()` and the synchronous wait of the issue command ask
`mtt_detect_since()` for matches **newer than an anchor** (`MTT_ANCHOR`,
`mttsnap.h`): the `hh.mm.ss` of the newest stamped entry at issue, and the
number of matches stamped exactly then. The first design stored a *count* of
matches and reported `detected` when the live count exceeded it. The table is a
byte-bounded wrapping window, so a burst of other messages removes older matches
and the count falls below the baseline while a fresh match is in the table:
measured on a throwaway system, four `D T` then an armed `D T`, eight
`D U,,,000,400`, one more `D T` -- one fresh `IEE136I` in the table, status
`waiting`. Two snapshots without traffic in between were identical, so it is
not a torn copy.

What is left, deliberately: the anchor is taken after `issue_command()`, so the
command's own reply may detect; and `detected` is not latched, so a match that
leaves the window before the next poll reads `waiting` again. Latching needs
room in the kv-store value (`MVSMF_KVS_VALMAX`) for a message, which
`SOL_DETECTION` does not have.

The table is read oldest first, and a line without a time inherits the time of
the line before it. Times are compared modulo 24 hours: a match counts as newer
when it is less than 12 hours ahead of the anchor, so a detection armed for more
than 12 hours (a very long `detect-time`) can no longer see matches stamped
later than that and reads `waiting`.

Reproducing it needs few commands with much output: every command stores a
cursor in the 32-slot kv-store, and enough small commands evict the detection
that is being watched (500 / 5 / 9).

### Notes

- MTT lines carry only `hh.mm.ss` (no date); the hardcopy log reconstructs the
  date by walking newest→oldest and rolling back one day at each midnight crossing.
- `mktime()` on 3.8j does **not** re-apply the TZ offset — keep the window anchor
  and the per-entry timestamps in the same (local-wall-clock) frame.
- The Zowe `zos-logs` SDK reads `resp.totalitems` (lower-case) — match it.
- Reading the real SYSLOG spool is a separate libc370/clibjes2 task (`jesprint`
  breaks on the SYSLOG block validation; see libc370#4).
