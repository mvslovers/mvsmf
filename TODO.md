# mvsMF — Open Work, Ranked

**State lives on GitHub, not here.** `gh issue list --repo mvslovers/mvsmf` is
the source of truth for what is open. What this file adds is the part the tracker
cannot hold: the **order**, the reason for it, which items are a decision rather
than code, and the per-issue hazard that makes an obvious-looking fix not one.

**It carries nothing that is copied.** Where the reasoning already has an owner —
the issue thread, the PR, `docs/uss-spec.md` — this file points at it and stops.

*Last reconciled against the tracker: 2026-08-23, 20 issues open, all of them
work — eighteen entries below, because two of them pair two issues each.*

---

## The order

| | Issue | Kind | Waiting on |
|---|---|---|---|
| 1 | #282 | the ecosystem blocker | a sysroot refresh + one run |
| 2 | #214, #195 | wrong data reaches a client | nothing |
| 3 | #267 | latent; one word, activates ten paths | a read of `quit:` |
| 4 | #336 | accepts the syntax, discards the operand | wire it or reject it |
| 5 | #210 | client-visible, fix identified, local | nothing |
| 6 | #251 | Optimistic Path stop pattern | nothing |
| 7 | #209 | client-visible, cheap on 3.8j | nothing |
| 8 | #245 | the docs are wrong *today* | doc fix now, decision after |
| 9 | #326 | its trigger has fired | nothing |
| 10 | #76 | the one externally reported defect | nothing |
| 11 | #244 | the ordering constraint is the content | nothing |
| 12 | #215 | latent, one place, every caller benefits | nothing |
| 13 | #257, #335 | one class, two tickets | a repro without a proxy |
| 14 | #234 | `type:research` | measuring the reference |
| 15 | #329 | `type:research` | **one measurement** — see *RAKF* |
| 16 | #345 | `type:research` | **a policy** — see *RAKF* |
| 17 | #291 | reclassified — hygiene, not stability | nothing |
| 18 | #186 | unblocked since `libc370#21` — needs a mapping decision | a sysroot refresh |

---

## Tier 1 — now

### 1 · #282 — jobs API `S0C4` on `jesjob(dd=1)`

*the only item here that blocks another project — and the diagnosis is already done*

Its last open question — dd=0 green while dd=1 abends, same job, same second — is
answered upstream by `libc370#126`, merged as PR#129: only the dd=1 walk traverses
the multi-buffer internal-text chain, and that parser can walk past its buffer.
So this still carries work, but the work is a verification run, not an investigation.

`make test-mvs` reports **"no test ran"** for a job whose steps all ended
`CC 0000`. That mistranslation is the real damage, and it blocks the MVS test
story ecosystem-wide while CI only compiles `make test`.

Two preconditions, both easy to miss and, missed, the run measures nothing:
**libc370 is the cc370 sysroot, not a declared dependency** — `mbt.lock` pins only
httpd and ufsd, so `make deps` cannot bring the fix in; and **`make deploy` alone
changes nothing** — `mvsmfact.jcl` has to run and `fn=version` has to match.

Closing condition unchanged from the reopen comment: a many-spool-file job reads
back, or fails with a status code rather than an abend.

### 2 · #214 — concurrent issue-command requests pick up each other's lines

*the worst live symptom: one client is served another client's data*

Every worker shares one MTT source, so `has_src` cannot separate two concurrent
requests. Second symptom, same cause: a `MODIFY` reply burns the whole
`POLL_SECONDS` window because foreign lines keep the block's line count moving.

**First step is asking whether #195 is this**, not opening two hunts. #195 is not
monotonic in load (0 → detected, 5 → waiting, 20 → detected), which fits
contamination better than a race. A `/zosmf/test` diagnostic reporting cursor
position and entries scanned likely settles both in one run.

### 3 · #267 — `unsigned rc` makes every send-error check dead code

`dsapi.c:1251` and `:2294`. A client that disconnects mid-listing has the whole
remaining directory written after it.

