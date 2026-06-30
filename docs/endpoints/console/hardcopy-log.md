# Get Messages from the Hardcopy Log

Retrieves console messages from the hardcopy log over a time window. Endpoint 4
of 4 of the z/OSMF Console services.

## HTTP Method
GET

## URL Path
`/zosmf/restconsoles/v1/log`

## Query Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `timeRange` | no | `nnnu` where `nnn` is 1–999 and `u` is `s`/`m`/`h`. Default `10m`. |
| `time` | no | ISO 8601 anchor (UTC), e.g. `2026-06-30T02:00:00Z`. Default: now. |
| `timestamp` | no | UNIX millisecond anchor. Overrides `time`. |
| `direction` | no | `backward` (default) or `forward`, from the anchor. Case-insensitive. |
| `hardcopy` | no | `operlog` or `syslog` (case-insensitive). On 3.8j `operlog` falls back to SYSLOG. |
| `sysName` | no | System name, max 8 chars. Only the local system is supported. |

## Response
On successful completion, this request returns HTTP status code 200 (OK):

```json
{
  "timezone": -5,
  "source": "SYSLOG",
  "items": [
    {
      "message": "$HASP395 MFCOPY   ENDED",
      "jobName": "JOB  752",
      "system": "MVSC",
      "type": "HARDCOPY",
      "time": "Tue Jun 30 02:41:36 GMT 2026",
      "timestamp": 1782787296000
    }
  ],
  "totalItems": 1,
  "nextTimestamp": 1782787181000
}
```

Items are chronological (oldest → newest). `timestamp` is UNIX milliseconds
(UTC); `time` is the same instant formatted in GMT. `nextTimestamp` is the far
edge of the window, usable as the anchor for the next page. The maximum is
10000 items.

## Error Responses
Console error body (`return-code` / `reason-code` / `reason`):

| HTTP | return-code | reason-code | Cause |
|------|-------------|-------------|-------|
| 400  | 1 | 22 | A parameter is invalid (`timeRange`, `direction`, `hardcopy`, `timestamp`) |
| 400  | 1 | 23 | The supplied `time`/`timestamp` is in the future |
| 400  | 1 | 24 | `sysName` exceeds 8 characters |
| 500  | 8 | 1  | Error retrieving the hardcopy log |

## Implementation (MVS 3.8j)
MVS 3.8j has **no OPERLOG** (no System Logger), and the **active SYSLOG on the
JES2 spool is not browsable** — its DDs report `records=0` and a spool browse
returns nothing, even after `WRITELOG`. So the source is the **Master Trace
Table (MTT)**: the in-memory tail of the hardcopy log, carrying the same
messages. Reported `source` is `SYSLOG`.

**Coverage is the MTT window** — recent history (activity-dependent: hours on a
quiet system), *not* a deep archive. Reading the real SYSLOG spool is tracked
separately (a clibjes2 limitation).

The MTT carries only `hh.mm.ss` per line, so dates are **reconstructed**: the
entries are walked newest → oldest and the date is rolled back one day at each
midnight crossing. Per-entry UNIX timestamps are synthesized from the
reconstructed date; `timezone` is derived from the local/UTC offset, and
`system` from the SMF system id.

`jobName` is the MTT source field (jobtype + JES number, e.g. `STC  328`), not
the literal job name — the MTT line does not carry the job name. `cart`,
`color`, `replyId`, `messageId` and `subType` from the z/OSMF schema are not
available from the MTT and are omitted.

**Deferred:** absolute `time`/`timestamp` anchoring is best-effort (the window
is most reliable anchored at *now*); deep archive depth needs the SYSLOG spike.

## Examples

### Using curl
```bash
# last 10 minutes (default)
curl -u USER:PASS 'http://mvs:1080/zosmf/restconsoles/v1/log'

# last 2 minutes
curl -u USER:PASS 'http://mvs:1080/zosmf/restconsoles/v1/log?timeRange=2m'
```
