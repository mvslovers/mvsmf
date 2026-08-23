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

**It re-correlates rather than resuming, and that part is not deterministic.**
Every call finds the block again by searching the MTT for the *newest* entry
matching the stored command text, so the same command text issued again between
issue and collect — by another client, or by an operator at a console — moves
the anchor to the newer echo, and the delta is then counted against a block the
key was not handed out for. #214's serialization does not cover this: that lock
is held by the issuing path only, and collect runs long afterwards and outside
it. Closing it needs a stable position in the MTT and there is none across
snapshots — tracked in #214.

## Error Responses
Console error body (`return-code`/`reason-code`/`reason`). A bogus or evicted key yields HTTP 200 with an empty `cmd-response`, not an error.

## Implementation (MVS 3.8j)
Each collect re-correlates the original command in the **Master Trace Table (MTT)** (echo + jobid + command-text + MLWTO-number, same as [Issue Command](issue-command.md)) and returns only the lines beyond what was already delivered. The `cmd-response-key` indexes a **delivered-line-count cursor** in the per-CGI key/value store (`ntstore`, lazy-init in the httpd `cgictx`): the MTT has no stable per-line sequence and `hh.mm.ss` is only second-granular, so the cursor tracks a *count*, returning lines `[delivered .. total)` and advancing `delivered` to `total`. The cursor is subject to LRU + TTL eviction; after eviction a collect re-correlates from whatever is still in the trace table.

## Examples

### Using curl
```bash
curl -u USER:PASS \
  http://mvs:1080/zosmf/restconsoles/consoles/defcn/solmsgs/E2E82A699B2B2001
```
