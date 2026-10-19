# Authorization in mvsMF

Moved verbatim from `CLAUDE.md` on 2026-10-19; `CLAUDE.md` keeps the rules every session needs and points here.

Read before changing who may do what: `require_access()`, `racf_set_acee()`, job ownership, the data set listing.

### Authorization — explicit for data sets, absent for jobs, none on the listing

**Data set operations authorize explicitly (#228, closed).** `require_access()`
(`dsapi.c:87`) calls `http_check_auth()` with the caller's own ACEE at ten call
sites, ahead of the first catalog or VTOC access, so a refusal cannot be told
from "does not exist". Member operations authorize on the **library** — RACF has
no member granularity — and a rename checks both names. A denial answers the
reference's `500` / category 4 body (#315); it no longer reaches the S913 that
OPEN used to raise and the router's ESTAE turned into a generic 500.

**Two gaps remain, both deliberate and both ticketed:**

- **Create (POST) is still implicit** (#329). `__dsalcf()` is SVC 99, not an
  OPEN, so it fell outside #228's site list. RAKF *does* refuse it (measured)
  and the reference's dynalloc `500` is the right answer — see
  `docs/endpoints/datasets/authorization.md` and **do not add an authorization
  body there**. What is open is that the decision runs under whatever ACEE sits
  in `ASXBSENV`, which is the last ambient dependency in the data set API.
- **`jobsapi.c` authorizes nothing at all** (#345). `owner` defaults to the
  caller but a client can widen it with `owner=*`, and the by-jobid paths —
  spool-content read and purge included — never consult an owner. RAKF has no
  JESSPOOL class, so there is nothing to delegate to; the policy has to be
  invented. Mirror of `mvslovers/ftpd#90`.

The `racf_set_acee()` pair in `mvsmf.c` stays as the **second** net, on purpose
(`httpd/docs/identity-redesign.md` §3.1 item 5). It is address-space-wide and
cannot be made correct while workers run concurrently — that is httpd#176 — so
it is redundancy behind the explicit checks, never the thing to rely on. For
create it is currently the *only* net. For jobs there is no net at all — RAKF
does not protect JES spool, so no ACEE, ambient or explicit, decides anything
on those paths; that is why #345 is a policy to invent and not a check to add.

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
