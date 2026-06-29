# Console Services — Issue Command (Endpoint 1)

`PUT /zosmf/restconsoles/consoles/{console-name}`

Issues an MVS operator command and (synchronously) returns the captured
command response. Part of the z/OSMF Console services
(`/zosmf/restconsoles/...`) — endpoint 1 of 4.

## Data source (3.8j)

mvsMF has no EMCS consoles or TSO address spaces. Instead:

- The command is issued with **SVC 34 (MGCR)** under the **authenticated
  user's ACEE** (established by `authmw.c` via `racf_set_acee`), so RAKF
  evaluates command authority against that user.
- The response is captured by reading the **Master Trace Table (MTT)** via
  `clibmtt` (`cmtt_new()` snapshot → `cmtt_get_array()`), correlating the
  command echo and its responses by **jobid + command text + MLWTO number**.

See `doc/console-services.md` (design) and the `/zosmf/test?fn=cmd` probe.

## Request

Headers: Basic Auth, `Content-Type: application/json`.

Body (JSON):

| Field | Req | mvsMF behaviour |
|-------|-----|-----------------|
| `cmd` | yes | issued via SVC 34; max 126 chars |
| `async` | no | `Y` / `N` (default `N`) — changes the response shape |
| `system` | no | if set and != local system (`CVTSNAME`) → **400** |
| `sol-key` | no | plain substring; sets `sol-key-detected` if found in the response |
| `solKeyReg=Y` | no | **400** (rc 1 / reason 25) — regex not supported (MVP) |
| `unsol-key`, `detect-time`, `unsol-detect-sync`, `unsol-detect-timeout`, `unsolKeyReg` | no | **deferred to endpoint 3** (unsolicited) — ignored here |
| `auth`, `routcode`, `mscope`, `storage`, `auto` | no | EMCS OPERPARM — **ignored** (no EMCS on 3.8j) |

`{console-name}`: validated as 2–8 alphanumeric (first char alpha or `# $ @`),
otherwise 400 (rc 1 / reason 14). Echoed in the returned URLs; there is one
logical console.

## Response

### Synchronous (`async` omitted or `N`) — HTTP 200

After issuing, the MTT is polled for up to ~3 s for the correlated response.

```json
{
  "cmd-response": "<response lines joined by \\r, or \"\" if none in time>",
  "cmd-response-key": "<opaque key>",
  "cmd-response-url": "http://host:port/zosmf/restconsoles/consoles/<cn>/solmsgs/<key>",
  "cmd-response-uri": "/zosmf/restconsoles/consoles/<cn>/solmsgs/<key>",
  "sol-key-detected": <bool>          // only when sol-key was supplied
}
```

`cmd-response` of `""` means "nothing captured within the window" — the client
uses `cmd-response-url` (endpoint 2, Collect) to retrieve the rest.

### Asynchronous (`async` = `Y`) — HTTP 200

Returns immediately, without `cmd-response`:

```json
{
  "cmd-response-key": "<opaque key>",
  "cmd-response-url": "…/solmsgs/<key>",
  "cmd-response-uri": "/zosmf/restconsoles/consoles/<cn>/solmsgs/<key>"
}
```

**MVP cut:** the `consoleAuth/Routcde/Mscope/Storage/Auto` and `ipcmsgqbytes`
"first-time" informational fields are omitted (no persistent console state).
`detection-*` fields (unsolicited) belong to endpoint 3.

### cmd-response-key

Self-describing, **no server-side table**: encodes **jobid + MLWTO number +
TOD anchor**. This lets the Collect endpoint (2) re-find the command's lines in
the MTT statelessly. The delta semantics of Collect are decided with endpoint 2.

## Errors

Console services use a **different** error body than restfiles/restjobs —
`return-code` / `reason-code` / `reason` (not `category`/`rc`/`message`):

```json
{ "return-code": <category>, "reason-code": <specific>, "reason": "<text>" }
```

| HTTP | return-code | reason-code | Cause |
|------|-------------|-------------|-------|
| 400 | 1 | 6 | Content-Type not application/json |
| 400 | 1 | 12 | body not JSON |
| 400 | 1 | 13 | `cmd` missing or empty |
| 400 | 1 | 14 | bad console name (length/format) |
| 400 | 1 | 17 | command length > 126 |
| 400 | 1 | 25 | regex sol-key/unsol-key not supported |
| 400 | 1 | 5  | `system` is not the local system |
| 500 | 8 | 14 | cannot get command response (MTT/SVC unavailable) |

## Notes / open items

- Sync ~3 s wait mechanism (STIMER vs TOD-clock loop) decided at implementation.
- Per-user command authority via RAKF + active ACEE to be verified empirically.
- Endpoints 2 (Collect), 3 (Unsolicited detection), 4 (Hardcopy log) follow.
