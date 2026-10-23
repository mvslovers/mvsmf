# mvsMF — Open Work, Ranked

**State lives on GitHub, not here.** `gh issue list --repo mvslovers/mvsmf` is
the source of truth for what is open. What this file adds is the part the tracker
cannot hold: the **order**, the reason for it, which items are a decision rather
than code, and the per-issue hazard that makes an obvious-looking fix not one.

**It carries nothing that is copied.** Where the reasoning already has an owner —
the issue thread, the PR, `internals/uss-spec.md` — this file points at it and stops.

*Last reconciled against the tracker: 2026-09-06 after the **1.0.0 release**,
20 issues open — fourteen entries below: one pairs two issues, one is a **block
of three** (#244 → #361 → #245, entry 4), and **#360 and #363 are not ranked
yet** — `errno` unread after a NULL from `__listpd()`/`__listds()`, and the
unguarded `http_realm()` call that abends the CGI on a pre-4.0.1 httpd. Both
need a place in the order; #363 is the lower of the two, since no maintained
stand runs a server that old. ~~**#398 is new (2026-10-10) and not ranked
either**: `P HTTPD` through the console API answers 503 with an empty body, so
a client cannot tell whether the command ran.~~ Fixed: `send_bytes()` refused
every send once the server quiesced, the 8/15 report's body included.
**#405 is new (2026-10-13) and not ranked either**: run right after
`curl-nospace`, `curl-datasets` hangs on its first sequential read, and the
data set stays allocated until HTTPD restarts. 2 of 2 on mvsdev on 2026-10-12,
0 of 3 on 2026-10-13, on libc370 2.10.2 and 2.10.3 alike (comments on #405);
the cause is open. ~~**#407 is new (2026-10-13) and not ranked either**: the two
other MTT snapshot sites behind #251 (fixed in PR #408) read a failed snapshot as no matches — a
false `detected`, and #214's mis-anchor reopened.~~ Fixed in PR #470.
**#417 and #418 are new (2026-10-13) and not ranked either**, both from a
client on m38b: `PUT /restjobs/jobs/{name}/{id}` with `request: cancel|hold|release`
is not implemented and answers 404 (a hung job had to be `$C`'d from the
console). #417 is cancel only, `jescanj(…, 0)`; hold/release split out as
**#424**, blocked on **libc370#529** (`jeshold()`/`jesrels()`: `$H`/`$A J` via
SVC 34, verified against the JQE hold bit). Cancel takes the purge rule of #440 (UPDATE on the JESSPOOL entity). #418 is the 404 itself: a known path with an unregistered method should
perhaps be 405 — measure the reference first.
**#423** (USS file GET: no `ufs_ferror()` check after the read loop) is fixed in
its PR: the loop is `src/ussread.c` (host test `TSTUSSRD`), the failure is
`MVSMF301E` plus `abort_response()`. A mid-file UFSD read error *can* be
provoked: a client that stops reading holds the handler in `send_all()`
between two reads, and `P UFSD` then fails the next `ufs_fread()` (`RC=-1`).
**#425 is new (2026-10-14) and not ranked either**: S0C7/S0C1 *at function
entries* -- the loaded MVSMF code was overwritten (m38b dump: the 6-byte
instruction executed at `find_and_send_job_status`'s entry is not the linked
`B 30(0,15)`). On the TK5 stands the STEPLIB is not APF, so MVSMF sits in
key-8 storage and a stray store lands in the code silently (measured, probe on
m38r). About 1 in 1,900 status polls on m38r; on m38b the server hung
afterwards (four workers would not stop, `SA03`). **PR #427** (merged
2026-10-14) added `MVSMF913I`, the PSW and R14 of every caught abend as
entry-point offsets (libc370 2.11.0 `tryinfo()`), and `MVSMF914I`, the bytes
around the instruction; the writer itself is still unknown. Re-reading
never-opened data sets (740 read errors on m38b) did not reproduce it on dev1
or m38r; the open lead is uptime -- both real hits came from an HTTPD running
since the previous day. **PR #429** (merged 2026-10-14) added `fn=textsum` /
`fn=textdump` and measured that MVS deletes MVSMF whenever its use count drops
to 0: every request after an idle gap fetches a fresh copy, so a damaged copy
lives only while requests overlap and the writer runs concurrently. The S0C7
(ILC 3) means the overwrite started with X'F8'-X'FD' or X'DE'/X'DF' -- EBCDIC
digits or packed data, not an ECB POST. m38r carries `99a423c` with
`MVSMF914I` armed, deliberately without a pinned LOAD. Pinning registered
modules in httpd (program fetch per request, region fragmentation) goes to
httpd.
**#428 is new (2026-10-14) and not ranked either**: a ~20 MB binary PUT
(`mbt deploy`) on m38b ended `MVSMF007W` -- no body byte for 10 s, the client
got EPIPE. Neither mbt nor Hercules' X'75' RECV path holds data back (both
read), and 6 + 6 such PUTs on m38r and m38b ran clean with the host's Recv-Q
never empty. Not reproduced; if it recurs, `ss -tnio` on the host while it
hangs separates the emulator from the sender.
**#430 closed 2026-10-15** (PR #431): every CGI request cost about 137 bytes
of subpool 0 for good, because libc370 up to 2.12.0 never freed the CRT block
(`libc370#546`). It sits in each module's own runtime, so MVSMF had to be
relinked against 2.12.1. On m38r, MVSMF `ed8e981`: 900 x `fn=version`, delta 0
(was -40,960 per 300); HTTPDM, still on 2.12.0, kept leaking in the same window.
Still open: the mixed-load runs read 111-165 B/req against 128 -- the long-term
run on m38b after the 1.3.0 rollout shows whether anything remains.
**mvsMF 1.3.0 released 2026-10-15** -- tag `v1.3.0` (`d454edf`), FMID
`TZMF130` deleting `TZMF120`, built against libc370 2.12.1, httpd 4.2.0, ufsd
1.4.0, crypto370 1.0.1 (#432/PR #433). `main` is `1.4.0-dev` (`TZMF140`).
`inst.jcl` read: `++VER(Z038) DELETE(TZMF120)`, ACCEPT `COND=(4,LT,APPLY)`.
Smoke run on dev1 with `d0bb975` (same code): curl-datasets/-jobs/-uss/-console,
`auth` and `info-cookie` all passed. Installed 2026-10-15 by MBT, HTTPD 4.3.0
first and HTTPD stopped around both installs: m38r JOB00892, m38l 1709, m38x
630, m38b 1518 (each `HMA2380` for MVSMF, APPLY RC 04 on `HMA2461 TZMF120`,
`fn=version` 1.3.0). On m38r the #425 debug wiring is gone (`MVSMF.DEV.LINKLIB`
out of the STEPLIB and scratched, `/.dm` out of HTTPPRM0). The long-term run on
m38b with pl1c370's load started the same day.
**PR #435, merged 2026-10-15** -- #434: the installation guide's Upgrading
section says stop HTTPD, run the install job, start HTTPD. An APPLY into
`MVSMF.LINKLIB` under a running server was never measured; the v1.3.0 release
page and the stand rollout already do it that way. Docs only.
**1.4.0 release mechanics (#450), prepared 2026-10-23**: FMID `TZMF140`
(deleting `TZMF130`) in README, installation guide and uninstall job; the
CHANGELOG section `[1.4.0] - unreleased` (date goes in with the tag; "Built
against" follows the final pins). `mbt package` on a throwaway tree with a local
`1.4.0` bump: `inst.jcl` reads `++FUNCTION(TZMF140)`, `++VER(Z038)
DELETE(TZMF130)`, ACCEPT `COND=(4,LT,APPLY)`. Not yet `LIST`-checked on any
stand. Open before the last pass: #372, #425, #428, #452, #453, #454, #449.
**#426 is done in its PR**: a purge JES2 only accepts (output held on a device)
stays 200 with `status: 0`, and `message` now says the purge is only requested
(`internals/zosmf-conformance.md`). What zxp answers for such a purge is not
measured (a write); `X-IBM-Job-Modify-Version: 2.0` is not implemented.
**#360 is handled in the libc370 2.25.1 move (#442)**: the `ENOMEM` contract
(2.0.0) is read in `datasetListHandler()` and `diagnose_open_failure()`, so a
shortage is a 500 with `MVSMF006E`, no longer an empty 200 or a 404. The
`__listds()` half never needed `libc370#157` for that: NULL with `ENOMEM` was
already there. The unreachable path is untested on MVS (`fn=listds` reports it
as `"nomem"`). #360 stays open until a shortage has been provoked on MVS. #361 is new (2026-09-06) and moved
#245 down: they are one subsystem and must be done in sequence. **Tier 1 is
empty again** — #406 landed in PR #409 and #371 in PR #403, both on
2026-10-13, and before them #336's
reject half in PR #358, #210 in PR #359, and #362 and #357 in PR #364.*

**State of play, 2026-10-15** (one mvsMF session from here on; the second one
handed its list over). In hand, in this order:
- **#345 is superseded by #440** (the JESSPOOL model, as in FTPD 1.3.0;
  `docs/jesspool.md`): implemented on `issue-440-jesspool`, in review. Close #345
  with it.
- **#417** (cancel) right after #440 -- it widens the same gap and takes the
  purge rule (UPDATE on the JESSPOOL entity).
- **#418** waits on a read-only zxp measurement (404 or 405 for a known path
  with an unregistered method).
