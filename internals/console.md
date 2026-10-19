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

### Notes

- MTT lines carry only `hh.mm.ss` (no date); the hardcopy log reconstructs the
  date by walking newest→oldest and rolling back one day at each midnight crossing.
- `mktime()` on 3.8j does **not** re-apply the TZ offset — keep the window anchor
  and the per-entry timestamps in the same (local-wall-clock) frame.
- The Zowe `zos-logs` SDK reads `resp.totalitems` (lower-case) — match it.
- Reading the real SYSLOG spool is a separate libc370/clibjes2 task (`jesprint`
  breaks on the SYSLOG block validation; see libc370#4).
