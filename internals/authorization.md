# Authorization in mvsMF

Moved verbatim from `CLAUDE.md` on 2026-10-19; `CLAUDE.md` keeps the rules every session needs and points here.

Read before changing who may do what: `require_access()`, `racf_set_acee()`, job ownership, the data set listing.

### Authorization — explicit for data sets and jobs, none on the listing

**Data set operations authorize explicitly (#228, closed).** `require_access()`
(`dsapi.c:87`) calls `http_check_auth()` with the caller's own ACEE at ten call
sites, ahead of the first catalog or VTOC access, so a refusal cannot be told
from "does not exist". Member operations authorize on the **library** — RACF has
no member granularity — and a rename checks both names. A denial answers the
reference's `500` / category 4 body (#315); it no longer reaches the S913 that
OPEN used to raise and the router's ESTAE turned into a generic 500.

**One gap remains, deliberate and ticketed:** create (POST) is still implicit
(#329). `__dsalcf()` is SVC 99, not an OPEN, so it fell outside #228's site
list. RAKF *does* refuse it (measured) and the reference's dynalloc `500` is the
right answer — see `docs/endpoints/datasets/authorization.md` and **do not add
an authorization body there**. What is open is that the decision runs under
whatever ACEE sits in `ASXBSENV`, which is the last ambient dependency in the
data set API.

**Jobs authorize per job through the RACF class JESSPOOL (#440, the model of
FTPD 1.3.0; it replaced #345's "no authorization at all").** User-facing rules,
profiles and examples: `docs/jesspool.md`. What a maintainer must keep:

- **One decision function, `jwn_check()`** (`jwn.c`, header `jwn.h`, free of
  MVS headers so `test/host/tstjwn.c` links it). Own job (the owner is the
  caller's userid, whole, an owner is required) → allowed, no RACF call, no
  profile needed, even with `UACC(NONE)`. Any other job → entity
  `<owner>.<jobname>.<jobid>`, RACF READ (a purge also UPDATE). Everything that
  is not a clean answer — no ACEE, a component outside `A-Z 0-9 $ # @` or longer
  than 8, a return code other than 0/4/8 — **hides the job**. `jobauth.c` is the
  thin MVS side (`racf_auth()` with the request's ACEE); it must not use
  `http_check_auth()`, which folds "no profile" (4) into "allowed".
- **Every path that outputs job data asks it**: the job list (per job), job
  status, spool file list, spool records, purge, and the three job probes of
  `/zosmf/test` (`fn=job`, `fn=spool`, `fn=syslog`). A new path that shows a
  job needs the call as well.
- **Hidden must be indistinguishable from not found.** `send_job_not_found()`
  is the one 404 path of the job handlers; do not add a second wording or a
  different status for a hidden job. A READ-only purge is the one place that
  tells the caller something (`send_not_authorized()`: 500, category 4): the
  caller already may read the job, so nothing is revealed.
- **The job that is acted on is the verified `JESJOB`**, not the request
  strings: the purge hands the checked job's name and id to `jescanj()`. The
  job id is compared exactly.
- **The owner filter only narrows** (`jwn_narrows()`, `resolve_owner_filter()`
  in `jobsapi.c`): `*` needs READ on the entity `..`, a foreign user id `X`
  needs READ on `X..`, anything else is an empty list. Each job of the list is
  checked in addition.
- **The per-request cache keys on 8 characters** (`JWN_KEYLEN`): RAKF cuts the
  entity at 8 characters before it matches a profile, so what the cache treats
  as the same question RAKF treats as the same too. If RAKF ever compares more,
  the key must grow with it, or one answer is reused for jobs it was not given
  for.
- **Job fields are sanitized** (`jwn_printable()`) before they reach a response
  body, an error text or an operator message. mvsMF adds no WTO for this; the
  existing ones carry sanitized names.
- **Consequence to keep in mind:** without JESSPOOL profiles every user, an
  administrator included, sees only their own jobs. A tool that finds another
  user's job (for example the started task HTTPD through `owner=*`) needs a
  profile for it.
- `PUT .../jobs/{name}/{id}` with a cancel request is not implemented (#417);
  when it is, it follows the purge rule.

The `racf_set_acee()` pair in `mvsmf.c` stays as the **second** net, on purpose
(`httpd/docs/identity-redesign.md` §3.1 item 5). It is address-space-wide and
cannot be made correct while workers run concurrently — that is httpd#176 — so
it is redundancy behind the explicit checks, never the thing to rely on. For
create it is currently the *only* net.

**`GET /zosmf/restfiles/ds?dslevel=` is not gated at all, and that is a
decision, not an oversight (#229, closed).** The listing path (`__listds` +
`__locate`/`__dscbdv`) reads the catalog and the VTOC and opens nothing, so no
OPEN check is reached: every authenticated user can enumerate every data set,
with DSORG/RECFM/LRECL/volume. It stays that way because **real z/OSMF does the
same** — measured on the reference system, a PDSE that answers a member read
with `500 / "Authorization failed - You may not use this protected data set"`
lists with full attributes to that same userid. z/OS does not gate
`LISTCAT LEVEL()` per entry either. Gating it would make mvsMF stricter than the
thing it clones, and cost one RACHECK per entry on the request path.

Member listing is **not** in the same position: `__listpd()` and the streaming
directory read open the PDS with BPAM, so they do go through OPEN.

If that ever gets revisited, the constraint from #229 holds: a refusal must not
be distinguishable from "does not exist", or the gate becomes the enumeration
oracle it was meant to close.

### Console services and `/zosmf/test` — a fail-closed check in the handler (#347, #460)

Every console handler (`consoleIssueHandler`, `consoleCollectHandler`,
`consoleDetectHandler`, `consoleLogHandler` in `consapi.c`) and both `/zosmf/test`
handlers (`testHandler` including `fn=version` and the help text, and
`testWildcardHandler` in `testapi.c`) call `console_authorize()` (`consauth.c`,
header `consauth.h`) as their **first statement**, before any parameter is read
or any byte is written. A new `fn=` in `testHandler` is covered by that one call
at the top; a new console route must call it too.

- **The profile is `FACILITY MVSMF.CONSOLE`, READ, for both.** One resource
  gates the console and `/zosmf/test`; there is no second profile.
- **Only SAF return code 0 permits.** `console_authorize()` takes the caller's
  ACEE from `http_get_acee()` and calls `racf_auth(acee, "FACILITY",
  "MVSMF.CONSOLE", RACF_ATTR_READ)`. No profile (rc 4), a denial (rc 8), any
  other code and a missing ACEE all refuse. `http_check_auth()` is the wrong
  call here: it folds rc 4 into "allowed" (see the comment at `require_access()`
  in `dsapi.c`), which is correct for data sets and wrong for a service that must
  stay closed until somebody has defined the profile.
- **The decision is a pure function** (`authdec.c`, header `authdec.h`, free of
  MVS headers so `test/host/tstauthd.c` links it): `authdec_decide(acee_present,
  rc)` returns allow only for an ACEE and rc 0, and `authdec_gate()` asks the
  RACF callback at most once and not at all without an ACEE. `consauth.c` is the
  thin glue around `racf_auth`; keep the logic out of it.
- **The answer:** `send_not_authorized()` — `500`, category 4 (Authorization),
  inside the closed status list — for rc 4 and rc 8 alike, so a client cannot
  tell "no profile" from "no READ". A missing ACEE gives `401` as in
  `require_access()`. The handler returns `-1`, not the sender's return value.
  **No WTO**: the refusal is caused by the client, and `consapi.c` reads the
  Master Trace Table, so a message would come back out of the console API.
- **Upgrade behaviour, not an error:** until the profile is defined and READ is
  granted, these endpoints refuse **every** user, administrators included.
- **The httpd route stays a first layer.** The shipped route `MOD=MVSMF
  /zosmf/restconsoles/* AUTH=TOKEN RES=FACILITY:MVSMF.CONSOLE` is listed before
  `/zosmf/*` in `samplib/mvsmfprm`. It requires READ: a user without it gets a
  plain-text `403` from HTTPD before mvsMF is reached. httpd's
  `samplib/httpprm0` has the line since httpd#338, merged after the v4.3.0
  release (the v4.3.0 sample has three lines); keep both in step. The route is
  optional now: the handler check is the authoritative one, it does
  not depend on route order, and it does not fail open without the profile
  (the route only warns with `HTTPD425W NO PROFILE FOR
  FACILITY:MVSMF.CONSOLE`). Do not add a route for `/zosmf/test`.
- `mbt` sends `P`/`S`/`D` through the console service; the user in the target
  needs READ. The refusal is a `500`. Measured on a throwaway container
  with a Hercules channel in the target: `mbt run restart -- HTTPD` without
  READ prints `WARNING: P HTTPD went out but its answer was lost (... HTTP 500
  ... Authorization failed ...)` and then `ERROR: restart: HTTPD is still
  active after P -- not started again`; HTTPD keeps running. The fall back to
  the Hercules console happens only when the connection is refused, not for
  this refusal. Teaching mbt this refusal (a `500` with
  `"category":4` is certainly not issued) is a question for mbt, not for mvsMF.
- Tests: `test/host/tstauthd.c` (the decision), `tests/curl-consgate.sh` (the
  matrix on MVS: no profile, READ for one user only, READ for both, profile
  removed again; every route and its path variants; by name only, rewrites
  `PROFILES`, needs `MVSMF_CONSGATE_WRITE_PROFILES=yes` and a throwaway
  system).

**The route as a first layer, measured (#459).** On MVS/CE with RAKF and
httpd 4.3.0, 2026-10-23:

- A user without READ gets `403`, plain text, from httpd (measured with a token
  session). That is outside the closed status list of `zosmf-conformance.md`
  and not a z/OSMF-shaped body; mvsMF is not reached.
- READ for a group line and for a user-id line (user id in the group column)
  both work. The user without READ still passes every other `/zosmf/` route.
- Route order decides for the route. Listed after `/zosmf/*` it is never
  consulted, and the start-up log shows no difference but the order of the
  `HTTPD036I` lines.
- Without the profile the route only warns `HTTPD425W NO PROFILE FOR
  FACILITY:MVSMF.CONSOLE -- /zosmf/restconsoles/* NOT GATED` and permits the
  access: the route alone is fail-open until the profile exists.
- The path `restconsoles//consoles` is refused with `403` as well.

**Not decided:** a per-command policy (out of scope for #347, see `TODO.md`).

### The path is decoded once (#507)

Every decision above is made on a name, and it has to be the name the client
meant. httpd percent-decodes the path once, in `http_decode()` while it parses
the request line (`httppars.c`), and hands it over as `REQUEST_PATH`; query
values are decoded once there too (`QUERY_*`). Up to 1.3.0 `handle_request()`
decoded `REQUEST_PATH` a second time before it matched a route and extracted
the path variables, so `%25b1` in a URL (the name `%b1`) reached the handler as
a different character, and a path encoded twice was decoded twice. The route
match, the `HTTP_<name>` path variables and the authorization check were
therefore working on a name other than the one in the request.

Since #507 the router takes `REQUEST_PATH` as it is (`request_path_copy()`,
`src/reqpath.c`). **Do not decode it again, and do not add a decode step to a
handler.** Measured on a throwaway system with the USS file API, before and
after: `PUT .../lit%2541` stored `litA` and `.../lit%25b1` stored `lit` plus
the byte `X'B1'`; both now store `lit%41` and `lit%b1`. A name that was
once-encoded (`ctl%41`) and one with a trailing `%25` are unchanged. Host test
`test/host/tstrqpth.c`; REST test: the "decoded once" block in
`tests/curl-uss.sh`.

What this does not change: httpd still maps `+` to a blank in the path as well
as in the query, so a literal `+` in a USS name has to be sent as `%2B`.
