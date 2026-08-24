# mvsMF — Open Work, Ranked

**State lives on GitHub, not here.** `gh issue list --repo mvslovers/mvsmf` is
the source of truth for what is open. What this file adds is the part the tracker
cannot hold: the **order**, the reason for it, which items are a decision rather
than code, and the per-issue hazard that makes an obvious-looking fix not one.

**It carries nothing that is copied.** Where the reasoning already has an owner —
the issue thread, the PR, `docs/uss-spec.md` — this file points at it and stops.

*Last reconciled against the tracker: 2026-08-24, 18 issues open — seventeen
entries below, because one of them pairs two issues. #245's doc half landed in
PR #349; it stays open on its implement-vs-reject decision. #214 and #267 both
closed on 2026-08-24, which is why Tier 1 is down to a single entry.*

---

## The order

| | Issue | Kind | Waiting on |
|---|---|---|---|
| 1 | #336 | accepts the syntax, discards the operand | wire it or reject it |
| 2 | #210 | client-visible, fix identified, local | nothing |
| 3 | #251 | Optimistic Path stop pattern | nothing |
| 4 | #209 | client-visible, cheap on 3.8j | nothing |
| 5 | #245 | docs corrected; decision open | reader-vs-400 decision |
| 6 | #326 | its trigger has fired | nothing |
| 7 | #76 | the one externally reported defect | nothing |
| 8 | #244 | the ordering constraint is the content | nothing |
| 9 | #215 | latent, one place, every caller benefits | nothing |
| 10 | #257, #335 | one class, two tickets | a repro without a proxy |
| 11 | #347 | an authenticated user can stop the system | **a policy** — measured, nothing to delegate to |
| 12 | #234 | `type:research` | measuring the reference |
| 13 | #329 | `type:research` | **one measurement** — see *RAKF* |
| 14 | #345 | `type:research` | **a policy** — see *RAKF* |
| 15 | #195 | split from #214 — not the same bug | one two-snapshot measurement |
| 16 | #291 | reclassified — hygiene, not stability | nothing |
| 17 | #186 | unblocked; sysroot refreshed 2026-08-23 | nothing |

---

## Tier 1 — now

### 1 · #336 — `{volume-serial}` is captured and never used

Seven routes accept `-(VOLSER)` and discard the operand; a request naming the
wrong volume is answered as if it had named the right one. Ranked here because
the answer looks correct.

The two resolutions differ by an order of magnitude: wire the volser through to
`__dscbdv()`/OPEN, or reject the seven routes. **The rejection is nearly free** and
worth taking even as an interim.

---

## Tier 2 — cheap and client-visible

### 2 · #210 — the submit response returns `owner:""`

A race, not a divergent path — and therefore **not fixable by asking libc370
earlier**: `JCTUSEID` is unwritten and the internal text is not on the spool yet.
mvsMF already knows the answer, because `process_jobcard()` injected `USER=`.
Fall back to that. Check the purge handler (`jobsapi.c:363,375`) for the same
emptiness, and make `tests/curl-jobs.sh` assert the value, not the key.

### 3 · #251 — console log answers 200 with an empty body on allocation failure

`consapi.c:1100` collapses a NULL `cmtt_new()` into `n = 0`. The MTT copy is the
largest allocation on that path — the one most likely to fail exactly when a
silent empty answer misleads most. The sibling `malloc()` three lines below
already returns 500. Textbook **Optimistic Path**; check `:266` and `:457` too.

### 4 · #209 — `exec-system` and `exec-member` are never emitted

3.8j has no sysplex, so `CVTSNAME` is a correct constant answer and needs no
libc370 change. `JCTRDSID` is right in principle and re-opens the relink chain
(`libc370#79`) for no gain here. Take the cheap one deliberately, and say so in
the code.

### 5 · #245 — `X-IBM-Data-Type: record` cannot be written back

The read path length-prefixes each record; the write path sends `record` down the
*text* loop, so the four bytes read back as a length are a length only by accident.

**The docs are corrected — that half is done.** It was three places, not the
two the issue names: the opening sentence of `put.md` and `members-put.md`,
their `X-IBM-Data-Type` bullets, and the common-header table in
`docs/endpoints/README.md`. Grep before trusting an issue's list of sites.

