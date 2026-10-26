# Conformance with z/OSMF: status codes, the 401 challenge, the reference system

Moved verbatim from `CLAUDE.md` on 2026-10-19; `CLAUDE.md` keeps the rules every session needs and points here.

Read before choosing or changing an HTTP status, touching `send_auth_challenge()`, or measuring against the reference z/OSMF.

## HTTP status codes -- the decisions behind the closed list

The list itself and the short rules stay in `CLAUDE.md`. This is the reasoning and history.

Two codes turn on this:

- **204 belongs to the bodiless replies** — deletes, rename, the USS utilities —
  and mvsMF emits it there (`dsapi.c:2943`, `dsapi.c:2992`, `ussapi.c:1374`).
  The list also describes it for "no data sets or files match the filter
  criteria, or the specified partitioned data set has no members", but real
  z/OSMF answers **200 with an empty `items` array** in every one of those
  cases, including a partitioned data set with zero members. Empty listings stay
  200 (#266, measured, closed won't-do).
- **206 went the same way, after briefly going the other.** #249/PR#265 adopted
  it for a listing truncated by `X-IBM-Max-Items`, on the documented wording —
  and #274 took it back out: real z/OSMF answers **200 with `moreRows: true`**
  there and emits no 206 on the files service at all, not even for a
  record-range read. Truncation is carried in `moreRows` and nowhere else, so
  **mvsMF emits no 206 anywhere**. Do not cite #249; it was measured wrong.

  The removal also deleted work rather than only adjusting it: the status was
  the sole reason `memberListHandler` and `ussListHandler` measured the page
  before the header went out, so both second walks went with it. What is left
  of that shape is load-bearing — `member_scan()` walks one match *past* the
  page and emits only up to it, because a walk bounded at the page returns the
  limit whether or not anything follows, and a directory holding exactly as
  many members as the limit would then report `moreRows: true`. That failure is
  silent and its test is the equal-to-the-count case in `curl-datasets.sh`.

Two further consequences that keep getting rediscovered:

- **409 Conflict, 414 URI Too Long and 507 Insufficient Storage are not in the
  list.** httpd gained all three in httpd#28/PR#56, and a live probe confirms a
  CGI-set 414 reaches the client unchanged — but adopting them is still wrong.
  "Already exists" / "not empty" stay **400**, "no space" / "no inodes" stay
  **500**. This was tracked as #102 and closed as won't-do; do not re-open the
  reasoning from the httpd side alone.
- **There are no sanctioned exceptions, and two were tried.** 410 Gone for
  purged spool output (#187) and 403 for a read-only file system both went in as
  "a case z/OSMF has no code for", and both came back out in #250. The reason to
  know this is the argument that produced them, because it is a good one and it
  will come again: mvsMF can detect states the reference cannot, so no reference
  behaviour exists to copy. What settled it is that the reference stays inside
  its own list even where a better code exists — a missing job answers **400**,
  not 404, measured. A distinction worth keeping goes in the error report's
  `reason` and `message`, where it costs no conformance; `REASON_SPOOL_GONE` is
  the worked example.
- **206, 412 and 429 reach the wire now — but only because httpd was re-cut and
  redeployed** (206 is emittable, and unused since #274; the entry is about what
  httpd can send, not about what mvsMF sends). They were added to
  `src/httpstat.c` by httpd#181/PR#183 (commit
  `623f6a6`), which landed *after* the original `v4.0.0-dev` artifact; that tag
  has since been re-cut and the STC redeployed, and 412 was measured going out
  correctly (#152). The mechanism is the part to remember: `http_resp()`
  resolves through the httpx vector into the **running** httpd, so the live
  server's build decides, not the staged `.a` — `mbt deps` alone can never
  change which statuses are emittable, because `libhttpd.a` carries no status
  table at all. An absent code is answered 500, and no longer silently: an
  unknown one WTOs `HTTPD054E`, which is how a 505 going out as 500 was finally
  noticed. **Check `httpstat()` in the httpd you are actually running** before
  sending a status this codebase does not already use. The cheap probe is
  `printf 'GET / HTTP/9.9\r\n\r\n' | nc <host> <port>` — the same commit fixed
  httpd's own 505, so a `505` reply proves the build is current and a `500`
  proves it is not.


### A known path, a method nobody registered: 405 (#418)

Until #418 the router answered 404 for any request it found no route for, so
`DELETE /zosmf/info` looked the same as a typo in the path. The reference tells
them apart. Measured on `zxp` on 2026-10-23 (read-only probes, the exact status
line through the SDK):

| Request | Reference answer |
|---|---|
| `DELETE /zosmf/info` | **405** `Http method DELETE is not supported by this URL`, no `Allow` header |
| unknown path | 404 `SRVE0190E: File not found` |
| `PATCH /zosmf/info`, `PATCH /zosmf/restfiles/fs` | 403 `AuthorizationFailed` |
| `PATCH /zosmf/restjobs/jobs` | 501 |

Decision: a path that some route serves, requested with a method none is
registered for, answers **405** with the usual error report (`category` 6,
`rc` 4, `reason` 7, `message` `Http method <METHOD> is not supported by this
URL`) and **no `Allow` header** -- the reference sends none, and 405 is in the
closed list. A path no route matches stays 404. The check is in
`handle_request()` (`src/router.c`), after the middleware chain, so a request
without a credential is still a 401, except on `/zosmf/services/authenticate`,
which `identity_middleware` (`src/mvsmf.c`) lets through to its handler;
`find_route()` is unchanged and
`path_is_known()` asks only whether any pattern matches, regardless of method.

Not covered, on purpose: methods `parseMethod()` does not know. `PATCH` and
`OPTIONS` never reach mvsMF: httpd answers them itself with a text/plain 405
(`http_parse()`). `HEAD` reaches `handle_request()`, which answers a bare 405
before the middleware chain. The reference answers PATCH with 403 or 501
depending on the service, which is a different question and not part of #418.


### Purge of a job whose output a device holds (#426)

`jescanj(name, id, 1)` returns `CANJ_OK` when JES2 has *taken* the purge, which
for a job with output a device has selected (`$DJ` shows `ON PUNCH1 ... PURGE`)
means "marked": the job stays on the queue until the device releases the output
(`$C PUNCH1`). Until #426 the handler answered `200 Request was successful.` on
that, and a client read it as free spool.

The answer is still **200 with `status: 0`**. The reference answers an
asynchronous purge (`X-IBM-Job-Modify-Version` 1.0, the default) with 200 and
`status: 0` whatever happens to the job afterwards, so a 200 is conformant for
"requested", and the closed list has no 202. What changed is the `message`:
`job_still_queued()` re-reads the job after `CANJ_OK` (up to five looks, 0.2 s
apart; `jesjob()` reads the checkpoint, which trails JES2) and, when it is still
listed, the text says the purge is only requested.

Not measured: what zxp answers for a purge of such a job. That is a write on a
real system and was not asked for; the reasoning above rests on the documented
asynchronous answer. A synchronous mode (`X-IBM-Job-Modify-Version: 2.0`) is not
implemented.

### The 401 challenge — the one deviation, and why it is not negotiable

Every 401 carries `WWW-Authenticate: Basic realm="<SMF ID>"`, **except** when the
request came from a browser `fetch`/XHR. `send_auth_challenge()` (`common.c`)
owns the rule; `is_browser_fetch()` next to it owns the exception.

The reference sends the challenge on every endpoint — measured, and *not*
dropped for a client identifying itself with `X-CSRF-ZOSMF-HEADER`, so there is
no API-client exemption to copy. RFC 9110 §11.6.1 requires it too.

The exception is not cosmetic and not a guess. Measured with
`tests/probe-401-dialog.py`: a same-origin `fetch` or XHR that receives a 401
carrying this header makes the browser open its native credential dialog **and
withhold the response until a human dismisses it** — 6080 ms and 4805 ms in the
run that settled it. The Desktop's own `mvsmf:session-expired` handling never
runs, and once the dialog is satisfied the browser caches those Basic
credentials and replays them on every same-origin request, outliving the token
logout that #161 exists to make meaningful. Re-run the probe before doubting
this; it needs no MVS.

Three things that look like tidying and are not:

- **`X-CSRF-ZOSMF-HEADER` is deliberately not a suppression signal**, even
  though the Desktop sends it. Zowe and the SDKs send it too, and they must keep
  getting exactly what the reference sends. httpd suppresses on it
  (`httppc.c`, httpd#119/#120) — the two layers differ on purpose.
- **`Sec-Fetch-Mode: navigate` still gets the challenge.** That is somebody
  typing the URL, where the browser's own prompt is the useful answer.
- **The realm is the SMF ID, not a constant.** A browser caches Basic
  credentials under (origin, realm), and httpd answers on the same origin with
  the realm it derives in `httprlm()` (httpd#191). A different string there is a
  second protection space and a second dialog; a constant is what httpd#191
  removed, because it made every system on the network share one. The logic is
  duplicated in `auth_realm()` because `httprlm()` lives in the server binary
  and the CGI-side `httpd.a` carries only the `cgistart` stub.

## Checking behaviour against a real z/OSMF (`zxp`) -- technique and findings

The read-only rule stays in `CLAUDE.md`.

Zowe CLI does not print the HTTP status on success and the profile is HTTPS, so
`tests/trace-zowe.sh` cannot see inside it. To read the exact status line, load
the profile through the SDK and use `client.response.statusCode`:
`ProfileInfo.readProfilesFromDisk()` → `mergeArgsForProfile(attrs,
{getSecureVals: true})` → `ProfileInfo.createSession()` pulls the credentials
from the OS credential store without ever printing them.

Two things met on the way: a member `pattern=` longer than 8 characters is
rejected `400 {"category":1,"rc":4,"reason":13,"message":"pattern"}` — that is
the member-name limit, not an empty result. And z/OSMF emits `moreRows` **only
when true** — mvsMF followed suit in #279, on all three listings and the USS
stat reply, so a complete listing now carries no `moreRows` key at all.

`totalRows` is the piece still missing, and it is narrower than it looks: the
reference emits it on the **file** list (`totalRows: 39` for `/`), and on a
complete data set or member list it emits neither `totalRows` nor `moreRows` —
measured, keys `["JSONversion","items","returnedRows"]`. mvsMF matches that
today by accident rather than by decision; the open TODOs sit at `dsapi.c:1284`
and `dsapi.c:2145` and are about `X-IBM-Attributes` `,total`.

### A data set addressed with `-(VOLSER)` (#336)

Measured read-only against the reference z/OSMF: GET only, the calls that
`zowe files view ds --volume-serial` and the member list send. Nothing was
created or written. The data set was cataloged on volume A; volume B exists;
volume C does not.

| Request | Status | category / rc / reason | message |
|---|---|---|---|
| read a member, cataloged on A, path names B | 500 | 4 / 8 / 0 | `LMINIT error`; ISRZ002 "not on volume" |
| member list, same case | 404 | 4 / 8 / 0 | same text |
| read a member, path names C (no such volume) | 500 | 6 / 8 / 75760138 | `Dynamic allocation failed`; IKJ56883I |
| member list, path names C | 500 | 4 / 8 / 0 | ISRZ002 "Volume not available" |
| name that exists nowhere, with or without a volume | 404 | 6 / 8 / 386400778 | `Data set not found.`; IKJ56228I |
| member list of that name, with a volume | 404 | 4 / 8 / 0 | ISRZ002 "not cataloged" |
| path names A, the right volume | 200 | | identical to the form without a volume |

What mvsMF does with it: the reference is not uniform for "not on this volume"
(500 on a read, 404 on a member list), so mvsMF takes the 404, which is in the
closed list, agrees with the member list, and is not a server fault: 404,
category 6, rc 8, reason 13, in `volume_gate()` and `dsapi_err.h`. A volume
that does not exist is the same case. A name that is not cataloged gets exactly
the answer of the route without a volume, as the reference does. The reference's
category and reason numbers are ISPF library-management codes that mvsMF does
not have, so they are not copied.

Not measured: a data set that is on a volume but not in the catalog (it could
not be created read-only), and a hyphen in the volume serial.

`volume_gate()` reads `HTTP_volume-serial` with `http_get_env()`, and httpd's
env lookup is case-insensitive. A request header `Volume-Serial: X` therefore
switches the gate on for the cataloged routes too (only stricter, never looser;
on the `-(VOL)` routes the path wins). This holds until the router can tell
path variables from headers.
