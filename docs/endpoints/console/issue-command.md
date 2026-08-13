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
Returns immediately without `cmd-response` (the `cmd-response-key`/`-url`/`-uri` only).

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
| 500 | 8 | 14 | Cannot get command response (MTT/SVC unavailable) |
| 503 | 8 | 15 | Command **was issued**; response/detection poll abandoned (server quiescing). |

> **`503 / 8 / 15` is a post-issue outcome, not a pre-issue failure.** The command
> has already executed (SVC 34 / MGCR) when the server begins quiescing; only the
> synchronous response capture or unsolicited-message detection is abandoned. A
> blind retry **re-issues the command** — harmless for a display (`D T`) but not
> for a state-changing command (`S`, `V`, `$P`). Treat it as "issued, result
> unavailable," not "not issued."

## Implementation (MVS 3.8j)
mvsMF has no EMCS consoles or TSO address spaces. The command is issued with **SVC 34 (MGCR)** under the authenticated user's ACEE (so RAKF evaluates command authority for that user); the response is read from the **Master Trace Table (MTT)** via `clibmtt`, correlating the command echo and its responses by jobid + command text + MLWTO number. EMCS OPERPARM fields (`auth`, `routcode`, `mscope`, `storage`, `auto`) are accepted but ignored.

### How the response block is identified

The newest MTT entry containing the command text is the **echo**. Its source
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

**Known limitation:** every mvsMF worker shares one source, so two console
requests issued concurrently through the same server can pick up each other's
lines. Tracked in #214.

## Examples

### Using curl
```bash
curl -u USER:PASS -X PUT -H 'Content-Type: application/json' \
  -d '{"cmd":"D T"}' \
  http://mvs:1080/zosmf/restconsoles/consoles/defcn
```
