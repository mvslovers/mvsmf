# Detect Unsolicited Message

Reports whether a keyword armed at issue time (`unsol-key`) has appeared in the console message stream since. Part of the z/OSMF Console services (`/zosmf/restconsoles`).

## HTTP Method
GET

## URL Path
`/zosmf/restconsoles/consoles/{console-name}/detections/{detection-key}`

## Path Parameters
- `console-name`: the console used at issue time.
- `detection-key`: from the arming response — async [Issue Command](issue-command.md) with `unsol-key`.

## Response
On successful completion, this request returns HTTP status code 200 (OK):

```json
{ "status": "waiting", "msg": "" }
```

| `status` | Meaning | `msg` |
|----------|---------|-------|
| `detected` | live match count grew past the baseline | the matching message text |
| `expired` | `now − anchor` exceeded the `detect-time` window, no match | `""` |
| `waiting` | neither yet | `""` |

## Error Responses
Console error body (`return-code`/`reason-code`/`reason`):

| HTTP | return-code | reason-code | Cause |
|------|-------------|-------------|-------|
| 500 | 5 | 9 | Unknown / evicted `detection-key` (no armed detection found) |

Regex keywords (`unsolKeyReg=Y` at issue time) are rejected by [Issue Command](issue-command.md) with 400 / 1 / 25.

## Use case
The issued command is a **trigger**; the message you care about arrives **unsolicited** afterwards. Example — start a server and wait until it is actually listening, in one call:

```
PUT  .../consoles/defcn   {"cmd":"S FTPD","unsol-key":"FTPD",
                           "unsol-detect-sync":"Y","unsol-detect-timeout":"20"}
  -> {"status":"detected","msg":"FTPD054I Listening for FTP connections on port 2121"}
```

Useful for automation and for MBT-style test orchestration.

## Implementation (MVS 3.8j)
Count-delta over the **Master Trace Table (MTT)**: at issue, the baseline = number of MTT entries whose (uppercased) text contains `unsol-key`, snapshotted right after the command is issued. Detection fires when the live count grows **past** that baseline — robust against pre-existing occurrences and excluding the command's own solicited response. The armed request (anchor TOD, window, baseline count, keyword) lives in the per-CGI `ntstore` (httpd `cgictx`), keyed by a `detection-key` derived from the issue STCK (microsecond-unique, so detections armed in the same second do not collide). The window comparison uses the TOD high word (~1.05 s/tick), so no 64-bit math. Sync mode polls tightly until `unsol-detect-timeout`; prefer **async** for long waits. The armed detection is subject to LRU + TTL eviction; after eviction the key reports 500 / 5 / 9.

## Examples

### Using curl
```bash
# arm (async) — returns a detection-key
curl -u USER:PASS -X PUT -H 'Content-Type: application/json' \
  -d '{"cmd":"S FTPD","unsol-key":"FTPD"}' \
  http://mvs:1080/zosmf/restconsoles/consoles/defcn

# poll the detection
curl -u USER:PASS \
  http://mvs:1080/zosmf/restconsoles/consoles/defcn/detections/D2E82AB1
```
