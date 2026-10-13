# Installing mvsMF

mvsMF is delivered as an **SMP Release 4** install package — the SMP that ships
with MVS 3.8j, not SMP/E. `mbt package` builds it; a release attaches it.

FMID **`TZMF120`** (mvsMF 1.2.0). Each release spends one id and **deletes its
predecessor**, so an upgrade needs nothing beyond the package.

## What you need first

mvsMF is a **CGI module**: it does not run on its own. It is LINKed per request
by Mike Rayborn's **HTTPD** server, which must be installed and running.

| | |
|---|---|
| **httpd** | **4.2.0 or later.** The token login calls `http_new_session()`, which first appeared in 4.2.0, and mvsMF cannot test for it at run time (#363): on an older server the login abends the CGI. Install httpd first, then mvsMF. These instructions also assume the unversioned product data sets httpd carries since 4.1.0. The startup message `HTTPD001I HTTPD <version> READY` names the level that runs. |
| **UFSD** | Only for the USS endpoints (`/zosmf/restfiles/fs`). Everything else works without it. |
| **JES2 usermod `SYZJ201`** | Only for `retcode` on submitted jobs. Without it every job reports `"retcode": null`. See [The `SYZJ201` usermod](https://github.com/mvslovers/mvsmf/blob/main/README.md#the-syzj201-usermod) in the project README. |

**None of these is an SMP prerequisite, and that is deliberate.** SMP's `REQ()`
takes exact SYSMOD ids and has no range syntax, so a prerequisite could only
say *"exactly this level"*. Every project in this ecosystem now spends one FMID
per release, so such a requirement would break in both directions: a system
with an older httpd could not install mvsMF, and a system where a newer httpd
was installed fresh never saw the id we would have named. A floor belongs in
prose, where it can be written as a floor.

## 1. Receive and install

The package contains the usual pair of jobs. Run them in order:

| Job | What it does |
|---|---|
| `MVSMFALC` | Allocates the target and distribution libraries |
| `MVSMFINS` | RECEIVE, APPLY CHECK, APPLY, ACCEPT |

**On MVS/CE the install job needs one more change.** Both `RECEIVE` commands in
it (steps `RECV1` and `RECV2`) need a `VOLUME()` operand naming the volume to
allocate on — `PUB000` on a stock MVS/CE:

```
  RECEIVE INDSN('CHANGE.ME.MVSMFLOD') -
    DATASET('MVSMF.MVSMFLOD') -
    VOLUME('PUB000')
```

The job's own comment says the `CHANGE.ME` lines are the only ones to change;
on MVS/CE that is not so. On TK5 the job runs as shipped.

**Verify the install by listing the members of `MVSMF.LINKLIB`, never by the
condition codes.** SMP keys element ownership on `MOD(name)`, and a SYSMOD that
does not own an element skips it: the element summary prints

```
ELEM   ELEMENT   ELEM
TYPE   NAME      STATUS
MOD    MVSMF     NOT SEL
```

nothing is copied, and every other line still says success — RECEIVE, APPLY
CHECK, APPLY and ACCEPT all RC 00, `HMA2270 … SUCCESSFULLY COMPLETED`, and
`STATUS = REC APP ACC` in both zones. The message that separates a real install
from that one is:

```
HMA2380 COPY SUCCESSFUL - MOD=MVSMF - LMOD=MVSMF - LIBRARY=…
```

If that line is not in the job log, nothing was copied.

## 2. Authorization — usually nothing to do

mvsMF does authorized work: every authenticated request switches the task's
identity (ACEE handling in key 0), and the console API issues operator commands
(SVC 34). It does not authorize anything itself. It is never a job step
program; HTTPD LINKs it per request, so it runs with **HTTPD's** authorization,
and what it needs is an authorized task, not an authorized library.

HTTPD gets that authorization one of two ways, and says at startup which one it
took:

```
HTTPD002I AUTHORIZED BY SVC (MODULE KEY 8)         SVC 244, from RAKF
HTTPD002I AUTHORIZED BY LIBRARY (MODULE KEY 0)     every STEPLIB library in IEAAPF00
```

**SVC 244 — no APF entry, no IPL.** HTTPD's documentation calls this the normal
route on a stock TK4- or TK5, and it is the one to take unless you have a reason
not to. HTTPD needs RAKF anyway; with RAKF in place, `MVSMF.LINKLIB` goes into
the STEPLIB in step 3 and that is all. Without RAKF *and* without an APF entry
HTTPD does not start at all (`HTTPD012E`, see HTTPD's message reference), so a
server that is up is authorized.

**The APF list.** If you want HTTPD authorized by library, add
`MVSMF.LINKLIB` to `SYS1.PARMLIB(IEAAPF00)` with the volume it was allocated
on:

```
MVSMF.LINKLIB WORK00,
```

On MVS a STEPLIB concatenation is authorized only if *every* library in it is,
so this route needs an entry for **each** of them — `HTTPD.LINKLIB`, a
development library you put in front, and this one. Because the rule is
all-or-nothing, a single library missing does not break anything either: the
step starts unauthorized and HTTPD falls back to SVC 244. No warning is
written, but `HTTPD002I` names the SVC route instead of `LIBRARY` — read it
rather than assume the route.

The volume is part of the entry rather than decoration: an entry naming a
different volume than the allocation authorizes nothing — **so read the volume
off the allocation rather than assuming it.** `MVSMFALC` allocates with a bare
`UNIT=SYSDA`, which lets the system choose among the volumes in that group, and
a second run on a fuller system can choose a different one (`mbt#102`). The
allocation job's `IEF285I` lines name what it actually used; `LISTCAT` or
`GET /zosmf/restfiles/ds?dslevel=MVSMF` answers it afterwards.

MVS 3.8j reads `IEAAPF00` at IPL and has no dynamic APF update, so **this route
needs an IPL** before the entry takes effect.

## 3. Concatenate it into HTTPD's STEPLIB

See `MVSMF.SAMPLIB(MVSMFSTC)`. Edit the STEPLIB DD of your HTTPD procedure:

```jcl
//STEPLIB  DD  DISP=SHR,DSN=MVSMF.LINKLIB
//         DD  DISP=SHR,DSN=HTTPD.LINKLIB
```

`MVSMF.LINKLIB` goes **first** on purpose. If a copy of `MVSMF` was ever placed
into `HTTPD.LINKLIB` by hand — older development setups did exactly that —
whichever library comes first wins, and an install into the other one activates
nothing while every step reports success. Better still: delete the hand-placed
copy.

## 4. Register the routes

See `MVSMF.SAMPLIB(MVSMFPRM)`. Add these three lines to the member your HTTPD
started task names on its `//HTTPPRM` DD:

```
MOD=MVSMF /zosmf/info                    AUTH=NONE
MOD=MVSMF /zosmf/services/authenticate   AUTH=NONE
MOD=MVSMF /zosmf/*                       AUTH=TOKEN
```

**Order matters — first match wins.** The two specific routes must precede the
catch-all.

`AUTH=NONE` on the first two is not a hole. Both endpoints resolve the caller
themselves and answer 401 without a credential: `/zosmf/info` is authenticated
like every other route (#324 — the "anonymous liveness probe" it was once
documented as never existed, and the reference gates its own too), and the token
login must reach its handler even when the login fails, to produce the
z/OSMF-shaped 401 body.

To narrow access, protect the catch-all with a resource check rather than
widening the prefix:

```
MOD=MVSMF /zosmf/*  AUTH=TOKEN RES=FACILITY:MVSMF.ACCESS
```

## 5. Restart httpd and verify

```
P HTTPD
S HTTPD
```

Then ask the server what it is actually running:

```
curl -u USER:PASS 'http://your.host:port/zosmf/test?fn=version'
```

It answers the version and the git hash the live module was built from. A
successful install that still reports the previous hash means something else is
shadowing it — see step 3.

`GET /zosmf/info` is the ordinary reachability check once a credential is to
hand.

## Upgrading

From 1.2.0 onwards each release's SYSMOD **deletes its predecessor**, so an
upgrade is RECEIVE/APPLY/ACCEPT of the new package and nothing else. Do **not**
run the uninstall job's `DELETE` step in between: it names the data sets the new
install is about to use.

`RESTORE` and `REJECT` are not the way to make room for a new level. Both are
refused once the FMID has been accepted, which the install job does in the same
run as the APPLY.

## Coming from a hand-copied MVSMF

mvsMF 1.0.0 and 1.0.1 shipped without an install package, so a system that ran
them has the `MVSMF` module in a library SMP knows nothing about. Two shapes
have been met: a library of its own (`MVSMF.V1R0M0.LINKLIB` on TK5), and a
copy placed into a non-SMP `HTTPD.LINKLIB` beside HTTPD itself (MVS/CE). There
is no SMP level to upgrade from; treat it as a fresh install and retire the
copy:

1. **Install as above** (steps 1 to 4). The package's SYSMOD names its
   predecessor for deletion. On a system that never had it, nothing is deleted
   and the APPLY still ends RC 00. SMP still records the deletion: a `LIST` of
   the predecessor id is expected to show `TYPE = FUNCTION` / `DELBY = …`, a
   tombstone SMP leaves even for an id that was never installed. It marks the
   id as spent, and an uninstall has to name it.
2. **Put `MVSMF.LINKLIB` first in the STEPLIB** (step 3). While the
   hand-copied module sits in a library ahead of it, that copy is what runs.
3. **Replace the old route lines** with the three of step 4. A `MOD=MVSMF`
   line without `AUTH=` is public to HTTPD. After the restart an
   unauthenticated request must be refused:

   ```
   curl -i 'http://your.host:port/zosmf/restjobs/jobs'      # expect 401
   ```

4. **Restart and check the level** with `?fn=version` (step 5). Once it
   reports the release you installed, retire the old library, so the copy
   cannot come back to the front of a concatenation later. A library of its own
   can simply be scratched.

**If the old copy sits in a non-SMP `HTTPD.LINKLIB`,** that library is HTTPD's
problem before it is mvsMF's: HTTPD's own allocation job cannot allocate
`HTTPD.LINKLIB` while the old one exists. Rename it aside first (IDCAMS
`ALTER HTTPD.LINKLIB NEWNAME(…)`, which renames catalog entry and VTOC entry on
MVS 3.8j), install HTTPD and then mvsMF through SMP, and scratch the renamed
library whole once both run — the hand-copied `MVSMF` and anything copied in
alongside it go with it. HTTPD's side of this is
[mvslovers/httpd#295](https://github.com/mvslovers/httpd/issues/295).

## Removing mvsMF

See [uninstall.md](https://github.com/mvslovers/mvsmf/blob/main/docs/uninstall.md).