**The hazard is that this is not the one-word edit it looks like.** `unsigned` →
`int` *activates* every `goto quit` for the first time; read the `quit:` cleanup
in that light before flipping it. `member_scan()` (#265) is the only place in the
member listing that detects a write failure today, and is the worked example.
Grep the other handlers in the same pass — the declaration is copied around.

### 4 · #336 — `{volume-serial}` is captured and never used

Seven routes accept `-(VOLSER)` and discard the operand; a request naming the
wrong volume is answered as if it had named the right one. Ranked here because
the answer looks correct.

The two resolutions differ by an order of magnitude: wire the volser through to
`__dscbdv()`/OPEN, or reject the seven routes. **The rejection is nearly free** and
worth taking even as an interim.

---

## Tier 2 — cheap and client-visible

### 5 · #210 — the submit response returns `owner:""`

A race, not a divergent path — and therefore **not fixable by asking libc370
earlier**: `JCTUSEID` is unwritten and the internal text is not on the spool yet.
mvsMF already knows the answer, because `process_jobcard()` injected `USER=`.
Fall back to that. Check the purge handler (`jobsapi.c:363,375`) for the same
emptiness, and make `tests/curl-jobs.sh` assert the value, not the key.

### 6 · #251 — console log answers 200 with an empty body on allocation failure

`consapi.c:1100` collapses a NULL `cmtt_new()` into `n = 0`. The MTT copy is the
largest allocation on that path — the one most likely to fail exactly when a
silent empty answer misleads most. The sibling `malloc()` three lines below
already returns 500. Textbook **Optimistic Path**; check `:266` and `:457` too.

### 7 · #209 — `exec-system` and `exec-member` are never emitted

3.8j has no sysplex, so `CVTSNAME` is a correct constant answer and needs no
libc370 change. `JCTRDSID` is right in principle and re-opens the relink chain
(`libc370#79`) for no gain here. Take the cheap one deliberately, and say so in
the code.

### 8 · #245 — `X-IBM-Data-Type: record` cannot be written back

The read path length-prefixes each record; the write path sends `record` down the
*text* loop, so the four bytes read back as a length are a length only by accident.

**Correct `put.md` and `members-put.md` immediately, ahead of any other decision.**
Both advertise the mode without qualification today; that is what misleads right
now and it costs nothing to stop. Then choose: a length-prefixed reader (mind a
prefix split across a chunk boundary, and `record_content_max()`), or a 400.

### 9 · #326 — five sources missing from the CLAUDE.md list

`abendmsg.c`, `hostparse.c`, `jclines.c`, `reclines.c`, `spoolln.c`. The issue said
"next time `CLAUDE.md` is touched", so fold it into the next edit of that file
rather than spending a PR on it. Read each file rather than inferring from the name,
which is how the list drifted in the first place.

---

## Tier 3 — correctness, needs care

### 10 · #76 — DSORG=DA in `datasetPutHandler` via BDAM

*the only defect on this list someone outside the project reported*

A ufsd image upload `SD37`s because QSAM extends past the primary allocation on a
DA data set. Detect `DSGDA` from the DSCB — the list handler already does — and
switch to the `osd*` BDAM API for PUT and GET.

Ranked above the two unobserved defects below it deliberately. This file orders by
impact on running systems, not by age or effort, and #76 is the one item here that
is observed, reported from outside, and blocking a real workflow; #244 is currently
harmless and #215 has never been seen at all. What holds it out of Tier 1 is that
`ufsd-utils upload` does the job today — a workaround, not an absence of impact.

### 11 · #244 — `#define VARIABLE 0x0002` is the wrong RECFM mask

**The ordering constraint is the whole content of this ticket.** The broken mask
is the only thing keeping `write_record()`'s manual RDW dormant, and that RDW is
itself wrong — libc370's `varflush()` already builds one. Correcting the mask
alone ships **two** RDWs. Remove the manual RDW first, then fix the mask. Drop
`FIXED`/`UNDEFINED` in the same edit: wrong the same way, and unused.

The regression test wants a **VB** data set written binary and read back with
lengths checked — `curl-binary.sh` uses FB, which is why this survived.

### 12 · #215 — `addJsonStringEsc()` escapes five characters, not the control range

One raw control byte makes the **whole** response unparseable, and `consapi.c`
passes Master Trace Table text — whatever any address space wrote to the console.
Honest scope, per the issue: **no observed failure**. #212 fixed this locally in
`dsapi.c` to keep that PR narrow; a fix here lets that copy go.

The subtlety from #212, easy to lose: `http_printf()` translates on the way out,
so the printability test applies to the **translated** byte, via `xlate_cp037`.

### 13 · #257 + #335 — early 4xx on a PUT with a body still in flight

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

### 14 · #234 — what should the API do with non-ASCII input?

Byte-wise through CP037 with no UTF-8 decoding — and **invisible through the API**,
because `etoa` inverts `atoe`, so only ISPF and the program reading the member see
it. One case is worse: any sequence containing `0x85` becomes `0x15`, which
libc370's `__fputc` treats as a record terminator, so the line splits and the byte
is dropped — **with HTTP 204**. Four ecosystem `samplib` members carry UTF-8 today.

Research because the policy is the hard part. Measure the reference first
(`--zosmf-p zxp`, read-only) — it has `fileEncoding=` controls the clone does not.
`xmit370`'s split between well-formed UTF-8 and Latin-1 is worth borrowing. Decide
GET and PUT together; a reject changes the round-trip property.

### 15 · #329 — dataset create is authorized only by the ambient ACEE

**The endpoint is not unauthorized and the response shape is settled** (#315,
#317): RAKF refuses the allocation and the refusal must stay indistinguishable
from any other dynalloc failure. *Do not add an authorization body here.* What is
open is only **which identity decides** — SVC 99 runs under whatever sits in
`ASXBSENV`, the last ambient dependency left after #228.

The cheap unblocked step is a measurement, and it decides whether the fix exists
at all: what does RACHECK answer for a name with no catalog entry and no DSCB?

### 16 · #345 — restjobs has no authorization model

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

---

## Tier 5 — larger work

### 17 · #291 — large bodies fully buffered, twice on submit

**Reclassify: memory hygiene, not stability.** Its motivation — stopping long-held
requests acting as the anvil for httpd#195's fragmentation — is gone: #287 closed,
httpd#195 closed, and `__stklen` (#290) cut mvsMF's demand from 262328 to 65584
bytes, which fits every hole that mechanism produced.

What survives is worth doing on a 24-bit target anyway. Start with
`jobsapi.c:2061` — a full-size EBCDIC copy beside the raw body, so a 1 MB submit
holds 2 MB. Cheapest item, and independent of the streaming work.

**`receive_raw_data()` stays byte-at-a-time** (PR #22 / #42, the TCP ring-buffer
bug). Streaming changes what we do with the bytes, not how they are read.

### 18 · #186 — console log: deep history beyond the MTT window

**No longer blocked — the issue text says it is, and that is out of date.** Its
hard dependency `libc370#21` is **closed and verified on target** (PR#31,
`JOB00321`): `jesprint()` now names why it stopped, so the endpoint can finally
tell "gone" from "empty". `libc370#30` (PSO/SSI instead of the checkpointed IOT)
was only ever the *nicer* route and is still open — it is not a gate. What this
needs to start is a sysroot refresh, the same one #282 needs.

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

- **#248** — the ussapi statuses outside the z/OSMF list. Landed in `3de44a0`
  (2026-08-16) plus `14302da` for ROFS (#250); the commit never named the issue,
  which is the only reason it stayed open for a week. Re-verified against `main`
  before closing.
- **#323** — in-stream data in the JESJCLIN listing: closed on **option A**, client
  side. z/OSMF does not serve JESJCLIN at all, so no reference behaviour exists to
  match and every server-side variant is an extension. The rule the frontend needs
  is in the closing comment: match in-stream data to spool files **by ddname, never
  by position**.

## Campaigns, not eighteen tickets

- **Console correctness** — #214, #195, #251. One subsystem, one reading of
  `consapi.c`, and #195 may not survive the first measurement of #214.
- **The endpoint advertises what it does not do** — #245 and #336, with #248 as
  the worked example of how it ends. The doc half of #245 and the reject half of
  #336 are both nearly free and both stop the lying today, ahead of whichever
  implementation decision follows.
- **Checked, then swallowed** — #267, #251, #215. The same `CLAUDE.md` stop pattern
  in three subsystems: the return code is inspected and the failure goes nowhere.
  One convention, not three decisions.
- **The authorization endgame** — #329, #345, with `httpd#176` behind them. Two
  measurements and one policy; no code for either before both are recorded.

## Cross-repo

mvsMF-only. Do not rank these here — update them where they live.

Still open and ours to wait on — all three verified 2026-08-23: `libc370#79`
(`exec-submitted`, and the accurate answer for #209), `libc370#30` (the nicer route
for #186, not a gate for it), `httpd#176` (`blocked:rakf`), and `ftpd#90` (decide
with #345).

Landed upstream, not yet cashed in here — **and this is the single highest-value
thing on the list, because one sysroot rebuild cashes in all five at once**:
`libc370#21` (unblocks #186), `#126` (the `process_intxt()` walk behind #282),
`#127`, `#128` and `#131` — which between them closed the ENQ escalation from #342
and made `make test-mvs` complete for the first time (508/0). None of them arrive
via `make deps`: libc370 is the cc370 sysroot, not a declared dependency.
