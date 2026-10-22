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
