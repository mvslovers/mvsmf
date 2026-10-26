# Detect Unsolicited Message

Reports whether a keyword armed at issue time (`unsol-key`) has appeared in the console message stream since. Part of the z/OSMF Console services (`/zosmf/restconsoles`).

> **Authorization:** needs READ on `FACILITY MVSMF.CONSOLE`; without it (or while the profile is not defined) the answer is `500`, category 4, in the `category`/`rc`/`message`/`details` form rather than the `return-code` form below; a request with no resolved user gets `401`. See [Issue Command](issue-command.md).

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
| `detected` | a matching message is in the table that is newer than the anchor taken at issue | the newest such message text |
| `expired` | `now − anchor` exceeded the `detect-time` window, no match | `""` |
| `waiting` | neither yet | `""` |

## Error Responses
Console error body (`return-code`/`reason-code`/`reason`):

| HTTP | return-code | reason-code | Cause |
|------|-------------|-------------|-------|
| 500 | 5 | 9 | Unknown / evicted `detection-key` (no armed detection found) |
| 500 | 8 | 1 | The copy of the Master Trace Table could not be made. The detection stays armed: ask again. Not `waiting` and not `expired` — both would say the keyword is not there, and the table could not be looked at. |

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
Anchor over the **Master Trace Table (MTT)**: right after the command is issued, the detection remembers where the table ends -- the `hh.mm.ss` of its newest stamped entry, and how many entries containing `unsol-key` (uppercased) carry exactly that second. A poll reports `detected` when the table holds a matching entry stamped later than the anchor, or more matches at the anchor's own second than were counted. The MTT is a window that wraps, bounded in bytes: after a burst of messages the oldest entries are gone, so a *count* of matches compared with a baseline falls even though a fresh match has arrived, and a count-based check would answer `waiting` for it. Only the position is stable across the wrap, so the position is what is stored. The stamp carries no date; it is read modulo 24 hours (less than half a day ahead counts as later), and an entry without a time of its own, such as the continuation line of a multi-line message, takes the time of the entry before it.

Things to know:

- **The command's own response can detect.** The anchor is taken after the command is issued, and the command's reply may land on either side of it; a `D T` armed with `unsol-key: IEE136I` can report `detected` on its own reply. Detection is meant for messages the command triggers afterwards, which is how the example above uses it.
- **`detected` is not latched.** Every poll looks at the table afresh. A matching message that has left the window by the time of the next poll no longer counts, and the status falls back to `waiting` (or `expired`). Poll within the window's lifetime -- minutes on a quiet system, seconds under heavy console traffic.
- The one-second grain of the stamp cannot tell two matches in the anchor's own second apart from the ones counted before; a match arriving in that second is seen only if it raises the count above what the anchor recorded.

The armed request (anchor TOD, window, anchor, keyword) lives in the per-CGI `ntstore` (httpd `cgictx`), keyed by a `detection-key` derived from the issue STCK (microsecond-unique, so detections armed in the same second do not collide). The window comparison uses the TOD high word (~1.05 s/tick), so no 64-bit math. Sync mode polls tightly until `unsol-detect-timeout`; prefer **async** for long waits. The armed detection is subject to LRU + TTL eviction; after eviction the key reports 500 / 5 / 9.

If the table cannot be copied at issue time, no anchor exists and nothing is armed: the issue request answers 500 / 8 / 14 (the command was issued, see [Issue Command](issue-command.md#error-responses)). Without an anchor every message already in the table would count as new.

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