What is left is the choice: a length-prefixed reader (mind a prefix split
across a chunk boundary, and `record_content_max()`), or a 400. Nothing
misleads a client in the meantime.

### 6 · #326 — five sources missing from the CLAUDE.md list

`abendmsg.c`, `hostparse.c`, `jclines.c`, `reclines.c`, `spoolln.c`. The issue said
"next time `CLAUDE.md` is touched", so fold it into the next edit of that file
rather than spending a PR on it. Read each file rather than inferring from the name,
which is how the list drifted in the first place.

---

## Tier 3 — correctness, needs care

### 7 · #76 — DSORG=DA in `datasetPutHandler` via BDAM

*the only defect on this list someone outside the project reported*

A ufsd image upload `SD37`s because QSAM extends past the primary allocation on a
DA data set. Detect `DSGDA` from the DSCB — the list handler already does — and
switch to the `osd*` BDAM API for PUT and GET.

Ranked above the two unobserved defects below it deliberately. This file orders by
impact on running systems, not by age or effort, and #76 is the one item here that
is observed, reported from outside, and blocking a real workflow; #244 is currently
harmless and #215 has never been seen at all. What holds it out of Tier 1 is that
`ufsd-utils upload` does the job today — a workaround, not an absence of impact.

### 8 · #244 — `#define VARIABLE 0x0002` is the wrong RECFM mask

**The ordering constraint is the whole content of this ticket.** The broken mask
is the only thing keeping `write_record()`'s manual RDW dormant, and that RDW is
itself wrong — libc370's `varflush()` already builds one. Correcting the mask
alone ships **two** RDWs. Remove the manual RDW first, then fix the mask. Drop
`FIXED`/`UNDEFINED` in the same edit: wrong the same way, and unused.

The regression test wants a **VB** data set written binary and read back with
lengths checked — `curl-binary.sh` uses FB, which is why this survived.

### 9 · #215 — `addJsonStringEsc()` escapes five characters, not the control range

One raw control byte makes the **whole** response unparseable, and `consapi.c`
passes Master Trace Table text — whatever any address space wrote to the console.
Honest scope, per the issue: **no observed failure**. #212 fixed this locally in
`dsapi.c` to keep that PR narrow; a fix here lets that copy go.

The subtlety from #212, easy to lose: `http_printf()` translates on the way out,
so the printability test applies to the **translated** byte, via `xlate_cp037`.

### 10 · #257 + #335 — early 4xx on a PUT with a body still in flight

**One class, two tickets — rank and fix them together.** Every early return in the
PUT handlers answers before draining the announced body (`dsapi.c:1156, 1180,
1192, 1217`; `memberPutHandler` at `:1945`, `:1991`), so the client can see a
transport error instead of its status. Same class as #126.

Neither is confirmed. #257 was seen once through a proxy — a confounder that
turned the reset into a 502 — so **reproducing without a proxy is step one**. #335
is the same shape narrowed to one stand after #334 removed its trigger; it needs
`fn=version` and a proxy check from that stand and is no longer user-visible.
Draining probably closes #257 and reduces #335 to the proxy question.

---

## Tier 4 — decisions before code

### 11 · #347 — restconsoles authorizes nothing at all

*an authenticated user can stop the system*

`grep -c 'http_check_auth\|require_access\|racf' src/consapi.c` → **0**, against
25 in `dsapi.c`. `issue_command()` leaves the SVC 34 buffer's bytes +2/+3 zero,
so every command goes out from **console 0 — the master console** — with the text
passed through unfiltered: `$P JES2`, `V xxx,OFFLINE`, `P`/`S` of any started
task. `GET /restconsoles/v1/log` separately returns the whole Master Trace Table
to anyone. Neither latent nor intermittent: it is what the shipped endpoint does
today.

Ranked at the top of its tier because this file orders by impact on running
systems: #214, now closed, handed a client a wrong answer; this hands it the
machine.

