# `/zosmf/test` -- code-integrity probes and the gate history

Moved verbatim from `CLAUDE.md` on 2026-10-19; `CLAUDE.md` keeps the rules every session needs and points here.

Read before using `fn=textsum` / `fn=textdump`, or before adding or gating a test function.
For `fn=storage` see [storage-probe.md](storage-probe.md).

`fn=textsum` and `fn=textdump` watch MVSMF's own loaded code (#425): the
load point plus one FNV-1a sum per 4 K block, and up to 256 bytes at an offset.
MVSMF is RENT, so two samples of one build at one load point must agree; a
block that changed was overwritten. On a stand whose STEPLIB is not APF the
module sits in key-8 storage and a stray store lands there silently; APF does
not fully protect either, because a store from a key-0 path (MODESET for
`fn=cmd`, the ACEE handling) reaches the key-0 copy too. Only compare samples
at one load point: relocated address constants differ between loads. A
different load point or `cde` address proves a reload; the same ones do not
prove the same copy. **MVS deletes MVSMF whenever its use count drops to 0**
(measured on dev1 by walking HTTPD's job pack queue through `/.dm` while idle:
no MVSMF CDE, and its CDE cell and storage taken by HTTPDM). httpd holds no
LOAD of its own, so every request after an idle gap fetches a fresh copy,
usually into the same free block and CDE cell. A damaged copy survives only
while requests overlap, and `textsum` -- itself a request -- sees only damage
that is present while it runs. `textdump`'s `off` is from the load point, which is also
the link map's module offset; from an `MVSMF913I` `EP+X'n'` it is file370's
`entry=` plus `n`. Both are gated to the CDE extent of this copy of MVSMF, as
`MVSMF914I` is.

**The endpoint has no per-function gate any more, and must not grow one back
(#343).** `fn=abend`, `fn=jesabend` and `fn=denyopen` were gated on
`MVSMF_ABEND_TEST` in the server environment from the days when a CGI abend
cost the address space its storage permanently (httpd#154). That is measured
gone — httpd#175 plus mvslovers/libc370#126 — and the gate was guarding the
weakest function here while `fn=cmd`, which issues operator commands through
SVC 34 in supervisor state, never had one. `&hold=` went with it: it was the
only knob that degraded *other* requests, and #287, which it was built for, is
closed. The boundary that means something is the route: building with
`-DMVSMF_NO_TEST_ENDPOINT` leaves `/zosmf/test` unregistered, which covers
`fn=cmd` too. The flag is off by default; what leaves the endpoint out of a
release is the next paragraph.

**A release does not register it (#508).** `mvsmf.c` registers the two routes
only when `build_is_dev(MBT_VERSION)` (`buildkind.c`, host test `tstbknd.c`)
says the stamped version ends in `-dev`. mbt 3 has no release build: `mbt
package` is the same compile as `mbt build`, `[build] cflags` is global, a hook
cannot change the build, and `<buildstamp.h>` carries the version, not a build
kind. So the version is the only thing that tells a tag (`1.4.0`) from a
development build (`1.4.0-dev`). The decision fails closed: a missing, odd or
differently suffixed version counts as a release. A package built from a tag
before this change contained the endpoint and all its functions; now it is
unreachable in a release (`404`), and a `-dev` prerelease package still has it.

**What this does not do:** the code stays in the release module, only
unreachable. Leaving it out of the object needs mbt to emit a compile-time
release flag (`MBT_RELEASE`) so `#if` can drop `testapi.c`; until then
`-DMVSMF_NO_TEST_ENDPOINT` stays the only way to build it out. A `-dev` build on
a production system has the endpoint -- DEV libraries have no business there
(root `CLAUDE.md`).

**Checking a release deploy** needs no endpoint: `GET /zosmf/info`, field
`zosmf_full_version`. It is the version only, with no git hash; a tagged build
is identified by its version. `fn=version`, `fn=storage`, `fn=textsum` and every
other function exist on development builds only.

**Tests that need the endpoint** run against a development build. `curl-diag`
skips on a release, `curl-consgate` leaves its `/zosmf/test` rows out, and the
`fn=dscb` assertions of `curl-datasets` skip, all by asking `mvsmf_dev_build`
(`tests/lib/conn.sh`). The load and soak scripts (`poll-425.sh`, `load-452.sh`,
`storage-classes.sh`, `soak-176.sh`, `loadtest-176.sh`) are probe-driven by
design: run them on a development build. Some assertions that read a probe
(`mtt_abend_count` in `curl-datasets`, the `fn=syslog` lookup in `curl-jobs`)
have a fallback and weaken silently on a release rather than fail.

**Who may call it is a separate question, answered once for the whole
endpoint (#460).** `testHandler` and `testWildcardHandler` start with
`console_authorize()`, before `fn` is read: READ on `FACILITY MVSMF.CONSOLE`,
the profile of the console service, fail-closed (no profile, no READ, no ACEE:
refused; `internals/authorization.md`). That covers `fn=version` and the help
text, and a new `fn=` needs nothing added. It is a gate on the endpoint, not on
a function, so it is no exception to the rule above: do not add a second check
inside a `fn=` branch. Consequence for a deploy: the user who confirms the build
id with `fn=version` needs READ on the profile.

**No function of the endpoint returns session data (#508).** Whatever
identifies a session or authenticates a caller (a credential, a token value)
must not be readable through `/zosmf/test`, with or without a flag: the
endpoint's gate is READ on one FACILITY profile, which says who may issue
operator commands, not who may see another layer's secrets. `fn=token` shows
that the line can be drawn: it reports the token's length and how the caller
authenticated, never the value. The one function that returned a credential
was removed outright; a function that needs such a value to work belongs in
the handler that uses it, not in a probe.

`tests/curl-diag.sh` now asserts what the gate used to promise: an abend is
caught, the server keeps serving, and it costs no storage. It deliberately
faults the worker several times.

## `fn=dscb` and `fn=listds`: probes behind the libc370 2.25 move (#442)

`fn=dscb&dsn=...` reads the data set's format-1 DSCB and the format-4 DSCB of
its volume. Besides the extent and DS1LSTAR fields it returns the geometry
`dsapi.c` computes with: `devtk`, `devov`, `devk`, `devfg`, `dstrk`
(tracks per cylinder), `dscb4_rc` (the `__dscbv()` return code) and
`blocks_per_track` for the data set's block size, from the same
`blocks_per_track()` (`blkptrk.c`) that `get_fb_record_count()` calls. That is
how a new device type is checked against a real volume before its formula is
trusted: create an FB data set on it, write a known number of records, and
compare `lstar_tt`/`lstar_r` with `blocks_per_track`.

`fn=listds` adds `"nomem"`: `true` when `__listds()` returned NULL with
`errno` ENOMEM (a storage shortage), `false` for a plain empty result. The
list handlers tell the two apart the same way (#360).
