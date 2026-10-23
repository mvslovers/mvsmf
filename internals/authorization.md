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

### Console services — gated by httpd, not by mvsMF (#347)

`consapi.c` makes no authorization call and must not grow one for *who* may use
the service: the gate is the httpd route `MOD=MVSMF /zosmf/restconsoles/*
AUTH=TOKEN RES=FACILITY:MVSMF.CONSOLE`, listed before `/zosmf/*` in
`samplib/mvsmfprm` (and httpd's `samplib/httpprm0`; keep both in step).
Measured on MVS/CE 2026-10-23 with httpd 4.3.0:

- A user without READ gets `403`, plain text, from httpd — outside the closed
  status list of `zosmf-conformance.md`, and not a z/OSMF-shaped body. It is
  httpd's answer; mvsMF is not reached (measured with a token session).
- READ for a group line and for a user-id line (user id in the group column) both
  work. The unauthorized user still passes every other `/zosmf/` route.
- Route order decides. Listed after `/zosmf/*` the route is never consulted, the
  start-up log shows no difference but the order of the `HTTPD036I` lines, and a
  user without READ gets `200`.
- No profile: `HTTPD425W NO PROFILE FOR FACILITY:MVSMF.CONSOLE -- /zosmf/restconsoles/*
  NOT GATED` and everybody passes. The route is therefore fail-open until the
  profile exists; there is nothing mvsMF can do about it.
- `restconsole%73`, `%72estconsoles` and `%2f` for a slash, and
  `restconsoles//consoles`, were refused (403).
- `mbt` sends `P`/`S`/`D` through this service; without READ it prints a warning
  and falls back to the Hercules console, or fails with "not delivered".

**Not covered (#460):** the diagnostic endpoint `/zosmf/test` sits under
`/zosmf/*`, so the profile does not reach it, and it has no authorization check
of its own. Only `-DMVSMF_NO_TEST_ENDPOINT` closes it; a second httpd route
with the same `RES=` would also gate `fn=version`, and is no better than this
route is (it depends on route order and is fail-open without the profile).
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