- **#424** is blocked on `libc370#529` (still open; `jeshold()`/`jesrels()` are not in 2.25.1).
- **#443** is new (2026-10-22, found in #442): the listing's `dev` names a 3380 volume "3390".

Passive: **#425** (MVSMF913I/914I and `fn=textsum` ship in 1.3.0, which runs
on all four M38 stands since 2026-10-15),
**#428** (not reproduced: 12 clean 20 MB PUTs on m38r and m38b; plic370 reports
the next case).

---

## The order

| | Issue | Kind | Waiting on |
|---|---|---|---|
| 1 | ~~#209~~ | fixed in PR #482, merged | — |
| 2 | ~~#326~~ | fixed in the PR for #326, awaiting merge | — |
| 3 | #76 | the one externally reported defect | nothing |
| 4 | #244 → #361 → #245 | **one block, strict order** | #245 alone: reader-vs-400 decision |
| 5 | ~~#215~~ | fixed in the PR for #215, awaiting merge | — |
| 6 | #257, #335 | one class, two tickets | a repro without a proxy |
| 7 | #347 | an authenticated user can stop the system | **who** is gated in review (fail-closed check in the handlers, `FACILITY MVSMF.CONSOLE`, console and `/zosmf/test`; #460); **which commands** stays a policy — measured, nothing to delegate to |
| 8 | #234 | `type:research` | measuring the reference |
| 9 | #329 | `type:research` | **one measurement** — see *RAKF* |
| 10 | #345 | superseded by #440 | done with #440 (in review); #417 cancel follows |
| 11 | #195 | split from #214 — not the same bug | one two-snapshot measurement |
| 12 | #291 | reclassified — hygiene, not stability | nothing |
| 13 | #186 | unblocked; sysroot refreshed 2026-08-23 | nothing |
| 14 | #336 | routes withdrawn; now a feature request | nothing: `libc370#143` is in libc370 2.24.0 (`__scratch()`/`__renamev()`) |

