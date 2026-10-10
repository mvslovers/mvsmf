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
| **httpd** | **4.1.0 or later.** 4.0.1 is a hard floor for anything (`http_realm()`); the console services need the `cgictx` API from 4.0.0-dev; 4.1.0 is the first release carrying unversioned product data sets, which is what these instructions assume. |
| **UFSD** | Only for the USS endpoints (`/zosmf/restfiles/fs`). Everything else works without it. |
| **JES2 usermod `SYZJ201`** | Only for `retcode` on submitted jobs. Without it every job reports `"retcode": null`. See the README. |

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

## 2. Authorize the library — needs an IPL

Add `MVSMF.LINKLIB` to `SYS1.PARMLIB(IEAAPF00)` with the volume it was
allocated on:

```
MVSMF.LINKLIB WORK00,
```

**This is not optional.** The next step concatenates the library into HTTPD's
STEPLIB, and on MVS *every* library in an authorized STEPLIB concatenation must
be APF-authorized — one that is not silently de-authorizes the whole task.
httpd and mvsMF both do authorized work (SVC 34 for operator commands, ACEE
handling for identity), so the server stops working, and the failure that
follows does not name the cause.

The volume is part of the entry rather than decoration: an entry naming a
different volume than the allocation authorizes nothing — **so read the volume
off the allocation rather than assuming it.** `MVSMFALC` allocates with a bare
`UNIT=SYSDA`, which lets the system choose among the volumes in that group, and
a second run on a fuller system can choose a different one (`mbt#102`). The
allocation job's `IEF285I` lines name what it actually used; `LISTCAT` or
`GET /zosmf/restfiles/ds?dslevel=MVSMF` answers it afterwards.

MVS 3.8j reads `IEAAPF00` at IPL and has no dynamic APF update, so **this step
needs an IPL** before the library can be used.

## 3. Concatenate it into HTTPD's STEPLIB

See `MVSMF.SAMPLIB(MVSMFSTC)`. Edit the STEPLIB DD of your HTTPD procedure:

```jcl
//STEPLIB  DD  DISP=SHR,DSN=MVSMF.LINKLIB
//         DD  DISP=SHR,DSN=HTTPD.LINKLIB
```

`MVSMF.LINKLIB` goes **first** on purpose. If a copy of `MVSMF` was ever placed
into `HTTPD.LINKLIB` by hand — the development deploy does exactly that —
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

## Removing mvsMF

See [uninstall.md](uninstall.md).
