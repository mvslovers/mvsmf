# Collect Command Response

Retrieves the **new** response lines for a command issued earlier, since the previous collect. Part of the z/OSMF Console services (`/zosmf/restconsoles`).

## HTTP Method
GET

## URL Path
`/zosmf/restconsoles/consoles/{console-name}/solmsgs/{cmd-response-key}`

## Path Parameters
- `console-name`: the console used at issue time.
- `cmd-response-key`: the key returned by [Issue Command](issue-command.md).

## Response
On successful completion, this request returns HTTP status code 200 (OK):

```json
{ "cmd-response": "new lines joined by \\r, or \"\" if nothing new" }
```

Repeated polling drains the response: each call returns only what arrived since the previous call; once the command is done, collect returns `""`. An unknown key is **not** an error — it returns 200 with an empty `cmd-response`.

### The completion path — and its one caveat

This is how a truncated `cmd-response` is completed. The synchronous capture at
issue time ends when the reply goes quiet, so a command that pauses mid-stream
comes back short, with HTTP 200 and no indicator that anything is missing (see
[Issue Command](issue-command.md#response)). The lines that arrive after that
point are here and nowhere else. `P FTPD` is the worked example: one line from
the issue call, four once collect is polled. Zowe CLI drives exactly this loop
for `--wait-to-collect <seconds>`.

**It re-correlates rather than resuming, and the cursor is what keeps that
pointed at one block.** Every call finds the block again in the Master Trace
Table. Since #214 the search is not "the newest entry matching the command text"
but "the echo carrying the second this key was issued in", so a later command —
another client's, or an operator's at a console — no longer moves the anchor.
The lock taken by the issuing path does not reach here and does not need to.

Three limits follow from the MTT itself and are worth knowing before automating
against this:

- **Two identical commands inside the same second are ambiguous.** The table
  stamps `hh.mm.ss` and nothing finer, so both cursors resolve to the first of
  the two echoes.
- **An echo that has aged out of the trace-table window matches nothing**, and
  collect then answers `""` — the same "done" a drained block gives. The lines
  are gone from the table; a longer history is the hardcopy log's job.
- **If the echo had not landed before the synchronous capture gave up** (a very
  slow system: the capture polls ~3 s), the cursor has no second to match and
  collect falls back to the newest echo of that command — which is how a
  late-arriving reply is still reachable, and is the one case where a later
  identical command can still take the anchor.

## Error Responses
Console error body (`return-code`/`reason-code`/`reason`). A bogus or evicted key yields HTTP 200 with an empty `cmd-response`, not an error.

## Implementation (MVS 3.8j)
Each collect re-correlates the original command in the **Master Trace Table (MTT)** (echo + jobid + command-text + MLWTO-number, same as [Issue Command](issue-command.md)) and returns only the lines beyond what was already delivered. The `cmd-response-key` indexes a cursor in the per-CGI key/value store (`ntstore`, lazy-init in the httpd `cgictx`) holding two things: the **delivered line count** and the **MTT second of the command's own echo**. The MTT has no stable per-line sequence, so the delta is a *count* — lines `[delivered .. total)` — and the second is what pins that count to one block. The count only ever moves forward: a block shorter than what was already delivered is not counted back down, which is what used to leave a mis-anchored key answering empty for good. The cursor is subject to LRU + TTL eviction; after eviction a collect re-correlates from whatever is still in the trace table.

## Examples

### Using curl
```bash
curl -u USER:PASS \
  http://mvs:1080/zosmf/restconsoles/consoles/defcn/solmsgs/E2E82A699B2B2001
```