**It is #345's twin, and the hope that it was not has been measured and is
gone.** The first version of this entry claimed a native MVS mechanism needing no
security product — issue from a console with a lower authority level and let MVS
refuse. Read from primary source on 2026-08-23, that does not exist:
`SYS1.AMODGEN(IEECDCM)` maps the SVC 34 buffer as length / **MCS flags** / text
with **no console field**, and `MGCR` passes none. The authority machinery is
real — `IEECUCM`'s `UCMAUTH` groups commands into SYS / I/O / CONS per console,
set at sysgen — but it hangs off the UCM entry of the console a command was
*entered at*. MGCR from a program has none, which is what `CONS(0)` means: no
console, not master console selected.

So there is nothing to select and nothing to weaken, and the policy has to be
invented here exactly as in #345. Ranked at the top of Tier 4 rather than in
Tier 1 for that reason: it outranks everything below it on impact, but nothing
can be done *now* without a maintainer decision, and an entry in "Tier 1 — now"
that no one can act on is what this file's preamble warns against.

Directions are in the issue, none verified. The one worth knowing before
reaching for the obvious: a display-only allow-list **breaks a real workflow** —
`P FTPD` / `S FTPD` are group-1 (SYS) commands and are in use today (#346's
transcript). Decide with #345 and `ftpd#90`.

### 12 · #234 — what should the API do with non-ASCII input?

Byte-wise through CP037 with no UTF-8 decoding — and **invisible through the API**,
because `etoa` inverts `atoe`, so only ISPF and the program reading the member see
it. One case is worse: any sequence containing `0x85` becomes `0x15`, which
libc370's `__fputc` treats as a record terminator, so the line splits and the byte
is dropped — **with HTTP 204**. Four ecosystem `samplib` members carry UTF-8 today.

Research because the policy is the hard part. Measure the reference first
(`--zosmf-p zxp`, read-only) — it has `fileEncoding=` controls the clone does not.
`xmit370`'s split between well-formed UTF-8 and Latin-1 is worth borrowing. Decide
GET and PUT together; a reject changes the round-trip property.

### 13 · #329 — dataset create is authorized only by the ambient ACEE

