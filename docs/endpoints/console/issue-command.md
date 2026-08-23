# Issue Command

Issues an MVS operator command and returns the captured command response. Part of the z/OSMF Console services (`/zosmf/restconsoles`).

## HTTP Method
PUT

## URL Path
`/zosmf/restconsoles/consoles/{console-name}`

## Path Parameters
- `console-name`: 2–8 chars (first alpha or `# $ @`). One logical console; echoed in the returned URLs.

## Request Headers
- `Content-Type`: `application/json` (required)

## Request Body

```json
{
    "cmd": "D T",
    "async": "N",
    "sol-key": "string",
    "unsol-key": "string",
    "unsol-detect-sync": "N",
    "unsol-detect-timeout": "20",
    "detect-time": "30"
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `cmd` | yes | Command text, issued via SVC 34 (MGCR). Max 126 chars. |
| `async` | no | `Y`/`N` (default `N`). Changes the response shape. |
| `sol-key` | no | Plain substring; sets `sol-key-detected` if found in the response. |
| `solKeyReg` | no | `Y` → 400 (regex not supported). |
| `unsol-key` | no | Arm unsolicited-message detection — see [Detect Unsolicited Message](detections.md). |
| `unsol-detect-sync` | no | `Y` → block inline up to `unsol-detect-timeout`, return `status`/`msg`; else async. |
| `unsol-detect-timeout` | no | Sync poll bound in seconds (default 20, max 60). |
| `detect-time` | no | Async detection window in seconds (default 30). |
| `unsolKeyReg` | no | `Y` → 400 (regex not supported). |
| `system` | no | If set and not the local system → 400. |

## Response

### Synchronous (`async` omitted or `N`) — HTTP 200
After issuing, the MTT is polled for ~3 s for the correlated response.

```json
{
    "cmd-response": "response lines joined by \\r, or \"\" if none in time",
    "cmd-response-key": "opaque key",
    "cmd-response-url": "http://host:port/zosmf/restconsoles/consoles/{name}/solmsgs/{key}",
    "cmd-response-uri": "/zosmf/restconsoles/consoles/{name}/solmsgs/{key}",
    "sol-key-detected": false
}
```

`sol-key-detected` is present only when `sol-key` was supplied. A `cmd-response` of `""` means nothing was captured within the window — use the [Collect Command Response](collect.md) endpoint to retrieve the rest.

`cmd-response-url` (and `detection-url`, where present) take their host from the request's
`Host` header and their scheme from `X-Forwarded-Proto` — `https` when a reverse proxy
reports it, `http` otherwise. mvsMF itself only ever sees plain HTTP behind a
TLS-terminating proxy, so the header is the only source for the client's scheme.

### Asynchronous (`async` = `Y`) — HTTP 200
Returns without `cmd-response` (the `cmd-response-key`/`-url`/`-uri` only).

**It is not faster than the synchronous form, and deliberately so.** Since #214
the server still waits for the response block to settle before replying, because
an async command writes its echo and reply lines into the Master Trace Table
exactly like a synchronous one — returning early would let its lines land inside
another request's open block. What `async` saves is the payload, not the wait.
The cursor still starts at zero, so a later `collect` returns the whole block.

### With `unsol-key` (unsolicited detection)
Adds detection fields on top of the keys above:
- **async** (default): `detection-key`, `detection-url`, `detection-uri` — poll the URL for `waiting`/`detected`/`expired`.
- **sync** (`unsol-detect-sync=Y`): blocks up to `unsol-detect-timeout`, then returns `status` (`detected`/`timeout`) and `msg`.

See [Detect Unsolicited Message](detections.md).

## Error Responses
Console services use a `return-code`/`reason-code`/`reason` body (not `category`/`rc`/`message`):

```json
{ "return-code": 1, "reason-code": 13, "reason": "..." }
```

| HTTP | return-code | reason-code | Cause |
|------|-------------|-------------|-------|
| 400 | 1 | 6 | Content-Type not `application/json` |
| 400 | 1 | 12 | Body not valid JSON |
| 400 | 1 | 13 | `cmd` missing or empty |
| 400 | 1 | 14 | Bad console name (length/format) |
| 400 | 1 | 17 | Command length > 126 |
| 400 | 1 | 25 | Regex `sol-key`/`unsol-key` not supported |
| 400 | 1 | 5  | `system` is not the local system |
| 429 | 8 | 16 | Another console command is in progress; the command was **not** issued. |
| 500 | 8 | 14 | Cannot get command response (MTT/SVC unavailable) |
| 503 | 8 | 15 | Command **was issued**; response/detection poll abandoned (server quiescing). |
| 503 | 8 | 17 | Server quiescing; the command was **not** issued. |

> **`429 / 8 / 16` and `503 / 8 / 17` are safe to retry; `503 / 8 / 15` is not.**
> The first two are refusals *before* SVC 34 — nothing executed. Only `8 / 15`
> means the command already ran. The distinction is the whole reason they are
> separate reason codes: it decides whether an operator may re-send an `S`, `V`
> or `$P`.

> **`503 / 8 / 15` is a post-issue outcome, not a pre-issue failure.** The command
> has already executed (SVC 34 / MGCR) when the server begins quiescing; only the
> synchronous response capture or unsolicited-message detection is abandoned. A
> blind retry **re-issues the command** — harmless for a display (`D T`) but not
> for a state-changing command (`S`, `V`, `$P`). Treat it as "issued, result
> unavailable," not "not issued."

## Implementation (MVS 3.8j)
mvsMF has no EMCS consoles or TSO address spaces. The command is issued with **SVC 34 (MGCR)** under the authenticated user's ACEE (so RAKF evaluates command authority for that user); the response is read from the **Master Trace Table (MTT)** via `clibmtt`, correlating the command echo and its responses by jobid + command text + MLWTO number. EMCS OPERPARM fields (`auth`, `routcode`, `mscope`, `storage`, `auto`) are accepted but ignored.

### One command at a time (#214)

Commands are serialized. The bracket runs from just before SVC 34 to the end of
convergence, so **at most one mvsMF response block is open in the MTT at a time**
— which is what makes a block a block, since every worker writes under the
address space's one source and MVS interleaves the table line by line rather than
block by block.

The acquire is conditional with a ~5 s budget; past that the request is refused
`429 / 8 / 16` rather than parking a worker. Measured ceiling for issued commands
is roughly **2.2/s**, and a command whose reply is slow holds the lock for the
whole poll window (2.1–3.1 s).

**Only the issuing path takes it.** `collect`, `detections` and the hardcopy log
write nothing to the table and run unserialized, so polling clients stay fully
parallel — the cost lands on the command rate, not the request rate.

Two things it does **not** cover, both by construction:

- **A command issued outside mvsMF** — an operator at a console, a TSO user with
  OPER, an automation task. Those cannot be locked against, and their lines can
  still end or contaminate a block.
- **`collect`**, which re-correlates long afterwards and outside the lock. It
  still anchors on the newest matching entry and can walk past the end of its own
  block. Tracked in #214.

On an httpd without the `cgictx` service there is no context to lock on and
requests proceed **unserialized** — the same graceful degradation the cursor
store makes.

### How the response block is identified

The newest MTT entry containing the command text is the **echo**.

**Known race, not closed:** the first poll runs immediately after SVC 34, before
the echo is guaranteed to be in the table, so a *previous* identical command
still in the window can be anchored on — converging on its stale block and
returning the previous response. Two closures were tried on target and both
measured worse than the race: by issue timestamp (MTT entries carry `hh.mm.ss`
and back-to-back requests land in the same second routinely, so it resolved to
the previous command's echo), and by a match count taken before issuing (a count
over a *wrapping* window — after any burst of one command its oldest echoes sit
at the aging edge, each new entry evicts one as ours is added, the count never
grows, and every capture returns empty). Closing it needs a stable position in
the MTT, and there is none across snapshots. Tracked in #214. Its source
field (`"STC  nnn"`) seeds the block, and following entries are kept while they
carry that source, a blank source (an MLWTO header such as `IEE102I`), or a
matching MLWTO continuation number. A differently attributed originator ends the
block.

**A command routed to another address space is the exception.** The echo carries
the *issuer's* source — mvsMF's own worker — while the reply to `F <stc>,...` is
written by the *target* started task under its own source. So while the block has
produced no line yet, the first differently attributed originator is adopted as
the block's source, once, provided it falls in the echo's own second. Without
that, every `MODIFY` to anything but HTTPD itself returned an empty
`cmd-response` (issue #174); `D T` and `F HTTPD,...` were unaffected only because
there the issuer *is* the target.

The same-second requirement is what keeps an unrelated message written between
the echo and the reply from hijacking the block. MTT timestamps are
second-granular, so that is as tight as correlation gets here.

**Historical:** before #214 every mvsMF worker shared one source with no
serialization, so two concurrent console requests picked up each other's lines —
measured at 5 of 12 responses contaminated under two competing clients. See
*One command at a time* above.

## Examples

### Using curl
```bash
curl -u USER:PASS -X PUT -H 'Content-Type: application/json' \
  -d '{"cmd":"D T"}' \
  http://mvs:1080/zosmf/restconsoles/consoles/defcn
```
