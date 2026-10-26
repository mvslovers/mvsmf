# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

mvsMF is a z/OSMF REST API implementation for MVS 3.8j, built as a CGI module for Mike Rayborn's HTTPD server. It enables modern clients (Zowe Explorer, Zowe CLI, JetBrains IDEs) to interact with classic MVS systems via standard z/OSMF REST endpoints.

## C standard and platform

mvsMF compiles as **gnu99**, mbt 3's default, so `mbt.toml` does not spell it
out (under mbt 2 it was gnu89; the switch in #396 changed code generation in
four objects, not their external symbols). Prefer top-of-block declarations for
readability. Every platform constraint of the root `CLAUDE.md` applies, with
one override: the codepage, below.

## Codepage Override (CRITICAL)

**There is no single project codepage.** The root CLAUDE.md states a blanket
"the runtime is EBCDIC (CP037)"; for mvsMF that is true only of datasets and
jobs. **USS/UFS payloads are IBM-1047.** This section overrides the root rule
for mvsMF.

The failure mode is silent: CP037 and IBM-1047 disagree on `[ ] ^ ! ¬` and
friends. Translating a USS payload with CP037 compiles, runs, returns 200, and
corrupts exactly those bytes. Nothing surfaces the mistake — pick the table
deliberately.

| API surface | Codepage | Table |
|---|---|---|
| USS / UFS files (`ussapi.c`) | **IBM-1047**, or CP037 by request | `uss_data_type()` -- `xlate_1047` unless `X-IBM-Data-Type: text;fileEncoding=IBM-037` (#393) |
| Datasets (`dsapi.c`) | **CP037**, or IBM-1047 by request | `ds_codepage()` -- `xlate_cp037` unless `X-IBM-Data-Type: text;fileEncoding=IBM-1047` (#391) |
| Jobs (`jobsapi.c`) | **CP037** | `httpx->xlate_cp037` |
| HTTPD server default | **CP037** | `http_xlate_init()` fallback |

So the rule is: **payload bytes are yours to translate, formatted output is
httpd's** -- `http_printf()` translates, `send_all()` does not. Where the
tables live, who translates what, and how a codepage is changed (an httpd-side
change): `internals/codepage.md`.

## Read when relevant

| Before you … | read |
|---|---|
| translate a payload, or change a codepage | `internals/codepage.md` |
| work on `ussapi.c` or an issue labelled `uss-phase1` | `internals/uss-spec.md` (the design), `internals/uss-handlers.md` (patterns, error mapping) |
| work on `consapi.c` | `internals/console.md` |
| touch `etag.c` or an `If-Match` / `If-None-Match` path | `internals/etag.md` |
| change who may do what (data sets, jobs, the listing) | `internals/authorization.md` |
| pick or change an HTTP status, touch the 401 challenge, measure on `zxp` | `internals/zosmf-conformance.md` |
| touch `send_all()`, `sendall.c` or `abort_response()` | `internals/sending.md` |
| use or extend `/zosmf/test` (`fn=textsum`, `fn=storage`, a new `fn=`) | `internals/test-endpoint.md`, `internals/storage-probe.md` |
| cut a release or touch `[smp]` | `~/repos/mvs/.workspace/context/smp.md` (mvsMF's FMID row is there) |
| debug the running HTTPD/mvsMF live | `~/repos/mvs/.workspace/context/httpd-debug.md` |

## Development Workflow

1. Every bug fix or feature requires a **GitHub Issue**. If none exists, create one first.
2. Develop each fix/feature on a **feature branch**.
3. When done, merge via **Pull Request** and close the issue with a short comment.

`/fix-issue <number>` and `/sync-docs` are defined in `.claude/commands/`.

## Build System (mbt 3)

mvsMF uses [mbt](https://github.com/mvslovers/mbt) **3** as its build tool:
`mbt` on the `PATH`, the project in `mbt.toml`, no submodule and no Makefile
(#396). `[toolchain] mbt = "3.0"` pins the release line.

### Build Commands

The whole build runs **on the host** with the cc370 toolchain (`cc370` → `.o`, `as370`, `ar370`, `ld370`). MVS is only touched by `mbt deploy` and `mbt test --mvs`.

```bash
mbt doctor         # verify the toolchain + MVS connectivity
mbt deps           # resolve + stage dependencies and plugins into .mbt/
mbt build          # cross-compile + link the MVSMF load module (host only)
mbt test           # run the host unit tests (test/host)
mbt test --mvs     # deploy + run the test suite on MVS
mbt deploy         # pack -> XMIT -> RECEIVE -> IEBCOPY into MVSMF.DEV.LINKLIB
mbt run restart -- HTTPD   # compress MVSMF.DEV.LINKLIB + restart HTTPD (mbt-stc)
mbt compiledb      # generate compile_commands.json for clangd
mbt clean          # remove build/ and dist/
mbt distclean      # clean + remove all of .mbt/ (incl. staged deps)
```

The build id `?fn=version` reports is `MBT_COMMIT` from mbt's generated
`<buildstamp.h>`: the short HEAD, with `-dirty` when a tracked file differed
from it at build time. `/zosmf/test` exists only in a development build (a
version ending in `-dev`, #508); a release deploy is checked with
`GET /zosmf/info`, field `zosmf_full_version`.

The Desktop is uploaded with `mbt run deploy-desktop` (`mbt/init.lua`, which
calls `tools/deploy-desktop.sh`).

### Deploy and Activation

`mbt deploy` RECEIVEs the load module into a staging library and replaces the
`MVSMF` member of **`MVSMF.DEV.LINKLIB`** (mbt's default `<NAME>.DEV.LINKLIB`)
with IEBCOPY, `DISP=SHR`. It never deletes the library, so it works while HTTPD
holds it in its STEPLIB. `--dry-run` packs and reports without logging on.

Activate with **`mbt run restart -- HTTPD`** (plugin `mvslovers/mbt-stc`): it
compresses the library -- every replaced member leaves its old space dead,
and mbt refuses a deploy that would not fit -- and restarts HTTPD. Then check:

```
GET /zosmf/test?fn=version        # "build" must equal the HEAD you built (dev builds)
GET /zosmf/info                   # zosmf_full_version, the only check on a release
```

On mvsdev a deploy or an MVS test run needs a slot from the MBT session.

**Confirm the STEPLIB from the running STC, never from the data set list** —
several `HTTPD.LINKLIB*` data sets exist on a given stand and only one is in
use. Find the ACTIVE `STC` via `GET /zosmf/restjobs/jobs?owner=*&prefix=HTTPD*`
(a started task is a job of another owner: the caller needs READ on it in the
class JESSPOOL, `docs/jesspool.md`, or the list is empty),
then read its JESJCL (file id 3) for `XXSTEPLIB DD DISP=SHR,DSN=…`.

### Dependencies

Declared in `mbt.toml`: crypto370, httpd and ufsd, plus the plugin
`mvslovers/mbt-stc`. To build against an unreleased dependency, use a
gitignored `.mbt/deps.local.toml` `[override]`.

### Configuration

mbt reaches MVS through a target in `~/.mbt/targets.toml` (per machine;
`mbt target import .env --name <name>` converts an old `.env`). Nothing reads
`.env` any more (#400): the REST suites and the Desktop deploy run through mbt
(`mbt run rest-tests`, `mbt run deploy-desktop`, `mbt/init.lua`) and take the
connection from that target. The authorization tests need a second, ordinary
userid, a further user of the target:

```toml
[target.<name>.mvsmf.users.test2]
user     = "..."
password = { keychain = "..." }
```

clangd provides IDE diagnostics (configured in `.clangd`).

## Architecture

### Request Processing Pipeline

```
HTTP Request → cgistart (@@START, autocalled from httpd's libhttpd.a) → mvsmf.c (router setup)
  → router.c (URL decode, method parse, route match, path var extraction)
    → Middleware chain (identity_middleware in mvsmf.c; logmw.c present but disabled)
      → API handler (dsapi.c, jobsapi.c, ussapi.c, consapi.c, authapi.c, infoapi.c)
        → JSON response (json.c)
```

### Key Source Files

- **mvsmf.c**: Entry point. Registers all routes and middleware, initializes the router and HTTPD session. `identity_middleware` reads the client identity httpd already resolved (Basic/token) via the HTTPX auth export (`http_get_acee`) and sets the task ACEE — no per-request RACF login.
- **router.c**: HTTP routing framework. Pattern-based URL matching with `{param-name}` path parameters, percent-decoding, middleware chain execution.
- **dsapi.c**: Dataset REST API handlers — list, read, write, create, delete for sequential datasets and PDS members. Largest file by complexity.
- **etag.c**: The ETag stamp and `If-Match` / `If-None-Match` handling for data
  sets, members and USS files (#152, #263, #264, #271). Three rules there fail
  silently if broken -- read `internals/etag.md` before touching it.
- **jobsapi.c**: Jobs REST API handlers — submit JCL, list/status/purge jobs, read spool files. Uses JES2 interfaces. Every job that is shown or purged goes through `jobauth.c` / `jwn.c` (class JESSPOOL, #440; `internals/authorization.md`).
- **ussapi.c**: USS file REST API handlers — list, read, write, create, delete for UNIX files/directories via libufs/UFSD. Includes chtag utility stub.
- **consapi.c**: Console services handlers — issue command (SVC 34/MGCR), collect response, detect unsolicited keyword, hardcopy log. Reads console data from the Master Trace Table (libc370 `clibmtt`).
- **ntstore.c**: Small persistent key/value store (LRU + TTL) used by the console cursors/detections; lives in the httpd per-CGI context.
- **mvsmfctx.c**: Wires the per-CGI context (`MVSMF_CTX`) to httpd's `http_cgictx_get`, lazy-initialising the kv-store.
- **authapi.c**: `/zosmf/services/authenticate` token login (`authLoginHandler`, `AAPI0001`) and logout (`authLogoutHandler`, `AAPI0002`). The one route `identity_middleware` lets through without a resolved credential — a failed login has no ACEE and still has to reach the handler to get the z/OSMF-shaped 401 body. The login turns the resolved credential into a session of its own with `http_new_session()` before reading the token (httpd#288): httpd finds that credential by address, userid and password, so without it every client logging on the same way shared one token and one logout ended them all. That makes httpd 4.2.0's vector entry `0x144` a hard requirement -- there is no run-time test for it (#363). Documented in `docs/endpoints/auth/`.
- **infoapi.c**: `/zosmf/info` endpoint. Authenticated like every other route — the "unauthenticated liveness probe" it was documented as until #324 never existed: `identity_middleware` exempts only `/zosmf/services/authenticate`, and the reference z/OSMF gates its own `/zosmf/info` too (measured — 401 with `WWW-Authenticate: Basic`, on every endpoint, even for a client sending `X-CSRF-ZOSMF-HEADER`). The 401 is the conformant answer; do not add an exemption for it.
- **json.c**: JSON response builder with dynamic buffer management (`addJsonString`/`Esc`/`Number`/`Raw`, keyed arrays).
- **common.c**: Shared utilities for parameter extraction, HTTP responses, and z/OSMF-compatible error formatting.
- **abendmsg.c**: What a handler abend tells the client and the console, as pure functions (RENT-safe: the caller supplies the buffer). `abend_message()` builds the 500 body text with the abend code and names SB37/SD37/SE37 (#256); `abend_denial_detail()` returns the `details[]` sentence for S913 only, an authorization denial (#315) -- S213 must not fall in. Both are called from the abend recovery in `router.c`, as are `abend_instr_addr()`, `abend_ep_offset()` and `abend_in_range()` for the MVSMF913I/914I console messages (#425); `abend_in_range()` also gates `fn=textsum` / `fn=textdump` in `testapi.c`. Host test: `test/host/tstabnd.c`.
- **hostparse.c**: Splits a `Host` header value into a host name and a port (`parse_host_name()`, `parse_port_string()`) and checks a port (`validate_port()`: digits only, 1..65535). Used by `infoapi.c` for `zosmf_hostname` / `zosmf_port` of `/zosmf/info` (#175, #260) and for its `X-Forwarded-Port` fallback; a non-zero return means the caller must fall back to its default. An IPv6 literal is not handled (see `hostparse.h`). Host test: `test/host/tsthost.c`.
- **jclines.c**: `grow_lines_arrays()` grows the JCL line table (a buffer of 81-byte slots plus the pointer array over it) for the submit paths in `jobsapi.c` (`submit_file()`, `submit_jcl_content()`). The order of its two reallocs is the fix for #220: on failure the caller's table is still valid at its old capacity. Host test: `test/host/tstjcln.c`, with a fault-injecting `realloc`.
- **reclines.c**: The byte-stream-to-record state machine of the text PUT paths in `dsapi.c` (`datasetPutHandler()` and `memberPutHandler()`, each for Content-Length and chunked): `recline_init()`, `recline_put()`, `recline_flush()`. LF, CR and CRLF end a record, a blank line becomes one blank record (#233), an overlong line is truncated and flagged instead of failing (#243), and the state survives a chunk boundary. It works on ASCII bytes, before `write_record()` translates. Host test: `test/host/tstrecl.c`.
- **spoolln.c**: `spool_line_action()`, the per-record decision of the spool walk in `jobsapi.c` (`do_print_sysout_line()`): stop at the record-count cap (#158), and in JESJCLIN skip records that are not card images (JES2's pointer record behind every in-stream `DD *`, #314). A skipped record must not count toward the cap. Host test: `test/host/tstspln.c`.
- *(No `xlate.c`)* — the EBCDIC/ASCII tables live in libhttpd and are reached via `httpx->xlate_*`. See **Codepage Override**.
- **testapi.c**: Internal `/zosmf/test` endpoint for exercising libc370 functions in isolation (`fn=version`, `fn=mtt`, `fn=cmd`, catalog/DSCB probes, …). The CGI launcher (`cgistart`, providing `@@START`) is autocalled from httpd's `libhttpd.a`; this repo carries no launcher of its own.

### REST API Structure

All endpoints are under `/zosmf/`:

- `/zosmf/info` — system info (authenticated, like the reference — see #324)
- `/zosmf/restfiles/ds/...` — dataset + PDS member operations
- `/zosmf/restjobs/jobs/...` — job operations
- `/zosmf/restfiles/fs/...` — USS file operations
- `/zosmf/restconsoles/...` — console services (issue, collect, detections, hardcopy log)
- `/zosmf/services/authenticate` — token login (POST) and logout (DELETE)

Endpoint documentation lives in `docs/endpoints/` (with a curl & Zowe cookbook in `docs/examples.md`).

### HTTP Status Codes — the z/OSMF contract is a closed list

z/OSMF's "Error handling" section does not merely say "4nn/5nn means error"; it
**enumerates the valid status codes**. mvsMF is a clone, so that list is the
constraint — a status outside it is a deviation even when it is the semantically
nicer answer, and even when httpd happily puts it on the wire.

```
200 OK              204 No content      206 Partial content   304 Not Modified
400 Bad request     401 Unauthorized    404 Not found         405 Method not allowed
412 Precondition failed                 413 Request entity too large
429 Too many requests                   500 Internal server error
503 Service unavailable
```

**The list bounds which codes are permitted; it does not mandate one per
condition.** Where the documented example and the reference implementation
disagree, follow the implementation — that is what clients are written against,
and it can now be measured (see **Checking behaviour against a real z/OSMF**).

- Empty listings stay **200** with an empty `items` array (#266), and mvsMF
  emits **no 206 anywhere**: truncation is carried in `moreRows` (#274).
- **409, 414 and 507 are not in the list**: "already exists" / "not empty" are
  400, "no space" / "no inodes" 500 (#102).
- **There are no sanctioned exceptions** (#250): a distinction worth keeping
  goes into the error report's `reason` and `message`.
- **Check `httpstat()` in the httpd you are actually running** before sending a
  status this codebase does not already use.

Reasoning and history: `internals/zosmf-conformance.md`.

`sendErrorResponse()` (`common.c`) does not branch on status — it builds the
JSON error report and hands the code to `sendJSONResponse()` — so a wrong code
here fails silently, on the wire only.

### The 401 challenge — the one deviation, and why it is not negotiable

Every 401 carries `WWW-Authenticate: Basic realm="<SMF ID>"`, **except** when the
request came from a browser `fetch`/XHR. `send_auth_challenge()` (`common.c`)
owns the rule; `is_browser_fetch()` next to it owns the exception.

The reference sends it on every endpoint; the browser exception is measured
(`tests/probe-401-dialog.py`), and three things near it look like tidying and
are not. Read `internals/zosmf-conformance.md` before changing either.

### Checking behaviour against a real z/OSMF (`zxp`) — READ-ONLY

**This is a real IBM system. We treat it with respect.** Appending
`--zosmf-p zxp` to any Zowe CLI call reaches a live IBM z/OSMF (version 29 /
z/OS 05.29.00) — the very thing mvsMF clones. It turns conformance arguments
into measurements: #266 and #274 were both settled on it in an afternoon after
weeks of reading the spec.

**The rule is read-only.** `list`, `view`, `download` — nothing else, and only
as much of it as the question needs. Do not sweep the catalog, do not poll, do
not leave anything behind.

**Anything that writes must be explained and asked for, every single time.**
Create, upload, write, rename, delete, submit — no exception, no "just a small
test data set", and no carrying a permission over from a previous question. Say
exactly what will be created, where, and how it gets cleaned up; then wait for
an answer. A permission granted for one probe covers that probe only.

How to read the exact status line through the Zowe SDK, and what was found
there: `internals/zosmf-conformance.md`.

### Operator Messages (WTO) — the catalog is closed

Every `wtof()` literal lives in **`include/mvsmfmsg.h`**, exactly once, and is
documented for operators in **`docs/messages.md`**. Never write an inline
literal — that is what let one id (`MVSMF22E`) accumulate 25 different texts
before #201.

Three rules, in the order they get broken:

- **A WTO is for what an operator can act on or must know.** Everything the
  client caused — missing parameter, unknown route, data set not found,
  malformed job card, unparseable `Host` — is reported in the HTTP response and
  **nowhere else**. This is not tidiness: `consapi.c` reads the Master Trace
  Table, so every line mvsMF writes comes back out of
  `/zosmf/restconsoles/.../solmsgs` and the hardcopy log. A client polling a 404
  turns one message into a flood of its own console API.
- **One text per id.** Two wordings need two ids; a varying detail becomes an
  argument (`MSG_STORAGE_FAILED` takes the allocation name, it is not four ids).
  Ranges: `0xx` router/core, `1xx` data sets, `2xx` jobs, `3xx` USS, `4xx`
  consoles, `9xx` recovery.
- **Literals uppercase, substituted values untouched.** MVS names are uppercase
  already; USS paths and free user text must not be folded. Watch the
  conversion specifiers — `%s` is not `%S`.

Severity is `I`, `W` or `E`. There is no debug/trace level and no `getenv()`
gate for one: the natural implementation caches the level in a `static`, which
is the RENT S0C4 trap. If a gate is ever needed it belongs in `MVSMF_CTX`
(`mvsmfctx.c`), never in a static.

### Keeping Docs and Tests in Sync

Whenever working on an endpoint handler (in `dsapi.c`, `jobsapi.c`, `ussapi.c`, `consapi.c`, or `infoapi.c`):

- **Review and update the endpoint documentation** in `docs/endpoints/` to match the current behavior.
- **Review and update the integration tests** in `tests/` to cover the current behavior.

### Integration Tests

Test suites live in `tests/` and `mbt/lua/`, and run through mbt:

```bash
mbt run rest-tests                        # everything but curl-diag, curl-nospace, curl-jesspool, curl-quiesce and curl-consgate
mbt run rest-tests -- curl-jobs zowe      # one suite, a group (lua, curl, zowe, all)
mbt run rest-tests -- curl-jobs --setup   # arguments after the names go to each suite
```

- **curl tests**: `curl-datasets.sh`, `curl-jobs.sh`, `curl-binary.sh`, `curl-uss.sh`, `curl-console.sh`, `curl-info.sh`, `curl-dslist-parallel.sh` (400 list requests, 4 at a time; `DSLIST_REQUESTS` and `DSLIST_PARALLEL` change that, #436); `curl-diag.sh`, `curl-nospace.sh`, `curl-jesspool.sh`, `curl-quiesce.sh` and `curl-consgate.sh` by name only (`curl-consgate` rewrites `SYS1.SECURE.CNTL(PROFILES)` like `curl-jesspool` and needs `MVSMF_CONSGATE_WRITE_PROFILES=yes`; `curl-quiesce` stops HTTPD with `P HTTPD`, so it is for a throwaway container and the last thing it does; `curl-jesspool` rewrites `SYS1.SECURE.CNTL(PROFILES)`: it needs a throwaway system, a RAKF administrator, the second userid, and does nothing unless `MVSMF_JESSPOOL_WRITE_PROFILES=yes` is set)
- **Zowe CLI tests**: `zowe-datasets.sh`, `zowe-jobs.sh`, `zowe-binary.sh`, `zowe-uss.sh`, `zowe-console.sh`
- **Load run**: `load-452.sh`, by name only -- the combined stability run of #452 (member reads, job status polls, large PUTs, concurrent listings), for a local throwaway container; its header lists the knobs
- **Measurement run**: `poll-425.sh` (by name only) -- status polls on a running read-only job from several clients, with `fn=textsum` sampling, `fn=storage` before/after and a console check, for #425. Not part of `all`; it needs a restartable HTTPD.
- **Soak, by name only**: `reads-372.sh` sends `READS` (default 50000) strictly sequential member GETs and samples `fn=storage` every `EVERY` reads (`internals/storage-probe.md`); run it in a throwaway container: `READS=50000 mbt run rest-tests --target env -- reads-372`. It writes `storage.csv` and `summary.txt` (bytes lost per read) to `OUT`
- **Lua (in mbt)**: `auth` (the authentication service) and `info-cookie` (the cookie on a Basic response), in `mbt/lua/restauth.lua`; `auth-refused` by name only (#520: adds the RAKF user `AUTH520`, changes its password and reloads `RAKFUSER` to get a login that RACF refuses; throwaway container, main user in `RAKFADM`; does nothing, and says so, unless `MVSMF_AUTH_REFUSED_WRITE_USER=yes` is set, #530)
- **`tests/lib/conn.sh`**: what every shell suite sources instead of `.env`

**No suite sees a password, and no shell suite may log off.** mbt hands over
the target's URL and user and its session token (`MVSMF_TOKEN`); curl sends it
with `-K "$MVSMF_CURLRC"`, Zowe through the environment. Every suite of a run
shares that one session, so a `DELETE /zosmf/services/authenticate` with it
ends the run for every suite after. A test that needs a password -- a Basic
logon, a wrong password, a logout, two logins -- goes into `mbt/lua/`, where
`ctx.mvs.request{ auth = ... }` and `ctx.mvs.session{}` send the credentials
and Lua sees only the answers (mbt's ML02-0002, "The Table ctx").

Zowe runs from a home of its own outside the home directory (`conn.sh`): it
merges every `zowe.config.json` from its working directory upwards, a
`~/zowe.config.json` included, and a layer with a user and password wins over
the token without a word -- the request goes out with Basic auth.

Both curl and Zowe suites should cover every endpoint with all relevant variations (query parameters, headers, error cases). When touching a handler, verify the corresponding tests are complete and up to date.

### HTTP Trace Proxy

`tests/trace-zowe.sh` is a reusable TCP proxy for debugging HTTP traffic between any client and mvsMF. It captures all requests and responses with full headers and bodies.

```bash
# Interactive mode — starts proxy, run commands yourself, Ctrl+C to stop
./tests/trace-zowe.sh --proxy

# Command mode — run a specific command through the proxy, show trace
./tests/trace-zowe.sh --proxy "zowe files list ds 'MIG.ZOWE'"
./tests/trace-zowe.sh --proxy "curl -s -u U:P http://localhost:1081/zosmf/restfiles/ds/MY.DS"
```

### Test Endpoint

`/zosmf/test` (`src/testapi.c`) is an internal endpoint for testing libc370 functions in isolation. Useful for verifying catalog lookups, DSCB reads, the Master Trace Table, the deployed build id (`fn=version`), and other low-level MVS operations directly via curl.

```bash
curl -u U:P 'http://host:port/zosmf/test?fn=listds&level=SYS1&filter=SYS1.MAC*'
curl -u U:P 'http://host:port/zosmf/test?fn=locate&dsn=SYS1.MACLIB'
```

`fn=storage` is the free-storage sample behind #287 — largest contiguous block
in a subpool, and with `&total=1` the total and the block-size distribution.
The threshold it exists to watch is **262144**, the unconditional GETMAIN
libc370's C startup makes on every LINK: once the largest block is below that,
the next request S80As before mvsMF's ESTAE exists. `&total=1` briefly holds
*all* free storage, so it must be sampled between load runs, never during one.
See [internals/storage-probe.md](internals/storage-probe.md).

Every request needs READ on `FACILITY MVSMF.CONSOLE` (`console_authorize()` as the first statement of `testHandler` and `testWildcardHandler`, fail-closed, #460), so the user who checks the build id needs it too. The endpoint has **no per-function gate and must not grow one back** (#343);
building with `-DMVSMF_NO_TEST_ENDPOINT` leaves `/zosmf/test` unregistered, and
so does any version that does not end in `-dev` (#508): a release answers 404.
No function of it returns session data. Suites that need a probe ask
`mvsmf_dev_build` (`tests/lib/conn.sh`) and skip on a release.
`fn=textsum` / `fn=textdump` and the gate history: `internals/test-endpoint.md`.

### Known Platform Bugs

The MVS 3.8j TCP/IP stack has a ring buffer bug that corrupts data when a multi-byte `recv()` call spans the internal buffer wrap-around point. Corrupted reads return replayed data from earlier in the stream. Single-byte `recv()` calls are not affected because they never cross the boundary.

The `receive_raw_data()` function in `jobsapi.c` works around this by reading one byte at a time from the socket (same approach as the HTTPD's `http_getc`). **Do not change `receive_raw_data()` to use larger recv sizes** — any multi-byte recv will reintroduce data corruption for large request bodies (see PR #22 and Issue #42).

### Sending — `send_all()` is the only way out

**Never call `http_send()` directly.** Every raw send goes through
`send_all()` (`common.c`), which wraps the loop in `src/sendall.c`.

`http_send()` returns **0** for "socket send buffer full, no progress, retry"
— on a non-chunked response httpd's `send_raw()` reports the bytes it managed
this call, and `EWOULDBLOCK` means none. A loop written `for (pos = 0; pos <
len; pos += rc)` that only tests `rc < 0` therefore never terminates: `pos +=
0`, a `send()` SVC per turn, one worker pinned at 100% CPU until the STC is
restarted. That was #298, and it is byte-for-byte httpd#199 one level up. A
single *unchecked* call is the other half: it silently drops whatever it did
not send.

The policy is agreed across the ecosystem and must not be re-invented per
project: on a non-blocking socket **the application waits — 100 attempts of
100 ms = 10 s without progress, then abandon** (httpd's `SEND_STALL_MAX` /
`SEND_STALL_PAUSE`, mvsMF's in `include/sendall.h`, note the different unit).
On a *blocking* socket libc370 waits instead and the application must not — see
libc370#120 / ftpd#104. One layer per socket, never two.

What it depends on that fails silently if broken (the ECB, `CSTATE_DONE`,
`keepalive`, `chunked`): `internals/sending.md`.

### Conventions

- Headers use `asm("SYMBOL")` annotations for MVS external symbol naming.
- Error responses follow z/OSMF format with category, reason code, and return code.
- Manual memory management — watch for malloc/free pairing and cleanup paths.
- Tab indentation, 4-space width, LF line endings (see `.editorconfig`).

### Off-Limits

- `receive_raw_data()` — DO NOT MODIFY (MVS TCP/IP bug workaround)
- Router core logic — modify ONLY for {*} wildcard support in is_pattern_match() and extract_path_vars()

## RENT constraint (CRITICAL)

MVSMF is link-edited **RENT** (read-only static storage). Writing to any
writable `static`/global data ABENDs S0C4. Keep all mutable state on the stack
or in `__getm`'d storage. The console cursors/detections live in a `__getm`'d
key/value store (`ntstore.c`) anchored in the httpd per-CGI context
(`mvsmfctx.c` → `http_cgictx_get`), never in statics.

## USS/UFS Endpoints

All handlers live in `ussapi.c`. USS payloads are **IBM-1047** (see **Codepage
Override**). Every handler gets its UFS session from `uss_get_ufs()` and never
frees it -- HTTPD manages the lifecycle -- and maps UFSD return codes through
`ufsd_rc_to_http()` / `ufsd_rc_to_category()` / `ufsd_rc_message()` into
`sendErrorResponse()`. Patterns, ASM labels and the full mapping table:
`internals/uss-handlers.md`.

## Console Services

All handlers live in `consapi.c`; data source is the Master Trace Table. Details:
`internals/console.md`.

## SMP4 FMID

`[smp] prefix = "TZMF"` in `mbt.toml`; mbt 3 derives the id and the delete from
the version (1.4.0 is `TZMF140`, deleting `TZMF130`). Rules, spent ids and
mvsMF's install history: `~/repos/mvs/.workspace/context/smp.md`.