**The endpoint is not unauthorized and the response shape is settled** (#315,
#317): RAKF refuses the allocation and the refusal must stay indistinguishable
from any other dynalloc failure. *Do not add an authorization body here.* What is
open is only **which identity decides** — SVC 99 runs under whatever sits in
`ASXBSENV`, the last ambient dependency left after #228.

The cheap unblocked step is a measurement, and it decides whether the fix exists
at all: what does RACHECK answer for a name with no catalog entry and no DSCB?

### 14 · #345 — restjobs has no authorization model

`grep -c 'http_check_auth\|require_access' src/jobsapi.c` → **0**, against 25 in
`dsapi.c`. `owner=*` switches the default off, and the four by-jobid paths —
including **spool-content read** and **purge** — never consult an owner at all.

The tension is real: #229 says do not be stricter than the thing we clone; #228
chose the strict side for everything that mutates or reads content. #229 does
**not** settle this by precedent — it settled the *listing* half, which is the
least of the four paths here. So measure the reference for all four, as #229 was.
Whatever refusal is chosen must keep #229's constraint: "not yours" must not be
distinguishable from "does not exist". Establish `jescanj()`'s own behaviour on a
foreign purge, on a throwaway job. Decide together with `mvslovers/ftpd#90`.

### 15 · #195 — detections intermittently report `waiting` for a message that was emitted

**Split out of #214 on 2026-08-23: they are not the same bug.** Structural, no
measurement needed — `detect_count()` never reads `MTT_SRC_OFF`, never anchors an
echo and never walks a block. It is a `strstr` count over the whole snapshot
against a stored baseline, so #214's `has_src` contamination has no route into
it. What the two share is only the substrate: a global, wrapping, second-granular
MTT with no per-request identity, over which both features fake a cursor.

Here rather than in Tier 1 because nothing reaches a client wrongly — a
detection is missed, not misattributed — and because no fix can be designed
before one cheap measurement runs. Above Tier 5 because a silently missed
operator reply is impact on a running system, which is what this file orders by;
`#291` is hygiene and `#186` is a feature.

One thing is already settled from code: `unsol_base` is snapshotted **after**
`issue_command()`, so a `D T` carrying `unsol-key: IEE136I` detects its own
reply. `tests/curl-console.sh` asserts the opposite in a comment; the assertion
passes for the wrong reason and wants correcting either way.

**A provocation recipe fell out of #214's verification and is in the issue:** the
two `detections` assertions failed in the one console-suite run that carried the
most MTT traffic (`P FTPD` + `S FTPD`) and passed in three quiet runs against the
same module. That favours the aging-out branch below over the torn-`memcpy` one,
and it says when to run the discriminator — while a started task stops and starts.

The discriminator is two back-to-back `cmtt_new()` snapshots with no traffic
between: equal `n` with the oldest timestamp advancing under load means entries
aging out of the window between baseline and poll — a `D T` cluster leaving it
drops the count by more than the new match adds, and where the trailing edge
falls is exactly the reported non-monotonicity. `n` jumping between adjacent
snapshots instead means a torn walk in `cmtt_new()`'s unserialized `memcpy`,
which is libc370 and a different ticket. A third candidate the test does not
separate: `array_add()` failing to expand under storage pressure, silently
truncating the snapshot.

---

## Tier 5 — larger work

### 16 · #291 — large bodies fully buffered, twice on submit

**Reclassify: memory hygiene, not stability.** Its motivation — stopping long-held
requests acting as the anvil for httpd#195's fragmentation — is gone: #287 closed,
httpd#195 closed, and `__stklen` (#290) cut mvsMF's demand from 262328 to 65584
bytes, which fits every hole that mechanism produced.

What survives is worth doing on a 24-bit target anyway. Start with
`jobsapi.c:2061` — a full-size EBCDIC copy beside the raw body, so a 1 MB submit
holds 2 MB. Cheapest item, and independent of the streaming work.

**`receive_raw_data()` stays byte-at-a-time** (PR #22 / #42, the TCP ring-buffer
bug). Streaming changes what we do with the bytes, not how they are read.

### 17 · #186 — console log: deep history beyond the MTT window

**No longer blocked — the issue text says it is, and that is out of date.** Its
hard dependency `libc370#21` is **closed and verified on target** (PR#31,
`JOB00321`): `jesprint()` now names why it stopped, so the endpoint can finally
tell "gone" from "empty". `libc370#30` (PSO/SSI instead of the checkpointed IOT)
was only ever the *nicer* route and is still open — it is not a gate. The sysroot
refresh it also needed was done on 2026-08-23, so **nothing is in the way**.

**Read libc370#21's closing comment before designing the mapping — the obvious one
is a trap it already caught.** A foreign block means two different things by
position: on the **first** block the data set really is gone; **after** accepted
blocks it just means the data set is still open, its last block pointing at an
allocated-but-unwritten track. The first implementation reported HTTPD's two live
spool files as purged *after successfully reading 350 and 3170 lines from them*.
`JESPR_OPENEND` versus `JESPR_FOREIGN` carries the distinction; `st->blocks` is
what tells them apart.

Note also that the mapping the old #187 sketched cannot be reused as written: its
410 Gone is not a z/OSMF status and was removed in #250. "Gone" belongs in the
error report's `reason`, not the status line — `REASON_SPOOL_GONE` is the worked
example.

#145's closing line — *"the active SYSLOG on spool is not browsable"* — is stale
too: the failure was a `NOHOLD` class letting a printer purge the data set. The two
operational requirements (`VARY SYSLOG,HARDCPY`, and spinning to a held class)
belong in `docs/endpoints/console/hardcopy-log.md`, and mvsMF can issue
`WRITELOG H` through the console API it already has.

---

## Deferred — RAKF: nothing in this repo

Maintainer decision, 2026-08-23: anything needing a change in `MVS-sysgen/RAKF` is
flagged `blocked:rakf` and ranked out. **No mvsMF issue meets that test**, and that
is measured, not an omission — `httpd/TODO.md`, reconciled the same day, lists
`mvslovers/mvsmf#329` and `#345` under *"Unblocked and outside this repo"*.

What *is* off the table is one **branch** of each. Both keep their ranking above,
on their unblocked branch:

- **#329** — resolution **B** (wait for the per-task ACEE to make the ambient value
  correct by construction) is `MVS-sysgen/RAKF#5`. Resolution **A** is entirely
  ours and starts with a free measurement. If that measurement kills A, the honest
  outcome is to write B into `docs/endpoints/datasets/authorization.md` and stop —
  not to wait.
