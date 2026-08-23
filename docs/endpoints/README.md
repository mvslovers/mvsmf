# mvsMF REST API Endpoints

z/OSMF-compatible REST API for MVS 3.8j. All endpoints require Basic Auth unless noted otherwise.

> **Copy-paste examples** (curl & Zowe CLI) for every endpoint:
> [examples.md](../examples.md).

## Sessions — a Basic request gets a cookie back

Any request authenticated with `Authorization: Basic` is answered with

```
Set-Cookie: LtpaToken2=<token>; Path=/; HttpOnly; SameSite=Strict
```

so a client that keeps cookies is in a session from its first call and need not
resend credentials. This mirrors the reference z/OSMF, which does the same on
any Basic-authenticated request rather than only at `/zosmf/services/authenticate`.

A caller arriving **with** the cookie sends no `Authorization` header and gets
no new `Set-Cookie` — the session is not refreshed per request. Command-line
clients that ignore cookies are unaffected: they keep sending Basic and it keeps
working.

`POST /zosmf/services/authenticate` remains the explicit way in, and the only
way to get the cookie without also making an API call.

## `X-MVSMF-Client` — for browser clients only

A `401` carries `WWW-Authenticate: Basic realm="<SMF ID>"`, as the reference
z/OSMF does. **Send `X-MVSMF-Client: <name>` on every request if your client is
a browser page**, and the challenge is left off your 401s.

This exists because of one browser behaviour, measured rather than assumed
(`tests/probe-401-dialog.py`, issue #324): a `fetch` or `XMLHttpRequest` that
receives a 401 carrying the challenge makes the browser open its **native**
credential dialog and **withhold the response** until a human dismisses it —
6080 ms in the run that settled it. Your own 401 handling never runs, and the
Basic credentials the browser then caches replay on every same-origin request
and outlive a token logout.

- **Command-line and SDK clients want no part of this.** curl, Zowe, the SDKs
  and anything else that sends credentials preemptively should simply not send
  the header; they then get exactly what the reference sends.
- `Sec-Fetch-Mode`, which browsers set themselves, is honoured the same way, so
  a browser client is covered even without the header. `Sec-Fetch-Mode:
  navigate` is deliberately excluded — a typed URL should get the browser's
  prompt.
- `X-CSRF-ZOSMF-HEADER` is **not** a suppression signal, even though browser
  clients commonly send it: Zowe sends it too. Send `X-MVSMF-Client` as well.
- Note that HTTPD's own 401s (for anything outside `/zosmf/`) follow a
  different rule — they key on `X-CSRF-ZOSMF-HEADER`.

## System Information

| Method | Path | Description |
|--------|------|-------------|
| GET | [`/zosmf/info`](info.md) | System information |

## Authentication (`/zosmf/services`)

| Method | Path | Description |
|--------|------|-------------|
| POST | [`/zosmf/services/authenticate`](auth/authenticate.md) | Log in; returns `LtpaToken2` cookie |
| DELETE | [`/zosmf/services/authenticate`](auth/authenticate.md) | Log out; invalidates the token |

## Jobs (`/zosmf/restjobs/jobs`)

| Method | Path | Description |
|--------|------|-------------|
| GET | [`/zosmf/restjobs/jobs`](jobs/list.md) | List jobs |
| PUT | [`/zosmf/restjobs/jobs`](jobs/submit.md) | Submit job (inline JCL or dataset reference) |
| GET | [`/zosmf/restjobs/jobs/{name}/{id}`](jobs/status.md) | Job status |
| DELETE | [`/zosmf/restjobs/jobs/{name}/{id}`](jobs/purge.md) | Purge job |
| GET | [`/zosmf/restjobs/jobs/{name}/{id}/files`](jobs/files.md) | List spool files |
| GET | [`/zosmf/restjobs/jobs/{name}/{id}/files/{ddid}/records`](jobs/records.md) | Read spool file content |

## Datasets (`/zosmf/restfiles/ds`)

| Method | Path | Description |
|--------|------|-------------|
| GET | [`/zosmf/restfiles/ds`](datasets/list.md) | List datasets |
| GET | [`/zosmf/restfiles/ds/{name}`](datasets/get.md) | Read sequential dataset |
| PUT | [`/zosmf/restfiles/ds/{name}`](datasets/put.md) | Write sequential dataset |

Volume-specific variants: `/zosmf/restfiles/ds/-({volser})/{name}` for GET and PUT.

## PDS Members (`/zosmf/restfiles/ds`)

| Method | Path | Description |
|--------|------|-------------|
| GET | [`/zosmf/restfiles/ds/{name}/member`](datasets/members-list.md) | List PDS members |
| GET | [`/zosmf/restfiles/ds/{name}({member})`](datasets/members-get.md) | Read PDS member |
| PUT | [`/zosmf/restfiles/ds/{name}({member})`](datasets/members-put.md) | Write PDS member |

## Data set names are folded to upper case

Every data set, member and `dslevel` name on the `/zosmf/restfiles/ds` endpoints
is upper-cased before it is used, so `ibmuser.cntl`, `IBMUSER.CNTL` and
`IBMUSER.cntl` all address the same data set. Trailing blanks are trimmed.

This matches z/OSMF, which folds both the path variable and the `dslevel` query
value. It applies to the names in a `rename` control body as well.

A name longer than its limit is **refused with 400**, not truncated — 44
characters for a data set or `dslevel`, 8 for a member.

**USS paths are not folded.** `/zosmf/restfiles/fs` addresses a case-sensitive
file system, where `/tmp/Foo` and `/tmp/foo` are different files.

## USS Files (`/zosmf/restfiles/fs`)

| Method | Path | Description |
|--------|------|-------------|
| GET | [`/zosmf/restfiles/fs?path=...`](uss/list.md) | List directory |
| GET | [`/zosmf/restfiles/fs/{filepath}`](uss/get.md) | Read file |
| PUT | [`/zosmf/restfiles/fs/{filepath}`](uss/put.md) | Write file (or invoke utilities) |
| POST | [`/zosmf/restfiles/fs/{filepath}`](uss/create.md) | Create file or directory |
| DELETE | [`/zosmf/restfiles/fs/{filepath}`](uss/delete.md) | Delete file or directory |

## Console Services (`/zosmf/restconsoles`)

| Method | Path | Description |
|--------|------|-------------|
| PUT | [`/zosmf/restconsoles/consoles/{name}`](console/issue-command.md) | Issue operator command (SVC 34 → MTT) |
| GET | [`/zosmf/restconsoles/consoles/{name}/solmsgs/{key}`](console/collect.md) | Collect command response (deltas) |
| GET | [`/zosmf/restconsoles/consoles/{name}/detections/{key}`](console/detections.md) | Detect keyword in unsolicited messages |
| GET | [`/zosmf/restconsoles/v1/log`](console/hardcopy-log.md) | Get messages from the hardcopy log |

## Common Headers

| Header | Used By | Description |
|--------|---------|-------------|
| `X-IBM-Data-Type` | Dataset/member GET & PUT | `text` (default), `binary`; `record` on GET only (unimplemented on PUT, #245) |
| `X-IBM-Intrdr-Mode` | Job submit | Validated but fixed to `TEXT` |
| `X-IBM-Intrdr-Lrecl` | Job submit | Validated but fixed to `80` |
| `X-IBM-Intrdr-Recfm` | Job submit | Validated but fixed to `F` |
| `X-IBM-Max-Items` | Directory listing (datasets & USS) | Maximum items to return (0 = unlimited) |
| `X-IBM-Option` | USS delete | `recursive` for non-empty directory deletion |
