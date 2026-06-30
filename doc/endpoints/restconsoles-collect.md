# Console Services — Collect Command Response (Endpoint 2)

`GET /zosmf/restconsoles/consoles/{console-name}/solmsgs/{cmd-response-key}`

Retrieves the **new** response lines for a command issued earlier (endpoint 1),
since the previous collect. Endpoint 2 of 4 of the z/OSMF Console services.

## Data source (3.8j)

There is no per-command spool dataset to read. Each collect re-correlates the
original command in the **Master Trace Table (MTT)** (same echo + jobid +
command-text + MLWTO-number correlation as endpoint 1) and returns only the
lines beyond what was already delivered.

The `cmd-response-key` indexes a small **delivered-line-count cursor** kept in
the per-CGI key/value store (`ntstore`, lazy-init in the httpd `cgictx`):

| Cursor field | Meaning |
|--------------|---------|
| `issue_tod`  | STCK at issue (correlation anchor) |
| `delivered`  | lines already returned to the client |
| `cmd`        | uppercased command text (re-correlation) |

Delta semantics: the MTT has no stable per-line sequence and `hh.mm.ss` is only
second-granular, so the cursor tracks a **count**, not a timestamp — collect
returns lines `[delivered .. total)` and advances `delivered` to `total`.

## Request

Headers: Basic Auth. No body.

- `{console-name}` — echoed; one logical console.
- `{cmd-response-key}` — the key returned by endpoint 1.

## Response — HTTP 200

```json
{ "cmd-response": "<new lines joined by \\r, or \"\" if nothing new>" }
```

- `""` when the command produced no further lines since the last collect, or
  when the key is unknown / the store is unavailable (stateless-safe: an
  unknown key simply yields nothing, not an error).
- Repeated polling drains the response: each call returns only what arrived
  since the previous call; once the command is done, collect returns `""`.

## Errors

Same console error body as endpoint 1
(`return-code` / `reason-code` / `reason`). A bogus key is **not** an error —
it returns `200` with an empty `cmd-response`.

## Notes

- The cursor lives only as long as the `cgictx` store slot (LRU, TTL ~300
  TOD-high ticks); after eviction a collect re-correlates from the MTT and
  returns whatever is still in the trace table.
- See [Issue Command](restconsoles-issue-command.md) (endpoint 1) and
  [Detections](restconsoles-detections.md) (endpoint 3).