- **#345** — JESINTERFACELEVEL **2** delegates to a `JESSPOOL` class RAKF does not
  have. **Level 1** (jobname = userid plus at most one character) needs no security
  product and is implementable today. The policy is ours under either.

The one thing genuinely waiting on RAKF that touches mvsMF is `mvslovers/httpd#176`,
the ambient-identity switch, and it is ranked *there*. `docs/identity-redesign.md`
owns that story across all five projects — **do not re-rank it here**; update the
status line there.

#345 is **not** evidence for httpd#176: JES spool has no RAKF gate on 3.8j at all,
so no ACEE decides anything on that path. #329 is that bug's shape; #345 is a
policy vacuum.

---

## Recently closed

Pointers only — the reasoning lives in the closing comments.

- **#355** — `/zosmf/test` answered with no framing at all: no
  `Content-Length`, no `Transfer-Encoding`, and `Connection: keep-alive`
  anyway, so every call cost about 5 s waiting for the socket to close. Opened
  and closed the same hour in PR #356, found while verifying #267 — the 5 s
  reading looked at first like a server the abort probe had damaged. Two things
  worth carrying: the trigger is a **shape**, `httpprtv.c` injects chunked only
  when the blank line arrives as its own `http_printf()` (`len == 2`), so
  gluing it to the `Content-Type` header disables framing silently — httprexx
  and httplua write headers under the same httpd, and the same mistake is
  available there. And the test asserts the *header*, never the elapsed time: a
  timing assertion goes green on any stand with a short idle timeout, which is
  how this survived being measured at all.
- **#267** — `unsigned rc` in the two data set list handlers, closed together
  with **#353** in PR #354. The transferable part is the sweep that found the
  second one: cc370 is GCC 3.4.6, where the tautological-comparison warning
  lives under `-Wextra` (`-Wtype-limits` is 4.3+), and one pass over every TU
  reported 45 dead `< 0` checks in `dsapi.c` and exactly one other hit in the
  tree — `get_operation()`'s right trim, which was not dead but *writing*, one
  byte below its own stack array, on any deck ending in a blank-padded `//`.
  Cheap to repeat; budget for filtering the 61 other `-Wextra` warnings.
  What could not be shown is the fix working on the wire, and the reason is
  narrower than it first looked: the failure path *is* reached — an aborted
  client's RST lands within milliseconds, and a `send()` on a reset connection
  fails however much room the host-side buffer has, which is what separates
  this from the `rc == 0` stall #298 measured as unreachable here. What is
  missing is an observable: nothing on the client side tells a handler that
  stopped at the first failed write from one that wrote the rest into a dead
  socket, and 3.8j offers no CPU counter to weigh them (`D A,L` carries none).
  A measurement gap, not an unreachable branch.
