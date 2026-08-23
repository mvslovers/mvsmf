# mvsMF — Open Work, Ranked

**State lives on GitHub, not here.** `gh issue list --repo mvslovers/mvsmf` is
the source of truth for what is open. What this file adds is the part the tracker
cannot hold: the **order**, the reason for it, which items are a decision rather
than code, and the per-issue hazard that makes an obvious-looking fix not one.

**It carries nothing that is copied.** Where the reasoning already has an owner —
the issue thread, the PR, `docs/uss-spec.md` — this file points at it and stops.

*Last reconciled against the tracker: 2026-08-23, 20 issues open — nineteen
entries below, because one of them pairs two issues.*

---

## The order

| | Issue | Kind | Waiting on |
|---|---|---|---|
| 1 | #214 | wrong data reaches a client — reproduced | a decision on serializing |
| 2 | #346 | silently incomplete, single client, observed | a decision on the contract |
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
| 17 | #195 | split from #214 — not the same bug | one two-snapshot measurement |
| 18 | #291 | reclassified — hygiene, not stability | nothing |
| 19 | #186 | unblocked; sysroot refreshed 2026-08-23 | nothing |

---

## Tier 1 — now

### 1 · #214 — concurrent issue-command requests pick up each other's lines

*the worst live symptom: one client is served another client's data*

Every worker shares one MTT source, so `has_src` cannot separate two concurrent
requests. Second symptom, same cause: a `MODIFY` reply burns the whole
`POLL_SECONDS` window because foreign lines keep the block's line count moving.

**Reproduced and measured on 2026-08-23** — recipe, numbers and the raw MTT
window are in the issue. Two background clients looping `F HTTPD,D P` against
twelve foreground `D T`: **5/12 contaminated, up to 30 foreign lines, 2.39 s
against a 0.39 s baseline**. Both symptoms are one mechanism — the worst
contaminated response is also the slowest.

**Two of the issue's three directions are refuted by that data, including its
preferred one.** MVS interleaves the MTT *line by line*, not block by block: a
foreign echo lands between our echo and our own reply, in the same second. So a
time bound cannot cut it (the MTT is second-granular), and echo-stopping either
loses our own reply or — in the obvious `line_idx == 0` repair — still appends
the foreign reply lines, which share our source. **Serializing is the only one
of the three left standing**, and the decision to take is whether its cost is
acceptable: the lock must span MGCR through convergence, so the 2.1–3.1 s poll
window becomes the throughput ceiling, and it reduces rather than eliminates —
httpd's own WTOs carry the same source and still land inside an open block.

**Do not gate that decision on reading the MTT entry header.** `mtenttag` /
`mtentimm` have never been looked at, but `issue_command()` leaves the SVC 34
buffer's bytes 2–3 zero for every worker, so any caller identity MVS records
reads identically for two workers in one address space. Worth a probe run for
the record; it is not a blocker.

**Two further defects on the same path, neither addressed by any of the three
options** — fold them into whatever fix lands. `correlate_once()` anchors on the
*newest* `strstr` match over the whole table, and `consoleCollectHandler()`
re-anchors on every poll, so `cur.delivered` is counted against a block that may
have moved (`SOL_CURSOR.issue_tod` is stored, unused, and its comment already
says "reserved: re-issue disamb."). And #174's `d <= 1` adoption window does not
merely append a stray line under concurrency — it **redirects the whole block**
to another address space, which is strictly worse than the reported symptom.

### 2 · #346 — the sync capture converges on 0.3 s of quiet and truncates

*observed by the maintainer, single client, HTTP 200 with four of five lines
missing and nothing saying so*

`P FTPD` returns `FTPD098I` alone; `FTPD099I`, `IEF404I` and `$HASP395` are
dropped. `S FTPD`, issued seconds later, is complete. The whole difference is in
the MTT timestamps — `S FTPD`'s reply lands inside one second, `P FTPD` pauses
2 s in the middle, and `capture_response()` breaks after the line count has been
unchanged for three 0.10 s polls.

**Same function as #214, opposite failure, no shared fix.** #214 needs two
clients and delivers *foreign* lines; this needs one client and drops *own*
lines. Do not fold them together — #214 is held on a serialization decision that
has no bearing here.

**The hazard is that lengthening the quiet window looks like the fix and is
not.** Two limits stack: `POLL_SECONDS` is 3 and `tod_hi()`'s LSB is ~1.05 s, so
the hard cap is 2.1–3.1 s and `P FTPD`'s last line arrives at 3 s. Anything
slower is truncated however patient the convergence rule gets. The real choice
is in the issue, and one of the four options is that this is **by design** —
collect already returns the later lines, and real z/OSMF treats `cmd-response`
as "what was available". If that is the answer, the defect is that the sync
reply gives the client no way to know it is incomplete, and the work is a
contract plus a marker, not a longer timer.

Regression test wants a command with a known multi-second gap and an assertion
on the **last** expected line. `tests/curl-console.sh` uses `D T`, `D A,L` and
`F HTTPD,D P` — all sub-second — and its opt-in `P FTPD`/`S FTPD` block asserts
only the detection status, never the completeness of `cmd-response`.

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

### 17 · #195 — detections intermittently report `waiting` for a message that was emitted

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

### 18 · #291 — large bodies fully buffered, twice on submit

**Reclassify: memory hygiene, not stability.** Its motivation — stopping long-held
requests acting as the anvil for httpd#195's fragmentation — is gone: #287 closed,
httpd#195 closed, and `__stklen` (#290) cut mvsMF's demand from 262328 to 65584
bytes, which fits every hole that mechanism produced.

What survives is worth doing on a 24-bit target anyway. Start with
`jobsapi.c:2061` — a full-size EBCDIC copy beside the raw body, so a 1 MB submit
holds 2 MB. Cheapest item, and independent of the streaming work.

**`receive_raw_data()` stays byte-at-a-time** (PR #22 / #42, the TCP ring-buffer
bug). Streaming changes what we do with the bytes, not how they are read.

### 19 · #186 — console log: deep history beyond the MTT window

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

## Campaigns, not nineteen tickets

- **Console correctness** — #214, #346, #251, and #195 behind them. One
  subsystem and one reading of `consapi.c`, but **four separate bugs**: #214 and
  #195 were ranked together on the guess that #195 might not survive the first
  measurement of #214, and that premise is dead — see #195's entry. #214 and
  #346 are the two halves of "MVS gives no end-of-response signal, so both ends
  of the block are guessed", and they fail in opposite directions from opposite
  preconditions. #251 is independent of all three.
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