---

## Tier 1 — now

**Empty.** #406 was its only entry and landed in PR #409, and #412 landed in
PR #413 the same day (see *Recently closed*). The top of the queue is Tier 3's
#76.

---

## Tier 2 — cheap and client-visible

### 1 · ~~#209~~ — `exec-system` and `exec-member` are never emitted

Fixed in PR #482 (merged): both fields carry `JESJOB.sysid`
(`JCTRDSID`), measured equal to `__smfid()`. `exec-submitted` is split out as
#481 (libc370#79 is delivered; `JESJOB.submit_time64`).

### 2 · ~~#326~~ — five sources missing from the CLAUDE.md list

Fixed in the PR for #326: `abendmsg.c`, `hostparse.c`, `jclines.c`, `reclines.c` and
`spoolln.c` are in the Key Source Files list, each written from the source and its callers.

---

## Tier 3 — correctness, needs care

### 3 · #76 — DSORG=DA in `datasetPutHandler` via BDAM

*the only defect on this list someone outside the project reported*

A ufsd image upload `SD37`s because QSAM extends past the primary allocation on a
DA data set. Detect `DSGDA` from the DSCB — the list handler already does — and
switch to the `osd*` BDAM API for PUT and GET.

Ranked above the two unobserved entries below it deliberately. This file orders by
impact on running systems, not by age or effort, and #76 is the one item here that
is observed, reported from outside, and blocking a real workflow; the RECFM=V block
is a measured deviation nobody has reported and #215 has never been seen at all.
What holds it out of Tier 1 is that `ufsd-utils upload` does the job today — a
workaround, not an absence of impact.

### 4 · #244 → #361 → #245 — the RECFM=V block, in that order

*three tickets, one subsystem; the order is a constraint, not a preference*

**#244 first — it is what makes the other two safe.** The broken mask
`#define VARIABLE 0x0002` is the only thing keeping `write_record()`'s manual RDW
dormant, and that RDW is itself wrong: libc370's `varflush()` already builds one.
Correcting the mask alone ships **two**. Remove the manual RDW, then fix the mask,
and drop `FIXED`/`UNDEFINED` in the same edit — wrong the same way, and unused.

Two things the ticket text does not name, both added as a comment on 2026-09-06
and both part of the same edit. The **binary write path survives the stated fix**:
it splits the body on `eff_lrecl` = LRECL while libc370 sizes a V write buffer at
LRECL-4, so a VB/4004 chunk lands as a 4000-byte record *plus* a 4-byte one, with
NUL padding on the tail; `record_content_max()` already holds the right number and
the binary path is its one non-caller. And the `is_fixed` half is **lossy, not
merely inaccurate** — a VB record's trailing blanks are data, and the text round
trip drops them.

**#361 second — the only one of the three with a measured target.** Record mode on
a V data set emits LRECL-sized chunks of concatenated record data, prefixed with
the chunk size: `fread()` on a byte-mode stream runs straight across the record
boundaries that `__fgetc()` has already dissolved. The contract to hit was measured
against z/OSMF 29 on 2026-09-06 (`SYS1.ADFQPSRC(DFQDCAGA)`, VB/255): one 4-byte
big-endian length per **logical** record, the data length without the RDW, nothing
padded, the prefixes tiling the response exactly — and the same resource in binary
mode is those bytes with the prefixes removed, byte for byte.

Until then the read is refused (#455, 400, category 6, reason 12, in
`read_and_send_dataset()`): record mode on a V data set no longer returns data.
#361 replaces that refusal with the real thing; its tests are the VB cases in
`curl-binary.sh` and `zowe-binary.sh`, which expect the 400 today.

That second half matters as much as the first: **binary mode on a V data set is not
a bug.** The reference concatenates there too, exactly as we do. It looks like the
same defect and is not, so do not "fix" it.

The fix is a `",record"` open, which hands back one raw record per `__fread()` —
and libc370's BSAM read reassembles spanned records itself, so V, VB and **VBS**
all arrive whole. That is what makes this the one entry here with a use case
outside conformance: a RECFM=VBS SMF dump to a host, untranslated and with
boundaries intact, which today needs an AWS tape or a punch deck.