- **#214** — the console correlation. Closed on 2026-08-24 in four landings:
  the serialization (PR #348), the reproduction of the collect half (PR #350),
  the fix (PR #351) and one narrowing found by review rather than by
  measurement (PR #352 — the block end must test the *issuer's* source, or a
  MODIFY target answering without a message id is truncated mid-reply; UFSD
  answers `UFSD010I`… so no test on this stand could have caught it). The transferable parts, none of them about locks:
  a correct anchor made a *missing* block end visible — the first key came back
  with its own reply followed by the next command's, so the two halves had to
  land together; the field that would have made the block end exact does not
  exist, and that is now measured rather than assumed (`mtentflg`/`mtenttag`
  read uniform `0000`/`0001` over 317 entries, echo and reply alike, via the
  `fn=mtt&hdr=1` the PR adds); and what replaced it — an MVS message id carries
  a digit in its first token, a command does not — is a heuristic held safe by
  *where* it is applied, only to lines the walk would otherwise swallow. The
  residual limits are in `docs/endpoints/console/collect.md`, promoted from
  open work to documented behaviour: same-second identical commands, an echo
  aged out of the window, and the sync-capture race that two measured attempts
  failed to close.
- **#346** — the sync console capture converging on 0.3 s of quiet. Closed on
  measurement, not on code: `P FTPD --wait-to-collect 5` returns all four lines
  where the plain call returns one, so the completion path already worked and
  the contract already matched the reference. The timer was the obvious fix and
  the wrong trade twice — see the closing comment. Landed in PR #349 as
  documentation plus a regression test that measures 1 line captured against 3
  collected. The test's shape is the transferable part: "more lines with the
  flag than without" is not assertable alone, because it goes green on a stand
  fast enough to catch the whole block in one window.
- **#248** — the ussapi statuses outside the z/OSMF list. Landed in `3de44a0`
  (2026-08-16) plus `14302da` for ROFS (#250); the commit never named the issue,
  which is the only reason it stayed open for a week. Re-verified against `main`
  before closing.
- **#282** — the jobs API `S0C4` on `jesjob(dd=1)`. Fixed upstream by
  `libc370#126`; verified on mvsdev 2026-08-23 against a refreshed sysroot and an
  activated `f1bb06c`. All 13 MBTTEST runners on the spool read back 200 —
  including the three the reopen comment recorded as `S0C4` — and `make test-mvs`
  completed 508 PASS / 0 FAIL with no abend in the console window.
- **#323** — in-stream data in the JESJCLIN listing: closed on **option A**, client
  side. z/OSMF does not serve JESJCLIN at all, so no reference behaviour exists to
  match and every server-side variant is an extension. The rule the frontend needs
  is in the closing comment: match in-stream data to spool files **by ddname, never
  by position**.

## Campaigns, not twenty tickets

- **Console correctness** — **#251 and #195 are what is left**, with #346 and
  #214 both closed out of it. One subsystem and one reading of `consapi.c`, but
  four separate bugs, and the two that closed were the two that shared a
  premise: "MVS gives no end-of-response signal, so both ends of the block are
  guessed". #346 was the *end* guessed too early (by design, closed as
  documentation plus a test); #214 was the *start* guessed wrong and then no end
  guessed at all. #195 was ranked with #214 on the guess that it might not
  survive #214's first measurement, and that premise died before #214 did — see
  #195's entry. #251 was always independent of all three.
- **The endpoint advertises what it does not do** — #245 and #336, with #248 as
  the worked example of how it ends. **#245's doc half is done**, which is the
  campaign's proof that the cheap half is worth taking alone: the mode is still
  unimplemented and nothing lies about it any more. #336's reject half is the
  same move and is still open.
- **Checked, then swallowed** — **#251 and #215 are what is left**, with #267
  closed out of it as the worked example: the return code is inspected and the
  failure goes nowhere. One convention, not three decisions. #267 also says how
  to find the rest of the class mechanically rather than by reading — see its
  entry under *Recently closed*.
- **The authorization endgame** — #347, #329, #345, with `httpd#176` behind
  them. #347 looked like the least blocked until its measurement came back
  empty: there is no console authority to delegate to, so all three now wait on
  policy that has to be invented here. #347 is the one to settle first — it
  outranks the other two on impact by a wide margin.

## Cross-repo

mvsMF-only. Do not rank these here — update them where they live.

Still open and ours to wait on — all three verified 2026-08-23: `libc370#79`
(`exec-submitted`, and the accurate answer for #209), `libc370#30` (the nicer route
for #186, not a gate for it), `httpd#176` (`blocked:rakf`), and `ftpd#90` (decide
with #345).

**Cashed in on 2026-08-23** — libc370 rebuilt and installed into the cc370
sysroot, mvsMF rebuilt, deployed and activated: `libc370#21` (which unblocked
#186), `#126` (which closed #282), `#127`, `#128`, `#131` and `#104`. Measured
after: `make test-mvs` 508 PASS / 0 FAIL.

The mechanism is the part to remember, because it recurs every time libc370
moves: **none of those arrive via `make deps`.** libc370 is the cc370 sysroot,
not a declared dependency — `mbt.lock` pins only httpd and ufsd. A libc370 fix
reaches mvsMF only after `make install` in libc370, a rebuild here, `make deploy`,
and `tests/jcl/mvsmfact.jcl`. Skip any one of the four and you measure the old
module.
