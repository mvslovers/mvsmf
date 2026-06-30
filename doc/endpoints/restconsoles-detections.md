# Console Services — Detect Unsolicited Message (Endpoint 3)

`GET /zosmf/restconsoles/consoles/{console-name}/detections/{detection-key}`

Reports whether a keyword armed at issue time (endpoint 1, `unsol-key`) has
appeared in the console message stream since. Endpoint 3 of 4 of the z/OSMF
Console services.

## Use case

The command issued at endpoint 1 is a **trigger**; the message you care about
arrives **unsolicited** afterwards. Example — start a server and wait until it
is actually listening, in one detection:

```
PUT  …/consoles/defcn   {"cmd":"S FTPD","unsol-key":"FTPD",
                          "unsol-detect-sync":"Y","unsol-detect-timeout":"20"}
  -> {"status":"detected","msg":"FTPD054I Listening for FTP connections on port 2121"}
```

Useful for automation and for MBT-style test orchestration.

## Detection model

Count-delta over the **Master Trace Table (MTT)**:

1. At issue, the baseline = number of MTT entries whose (uppercased) text
   contains `unsol-key`, snapshotted **right after** the command is issued.
2. Detection fires when the live count grows **past** that baseline — i.e. a
   *new* occurrence appeared. This is robust against pre-existing occurrences
   and excludes the command's own solicited response.

The armed request (anchor TOD, window, baseline count, keyword) is stored in
the per-CGI `ntstore` (httpd `cgictx`), keyed by `detection-key`.

## Arming (endpoint 1)

`unsol-key` on the issue request arms detection. **async** (default) returns a
handle; **sync** (`unsol-detect-sync=Y`) blocks inline — see
[Issue Command](restconsoles-issue-command.md).

```json
{ "...cmd-response keys...",
  "detection-key": "D2E82AB1",
  "detection-url": "http://host:port/zosmf/restconsoles/consoles/<cn>/detections/D2E82AB1",
  "detection-uri": "/zosmf/restconsoles/consoles/<cn>/detections/D2E82AB1" }
```

The `detection-key` is derived from the issue STCK (microsecond-unique), so
detections armed in the same second do not collide.

## Request

Headers: Basic Auth. No body. `{detection-key}` from the arming response.

## Response — HTTP 200

```json
{ "status": "waiting" | "detected" | "expired", "msg": "<message text or \"\">" }
```

| `status`   | Meaning | `msg` |
|------------|---------|-------|
| `detected` | live count > baseline | the matching **message text** (MTT prefix stripped) |
| `expired`  | `now − anchor` > `detect-time` window, no match | `""` |
| `waiting`  | neither yet | `""` |

The window uses the TOD **high word** (~1.05 s/tick), so no 64-bit math.

## Errors

Console error body (`return-code` / `reason-code` / `reason`):

| HTTP | return-code | reason-code | Cause |
|------|-------------|-------------|-------|
| 500  | 5 | 9 | unknown / evicted `detection-key` (no armed detection found) |

Regex keywords (`unsolKeyReg=Y` at issue) are rejected at endpoint 1 with
400 / 1 / 25.

## Notes

- Sync mode polls tightly until `unsol-detect-timeout`; prefer **async** for
  long waits.
- The armed detection is subject to the store's LRU + TTL (~300 TOD-high
  ticks); after eviction the key reports `500 / 5 / 9`.
- See also [Collect](restconsoles-collect.md) (endpoint 2).