**#245 last — a decision, and the only part of the block that is not code.** A
length-prefixed reader on the write side, or a 400. Its doc half is already done
(PR #349, three places, not the two the issue names — grep before trusting an
issue's list of sites), so nothing misleads a client while the decision waits.
Taking option 1 before #361 means round-tripping against a producer known to be
wrong; option 2 is unaffected by the other two and can be taken at any time.

The regression tests are the same shape for all three and are missing today
(`curl-binary.sh` is FB only): a **VB** data set with records of *differing*
lengths, written binary, read back in record mode, prefixes walked against a
binary read of the same resource. Records of one uniform length pass while proving
nothing — the first two members measured on the reference were compiled REXX at a
flat 251 bytes, which is indistinguishable from LRECL-4 chunking.

Ranked below #76 for the same reason #244 alone was: nobody has reported any of
it, and nobody sends `X-IBM-Data-Type: record` at a V data set today either. It
keeps #244's old slot above #215 because it is where #244 already sat and the
three are one edit's worth of context — not on impact, where #215's unparseable
response reaches every `consapi.c` caller and this reaches none.

### 5 · ~~#215~~ — `addJsonStringEsc()` escapes five characters, not the control range

**Fixed on `issue-215-json-control-chars`, awaiting merge:** one shared
`append_quoted()` in `json.c` serves `addJsonStringEsc()` and
`addJsonArrayString()`; every byte below `' '` is escaped (short form for
`\b \f \n \r \t`, else `\u00XX`), tested by `TSTJSON`. The entry below is kept
for the one point the fix did not take over: `dsapi.c`'s `json_escape_member()`
still has its own copy, because it names the *translated* byte in the escape.

One raw control byte makes the **whole** response unparseable, and `consapi.c`
passes Master Trace Table text — whatever any address space wrote to the console.
Honest scope, per the issue: **no observed failure**. #212 fixed this locally in
`dsapi.c` to keep that PR narrow; a fix here lets that copy go.

The subtlety from #212, easy to lose: `http_printf()` translates on the way out,
so the printability test applies to the **translated** byte, via `xlate_cp037`.

### 6 · #257 + #335 — early 4xx on a PUT with a body still in flight

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

### 7 · #347 — restconsoles authorizes nothing at all

*an authenticated user can stop the system*

**Status, 2026-10-23: the gate on *who* is in review.** Every console handler
and both `/zosmf/test` handlers start with `console_authorize()`
(`consauth.c`): READ on `FACILITY MVSMF.CONSOLE`, fail-closed (no profile, no
READ, no ACEE: refused), the decision in `authdec.c`, host test
`tstauthd.c`, MVS matrix `tests/curl-consgate.sh` (#460). The httpd route
(httpd#335) stays as an extra first layer. Docs: `docs/installation.md`, *Who
may use the console service and `/zosmf/test`*; `internals/authorization.md`.
The endpoint is not registered in a release build, and no function of it returns
session data (#508). What stays open: a **per-command policy** (below, unchanged). The text below is
the analysis that led here; its `grep` count is of the state before the check.

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

### 8 · #234 — what should the API do with non-ASCII input?

Byte-wise through CP037 with no UTF-8 decoding — and **invisible through the API**,
because `etoa` inverts `atoe`, so only ISPF and the program reading the member see
it. One case is worse: any sequence containing `0x85` becomes `0x15`, which
libc370's `__fputc` treats as a record terminator, so the line splits and the byte
is dropped — **with HTTP 204**. Four ecosystem `samplib` members carry UTF-8 today.

Research because the policy is the hard part. Measure the reference first
(`--zosmf-p zxp`, read-only). The EBCDIC side of the choice exists since #391
and #393 (`X-IBM-Data-Type: text;fileEncoding=`, IBM-037 / IBM-1047 on data
sets and USS files; jobs still have none); what is still uninterpreted is the
ASCII side, `Content-Type: …;charset=`.
`xmit370`'s split between well-formed UTF-8 and Latin-1 is worth borrowing. Decide
GET and PUT together; a reject changes the round-trip property.

### 9 · #329 — dataset create is authorized only by the ambient ACEE

**The endpoint is not unauthorized and the response shape is settled** (#315,
#317): RAKF refuses the allocation and the refusal must stay indistinguishable
from any other dynalloc failure. *Do not add an authorization body here.* What is
open is only **which identity decides** — SVC 99 runs under whatever sits in
`ASXBSENV`, the last ambient dependency left after #228.

The cheap unblocked step is a measurement, and it decides whether the fix exists
at all: what does RACHECK answer for a name with no catalog entry and no DSCB?

### 10 · #345 — restjobs has no authorization model

**Superseded by #440** (the JESSPOOL model as FTPD 1.3.0 has it): own jobs
always, foreign jobs by RACHECK in class JESSPOOL, hidden = 404, READ lists and
reads, UPDATE purges. The text below is the history. Still open from it:
`fn=mtt` and the console API read the Master Trace Table, a separate surface.

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

### 11 · #195 — detections intermittently report `waiting` for a message that was emitted

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

### 12 · #291 — large bodies fully buffered, twice on submit

**Reclassify: memory hygiene, not stability.** Its motivation — stopping long-held
requests acting as the anvil for httpd#195's fragmentation — is gone: #287 closed,
httpd#195 closed, and `__stklen` (#290) cut mvsMF's demand from 262328 to 65584
bytes, which fits every hole that mechanism produced.

What survives is worth doing on a 24-bit target anyway. Two of the issue's
four sites are gone since PR #413 (#412): `read_request_content()` allocates a
`Content-Length` body once instead of doubling, and the submit translates the
JCL in place instead of holding a second copy. Left: streaming PUT bodies into
their target instead of buffering them whole, and the JSON builder.

**`receive_raw_data()` stays byte-at-a-time** (PR #22 / #42, the TCP ring-buffer
bug). Streaming changes what we do with the bytes, not how they are read.

### 13 · #186 — console log: deep history beyond the MTT window

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

### 14 · #336 — `-({volume-serial})` addressing, now a feature rather than a lie

**The routes are gone (PR #358), so this no longer misleads anyone** — that is
the whole reason it fell from rank 1 to last. Until then seven routes accepted
`-(VOLSER)`, discarded the operand and answered a wrong volume as if it were
right. They are withdrawn, not commented out: `{dataset-name}` stops at `/`,
`(` and `)` in `is_pattern_match()`, so the form reaches the router's own 404
and cannot be served as a data set literally named `-(VOL)`.

Ranked here rather than dropped because the capability is real and half of it
is already sitting in libc370:

- **Read and write need nothing new.** `__dsalc` parses `VOLSER=` and emits
  DALVLSER via `__txvols()`; `fopen("DD:ddname")` and `"DD:ddname(MEMBER)"`
  open the result; `__dscbdv(dsn, vol, &dscb)` always took a volume — mvsMF
  merely feeds it `__locate()`'s answer. Roughly six `fopen()` call sites.
- **DELETE and rename cannot be expressed at all.** `remove()`/`rename()` go
  through IDCAMS DELETE/ALTER, i.e. the catalog, and ALTER operates on catalog
  entries — an uncataloged rename has no spelling. That is **`libc370#143`**
  (volume-addressed SCRATCH/RENAME). Reaching for IDCAMS instead walks back
  into #342's SYSDSN ENQ escalation, which is why `__delmem()` is a
  STOW-under-SHR path in the first place.

Two things to carry into any attempt. `__dsalc` is verified to **parse**
`VOLSER=`, not that SVC 99 **accepts** DALVLSER without DALUNIT for an
uncataloged data set — the JCL rule says the pair is required, dynalloc may
differ, and `__listvl()` has the `cuu` if it does not. And the catalog-based
diagnosis (`why_open_failed()`, `dataset_cataloged()`) has to become
OBTAIN-by-volume on these routes, or an uncataloged data set comes back with
the wrong reason for its 404.

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

**PR #422, merged 2026-10-13** — #421: `abort_response()` cleared `keepalive`
but not `httpc->chunked`, so httpd's `httpdone()` closed a chunked data set GET
with a clean `0\r\n\r\n` after a read error — the truncated 200 #362 exists to
prevent. Found from a client's report on m38b (stale never-opened data sets,
`MVSMF106E` on the console, 200 at the client). Measured on mvsdev: before,
200 with an empty body and curl exit 0; after, curl exit 18; curl-datasets
313 → 314 of 314. The fixture is a label/block mismatch
(`tests/jcl/wronglen.jcl`), because a never-opened data set failed its read
only 1 of 2 times. Deployed on mvsdev as `d1e2e46`.

**PR #420, merged 2026-10-13** — #419, the installation guide after the 1.2.0
rollout to four stands: `VOLUME()` on both RECEIVEs on MVS/CE (generator side
is mbt#267), absolute links so the package README reaches `uninstall.md` and the
SYZJ201 section, and a section for systems coming from a hand-copied MVSMF —
including a non-SMP `HTTPD.LINKLIB` that has to be renamed aside (httpd#295).
Docs only.

**mvsMF 1.2.0 released 2026-10-13** — tag `v1.2.0` (`aeabef8`), FMID
`TZMF120` deleting `TZMF110`, built against libc370 2.10.3, httpd 4.2.0, ufsd
1.4.0 and crypto370 1.0.1 (PR #414 moved the floors off the prereleases).
`main` is `1.3.0-dev` (`TZMF130` by derivation). The dist's `inst.jcl` was
read: `++VER(Z038) DELETE(TZMF110)`, ACCEPT gated `COND=(4,LT,APPLY)`. Smoke
run on mvsdev with the release build: 665 of 665 across the four curl suites,
`auth` 21 of 21 and `info-cookie` 5 of 5. The stand installs (SMP) are MBT's
rollout; done for the two TK5 stands the same day, by SVC 244 with no APF
entry (#415/PR #416 made the guide say that is enough).

**PR #413, merged 2026-10-13** — #412, closed the same day after the re-check
on the stand that reported it (76–154 KB submits, all answered; HTTPD moved to
4.2.0 in the same cut-over, so which change removed it is open — see #412): a
`Content-Length` body was grown by doubling, so 72 KB asked for one 128 KB
block while holding 64 KB, and a failed read lost its answer to the reset that
closing a socket with unread data causes. The reader is `src/reqbody.c` now:
allocated once, drained before a 500 when there is no storage, 413 from 16 MB,
400 for a malformed length; the submit answers every failure and no longer
copies the JCL. TSTBODY red on the old algorithm, 51 of 51 on the new; on
mvsdev 665 of 665 across curl-jobs/-uss/-console/-datasets, and an 8 MB submit
(more than the largest free block) got its 500 after the full upload, with
one `MVSMF006E`.

**PR #409, merged 2026-10-13** — #406: a member PUT that ran out of space
answered 500 but still replaced the member, because libc370's CLOSE STOWed it
after the failed write: a new member stayed with no records, an existing one
was emptied. Fixed in libc370 2.10.3 (`libc370#524`, `DCBCNSTO` before the
CLOSE), which `mbt.toml` now pins. `curl-nospace.sh` section 5 was red on
2.10.2 and is 6 of 6 on 2.10.3; `curl-datasets` 313 of 313 after it.

**PR #411, merged 2026-10-13** — #410, the 1.2.0 preparation: the
`CHANGELOG.md` section, httpd 4.2.0 as the floor in the install guide and the
README (the token login needs HTTPX `0x144`, and nothing checks for it, #363),
and FMID `TZMF120` in the README. mbt 3 reads no `CHANGELOG.md`; the section
goes onto the release page by hand.

**PR #408, merged 2026-10-13** — #251: the hardcopy log answered a failed
MTT snapshot with 200 and no items. A missing array is 500 8/1 now, and an
empty window stays 200. The failure path cannot be provoked; on mvsdev,
`curl-console` passed 66 of 66 on the deployed build `58b4f9b`. The other two
snapshot sites went to #407.

**PR #470, open** — #407: `correlate_once()` and `detect_count()` read a failed
MTT snapshot as no matches — a false `detected` from a baseline of 0, and
collect re-anchored on the newest echo (#214 reopened). A failed snapshot is
`MTT_SNAP_FAILED` now: collect and detections answer 500 8/1, the issue command
500 8/14. The failure path cannot be provoked; `TSTMTSN` drives the real
snapshot and count against a failing `cmtt_new()`. Not run on MVS.

**PR #403 and PR #404, merged 2026-10-13** — #371: a PUT whose last, partial
block did not fit answered 204, because `session_fclose()` discarded the
`EOF`/`ENOSPC` that `fclose()` reports since `libc370#182`. It returns the
result now, and `close_write_target()` answers 500 and writes `MVSMF107E`.
`curl-nospace.sh` section 4 failed on mvsdev before the fix (195..199 records
answered 204 with 190 stored) and passes with it. The member-into-a-full-PDS
shape oftp370 reported has no test: a PDS filled by a failed PUT refused the
next small member on the unfixed build too, so that section was dropped.
Reproduced after the merge with a PDS filled by successful PUTs: the 500 is
right, and the member is replaced anyway — #406.
#402: the `dslevel` listing cut a name at its first hyphen; `libc370#519`,
fixed in 2.10.2, which `mbt.toml` now pins together with cc370 1.6.1. The
`curl-datasets.sh` section failed before (`IBMUSER.CURL.HY`) and passes after,
313 of 313. The same slot found #405.

**PR #377, merged 2026-09-30** — #376: an empty SYSOUT data set whose
unwritten first record JES2 had handed to the job's next data set (both PDDBs
at the same MTTR) answered `500 "first spool block belongs to another data
set"`. `JESPR_DSID` now takes the record-count test `JESPR_FOREIGN` already
had: no records promised, empty 200. It takes a dynamic `FREE` between the two
allocations — static DDs never show it — so the reproducer
`tests/jcl/emptydd.jcl` uses `ALLOC`/`FREE` in TSO batch. Surfaced by the
BREXX/370 3.0.0-dev build writing to libc370's dynamically allocated SYSOUT
instead of the JCL's `STDOUT`/`STDERR`; that half is mvslovers/brexx370#251.

**PR #369, merged 2026-09-14** — #365: a `USER=` the caller put on the job
card got a second one from mvsMF's injection, and JES2 answered `IEF652I
MUTUALLY EXCLUSIVE KEYWORDS`. The card is cleared of `USER=`/`PASSWORD=` before
ours go on, so the authenticated identity always wins. **A deliberate deviation
from the reference** — measured, z/OSMF passes the card through untouched, but
it can: there the submitter's identity is propagated and SAF checks the card
against it. Without propagation, honouring a card-supplied `USER=` loses the
identity rather than assuming it. The removal lives in `src/jobcard.c` with a
host test, because cutting an operand out of a job card damages the quoted
programmer name or the comma structure silently.

**PR #367, merged 2026-09-14** — the libc370 1.0.6 relink (#366, closed).
The `[toolchain]` pin, plus the half of the out-of-space defect this repo can
reach: the physical I/O is per *block*, so the record that completes one has
its write inside `fflush()`, whose result all three call sites discarded. A PUT
of 200 records into a 194-record data set answered 204 having lost ten;
measured before and after on mvsdev, exactly one row of the band moves.
`MVSMF107E` is the operator side. The close-time band (a partial last block,
five counts in that measurement) is still silently lost and is `libc370#182`.
`tests/curl-nospace.sh` bisects for the capacity rather than hardcoding it, and
reports that band as a KNOWN GAP that should reach 0 when #182 lands. #366 is
closed: what it asked for — relink and check — is done, and the residue is not
ours to fix.

**PR #379, merged 2026-10-01** — the libc370 2.0 port (#378, closed). Includes
rewritten per libc370's migration guide, base64 from crypto370, httpd
`>=4.2.0-dev` and ufsd `>=1.4.0-dev` (prereleases: an mvsMF release waits for
their stable cut), version **1.2.0-dev / `TZMF120`**. The build now runs
`-Wall -Wextra -Werror` — it had no warning flags at all, which is how a missing
`recv()` declaration reached the linker. Generated code compared against the
1.x build TU by TU; `test-mvs` and every integration suite green on mvsdev under
httpd 4.2.0-dev on libc370 2.0.0.

**2026-10-05, direct to `main`** — toolchain bump to mbt v2.2.0 (PR #386,
`dep_startup = true` on MVSMF for httpd's CGI `@@START`), cc370 1.4.0 and a
`[toolchain]` pin of libc370 2.4.0, which needs cc370 >= 1.4.0 and no longer
ships `crt0.o`/`crt1.o`. Build warning-free, `test-host` 276/0, `test-mvs`
584/0 on mvsdev (JOB01416). The integration suites were not re-run.

**PR #397, merged 2026-10-10** — the move to mbt 3 (#396): `mbt.toml`, no
submodule, no Makefile, no `VERSION`. Built gnu89 it is byte-identical to the
mbt 2 build; mbt 3's default gnu99 changes code generation in four objects,
not their externals. Host tests 384/0, every curl and Zowe suite green on
mvsdev (build `d7f0004`, results on the PR). Activation is now `mbt deploy` +
`mbt run restart -- HTTPD` (plugin mvslovers/mbt-stc). Left over: the
Makefile's `run-mvs` / `stop-mvs` / `deploy-desktop` are to come back as mbt
commands (`tools/deploy-desktop.sh` meanwhile), and #398 came out of the
restart.

**PR #399, merged 2026-10-11** — each login gets a session of its own
(mvslovers/httpd#288). `authLoginHandler` calls `http_new_session()` before it
reads the token, so two clients logging on with the same credentials from one
address no longer share a token, and one logout no longer ends both. That makes
httpd 4.2.0-dev from `c81e38e` on a hard requirement (vector entry `0x144`, no
run-time test — #363); `mbt.lock` pins it. TSTSESS 90/0 and every curl and Zowe
suite green on mvsdev (results on the PR). Left over: a Basic response still
carries the shared cache token as a cookie (#324).

**PR #401, merged 2026-10-11** — the REST suites run through mbt (#400):
`mbt run rest-tests [-- SUITE|lua|curl|zowe|all ... [ARGS]]` hands them the
target's URL, user and mbt's session token, never a password, through
`tests/lib/conn.sh`; `mbt run deploy-desktop` does the same for the Desktop.
`.env`, `.env.example` and `tests/test.sh` are gone. The tests that need a
password (logon, wrong password, logout, two logins, the cookie on a Basic
response) are Lua in `mbt/lua/restauth.lua`; the ordinary userid of the
authorization tests is the target's further user `test2`. Every suite green
on mvsdev, with `test2` too: `auth` 21/0 and `curl-datasets` 306/0, no skips,
on mbt `fee3c9d`, which returns the body on an error status (results on the
PR).


Pointers only — the reasoning lives in the closing comments.

- **#362** — fallout of the libc370 1.0.4 relink, found and fixed in the same
  release (PR #364). A SYNAD on the stdio DCBs turns a media error into
  `ferror()` + `EIO` instead of ABEND S001 and leaves `feof()` clear, so six
  read loops would have ended on a bad track exactly as they end at the end of
  the data — a 500 replaced by a 200 with a short body. The pattern to carry:
  **a dependency upgrade can move a failure from loud to silent**, and the
  places it lands are wherever the code reads "no more data" from a count. The
  fix splits by what each site can still decide — the ETag pass and the JCL
  reader answer properly, the streaming paths drop the connection because their
  status is already on the wire.
- **#357** — the two JES2 DDs the jobs API needs in the *host* STC procedure,
  documented in the same PR. Undiscoverable except by reading `jobsapi.c` down
  into libc370, and the whole jobs service answers 500 without them.

- **#210** — the submit response answered `owner:""`, closed in PR #359 and
  measured on mvsdev before and after. Two things worth carrying. The fallback
  is an explicit **parameter** on `find_and_send_job_status()` and has to stay
  one: that function has two callers and only `jobSubmitHandler` can vouch for
  an owner, so collapsing it into a `http_get_userid()` inside the function
  would report the caller as the owner of somebody else's just-submitted job.
  The same reasoning kept it out of the purge handler, which is affected —
  that one authorizes nothing (#345), so the caller is frequently not the
  owner; recorded in `docs/endpoints/jobs/purge.md` rather than fixed. And the
  test lesson repeats #334's: both suites asserted the *key*, which a
  present-but-empty value satisfies, so a green suite carried this the whole
  time.
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

- **Console correctness** — **#195 is what is left**, with #346,
  #214, #251 (PR #408) and #407 (PR #470) closed out of it. One subsystem and one reading of `consapi.c`, but
  four separate bugs, and the two that closed were the two that shared a
  premise: "MVS gives no end-of-response signal, so both ends of the block are
  guessed". #346 was the *end* guessed too early (by design, closed as
  documentation plus a test); #214 was the *start* guessed wrong and then no end
  guessed at all. #195 was ranked with #214 on the guess that it might not
  survive #214's first measurement, and that premise died before #214 did — see
  #195's entry. #251 was always independent of all three, and so was #407, the
  rest of it.
- **The endpoint advertises what it does not do** — **#245 and #361 are what is
  left**, with #248 and now #336 as the worked examples of how it ends. #361 is
  the campaign's mirror image and worth reading as such: there the *docs* are
  right (`get.md:38`, `README.md:136` both promise a length per record) and the
  code is what does not deliver, for RECFM=V. The cheap half here is therefore
  not a doc edit — it is picking which side becomes true. Both prove the
  campaign's premise that the cheap half is worth taking alone: neither mode is
  implemented and nothing lies about either any more. #336 went further than
  #245's doc-only half — the routes themselves are withdrawn (PR #358), and the
  six suite assertions that covered them turned out to have been green
  throughout, because they were measuring the cataloged path.
- **Checked, then swallowed** — **#215 is what is left**, with #267, #251 and
  #407 closed out of it as the worked examples: the return code is inspected and the
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

Still open and ours to wait on — the first four verified 2026-08-23:
`libc370#79` (`exec-submitted`, and the accurate answer for #209 — its
`JESJOB.submit_time64`/`sysid` **ship in libc370 2.0.0**, the issue is still
open), `libc370#30`
(the nicer route for #186, not a gate for it), `httpd#176` (`blocked:rakf`),
`ftpd#90` (decide with #345), and — filed 2026-08-25 — **`libc370#143`**
(volume-addressed SCRATCH/RENAME, the half of #336 that is not ours; the read
and write half needs nothing from there).

**`libc370#524`** -- filed 2026-10-13, **closed, shipped in libc370 2.10.3**
and cashed in by PR #409 (#406): CLOSE no longer STOWs a member whose write
failed.

**`libc370#519`** -- filed 2026-10-12, **closed, shipped in libc370 2.10.2**
and cashed in by PR #404 (#402): `__listds()` read the entry name with
`" -\n"` as delimiters, so a name with a hyphen was cut at it.

Filed 2026-09-14 out of the libc370 1.0.6 relink (#366):

- **`libc370#182`** — **closed, shipped in libc370 1.0.7 and so in our 2.0
  build: `fclose()` now returns `EOF` with `ENOSPC`. The residue is ours now** —
  `curl-nospace.sh` still reported the KNOWN GAP at 5 record counts on mvsdev
  2026-10-01, because mvsMF discards `fclose()`'s result (`session_fclose()`
  and friends in `dsapi.c`). That was **#371, fixed in PR #403** (2026-10-13).
  Original description: a close-time
  out-of-space was invisible. `@@ACLOSE` ends
  `FUNEXIT RC=0` unconditionally and `fclose()` discards even that, so a PUT
  whose last block is *partial* loses those records and answers 204, with
  nothing in this repo able to see it. Measured: five record counts per full
  data set. `fclose()` returning `EOF` as C99 7.19.5.1 requires would close it,
  and `tests/curl-nospace.sh` reports the band as a KNOWN GAP that should reach
  0 when it lands.
- **`mbt#103`** — mbt 2 only; mvsMF is on mbt 3 since PR #397, where this
  is not measured. Neither `libc.a` nor `$(DEP_LIBS)` is a prerequisite of the
  link rule, so installing a new libc370 or staging a new dependency **never
  relinks**. `make` reports "Modules built: 1" and links nothing. This cost a
  measurement here: #366's first run on mvsdev showed pre-1.0.6 behaviour on
  what was believed to be a 1.0.6 build. Until it lands, `make clean` before
  any relink. Sibling of `mbt#65` (cflags) and `mbt#66` (the stale build stamp,
  which also showed up here — the activated module carried the previous
  commit's hash while containing the fix).

**Cashed in on 2026-08-23** — libc370 rebuilt and installed into the cc370
sysroot, mvsMF rebuilt, deployed and activated: `libc370#21` (which unblocked
#186), `#126` (which closed #282), `#127`, `#128`, `#131` and `#104`. Measured
after: `make test-mvs` 508 PASS / 0 FAIL.

The mechanism is the part to remember, because it recurs every time libc370
moves: **none of those arrive via `make deps`.** libc370 is the cc370 sysroot,
not a declared dependency — `mbt.lock` pins only httpd, ufsd and crypto370. A libc370 fix
reaches mvsMF only after `make install` in libc370, a rebuild here, `mbt deploy`,
and `mbt run restart -- HTTPD`. Skip any one of the four and you measure the old
module.
