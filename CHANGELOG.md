# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

mvsMF is a **CGI module**: it runs inside HTTPD's address space with its own
statically linked C runtime, so the libc370 version named in an entry below is
the one *this* module was built against. Relinking the server does not change
it, and `HTTPD005I` reports the server's, not mvsMF's.

## [Unreleased]

## [1.3.0] - 2026-10-15

The release that stops every request from costing the server storage for
good. FMID `TZMF130`, and its SYSMOD deletes `TZMF120`, so an upgrade from
1.2.0 needs nothing beyond the package. A drop-in: no configuration changes.

Built against **libc370 2.12.1**, **httpd 4.2.0**, **ufsd 1.4.0** and
**crypto370 1.0.1**. httpd 4.2.0 stays the minimum (see 1.2.0).

### Fixed

- **A request no longer leaks 128 bytes of the server's storage** (#430).
  Every run of a C module built against libc370 up to 2.12.0 left its
  128-byte runtime block in subpool 0 when it ended. HTTPD runs mvsMF once per
  request, so the server's free storage shrank by about 137 bytes per request
  until a restart; at that rate 7 MB of free storage lasts about 50,000 mvsMF is
  built against libc370 2.12.1, which frees the block. Measured on MVS: 900
  requests, no storage lost; 300 cost 40,960 bytes before. Other CGI modules
  in the same server leak until they are relinked too.
- **A read error after the response started breaks the transfer** (#421).
  When reading a data set failed after the status line had been sent, the
  client got a complete-looking `200` with the data missing. The
  connection is now dropped, so the client sees a failed transfer.

### Added

- **`MVSMF913I` and `MVSMF914I` say where a caught abend happened** (#425).
  After every `MVSMF901E` the PSW, the failing instruction and R14 follow,
  as offsets from the module's entry point, and, when they lie inside
  mvsMF, the 16 bytes around the failing instruction. See
  `docs/messages.md` for how to look the offsets up in the link map.
- **`fn=textsum` and `fn=textdump` on the test endpoint** (#425). A checksum
  per 4 KB block of the loaded module, and the bytes at an offset, so that
  code overwritten while it is loaded can be seen before it runs.

### Changed

- **No APF entry is needed for `MVSMF.LINKLIB`** (#415). The installation
  guide called it "not optional". mvsMF runs with HTTPD's authorization, and
  HTTPD authorizes itself through SVC 244 from RAKF when its STEPLIB is not
  all in `IEAAPF00`; `HTTPD002I` names the route it took. The guide now
  describes both routes: SVC 244, with no entry and no IPL, and the APF list,
  which needs an entry for every library in the STEPLIB.
- **The installation guide covers MVS/CE and hand-copied installs** (#419).
  Both `RECEIVE`s of the install job need `VOLUME()` on MVS/CE. A new section
  describes moving from a hand-copied `MVSMF` to the SMP install. The links
  to `uninstall.md` and the `SYZJ201` section now work from inside the
  package.

## [1.2.0] - 2026-10-13

The release that moves mvsMF to **libc370 2.x**, which is why the minor moves.
FMID `TZMF120`, and its SYSMOD deletes `TZMF110`, so an upgrade from 1.1.0
needs nothing beyond the package.

Built against **libc370 2.10.3**, **httpd 4.2.0**, **ufsd 1.4.0** and
**crypto370 1.0.1**. **httpd 4.2.0 is a hard minimum**: see *Read this first*.

### Read this first

- **httpd 4.2.0 or later is required, and nothing checks it.** The token login
  (`POST /zosmf/services/authenticate`) now calls a server function that first
  appeared in httpd 4.2.0. mvsMF reaches the server through a function vector
  and cannot test at run time whether an entry is there (#363). On an older
  server the login abends the CGI. Install httpd first, then mvsMF.

### Added

- **`X-IBM-Data-Type: text;fileEncoding=...`** (#391, #393). `IBM-037` (or
  `037`) and `IBM-1047` (or `1047`) select the code page a text transfer is
  translated with, on reads and writes, for data sets, members and USS files.
  The defaults stay as they were: CP037 for data sets, IBM-1047 for USS files.
  Any other value is answered `500` with the reference's
  `"iconv_open() failed."` body. On a write that check runs before the target
  is opened, so the target is left as it was. On USS files `record` is answered
  `400`, as on the reference. Data sets keep the record mode they already had.

### Changed

- **Each token login gets a session of its own** (#399). Two clients logging
  on with the same userid and password from the same address used to get the
  same token, so a logout by one ended the other. A login whose credentials are
  good but for which no session can be created now answers `500` with
  `returnCode 4, reasonCode 40`. That happens when the server's credential
  store is full, or when the client already holds 16 sessions. Not covered:
  the `LtpaToken2` cookie set on a Basic-authenticated response is still the
  shared credential's token, so a logout with that cookie ends it for every
  holder of the cookie.
- **Rebuilt on libc370 2.x** (#378), now 2.10.3, with the cc370 1.6 toolchain.
  Base64 comes from crypto370, a new static dependency; it adds nothing to
  install. The build now treats every warning as an error
  (`-Wall -Wextra -Werror`). The fixes this needed are not meant to change
  behaviour.
- **Built with mbt 3** (#396). This matters only when building from source:
  `mbt build`, `mbt deploy` and `mbt run restart -- HTTPD` replace the make
  targets. The build id `/zosmf/test?fn=version` reports gains a `-dirty`
  suffix when the tree differed from the commit.

### Fixed

- **A PUT whose last, partial block does not fit is reported** (#371). This
  was the known limitation of 1.1.0. The last block of a write is usually
  partial and is written only when the data set is closed. libc370 reports a
  failed close now, and mvsMF answers `500` "Error writing the last block" and
  writes `MVSMF107E`, where it used to answer `204` with the tail missing. The
  same applies to a member smaller than one block written into a full PDS.
- **A member PUT that runs out of space leaves the member as it was** (#406).
  libc370 up to 2.10.2 wrote the directory entry when it closed a member whose
  write had failed: a failed new member stayed in the directory with no
  records, and a failed overwrite left the existing member empty, although
  the PUT answered `500`. With libc370 2.10.3 a failed new member does not
  appear, and an existing one keeps its old content. Measured on MVS: a PDS
  filled member by member until one fails, with the previous libc370 as the
  control.
- **The `dslevel` listing keeps a name with a hyphen whole** (#402). A data set
  such as `A.B-C` used to be listed as `A.B`, with empty attributes.
- **An empty spool data set reads as empty** (#376). A program that allocates
  its own SYSOUT data sets dynamically and frees one without writing to it
  leaves that data set pointing at the first record of the next one. Reading
  the empty one answered `500`. It answers `200` with no records now; the
  neighbour still reads in full.
- **`X-IBM-Data-Type: BINARY` and `binary;...` are binary** (#391, #393).
  Anything but the exact string `binary` used to be translated as text.
- **The hardcopy log reports a failed snapshot** (#251). When the copy of the
  Master Trace Table could not be allocated, the log answered `200` with no
  items. It answers `500` with reason code 8/1 now. An empty window is still
  `200`.
- **A request body is allocated once, at its size, and a failure is answered**
  (#412). A body with a `Content-Length` (a job submitted as JCL, a USS file,
  a console command) started in a 4 KB buffer that doubled, so a 72 KB body
  asked for one contiguous 128 KB block while holding a 64 KB one, so a region
  without a 128 KB hole could fail a body it had room for. When the read
  failed, the client could see the connection close instead of an error: the
  rest of the body was still unread, and closing such a socket resets the
  connection.
  The body is now allocated once. A body there is no storage for is read to
  its end and answered `500`. A `Content-Length` of 16 MB or more, more than
  24-bit storage holds, is answered `413` without reading. A submit that ran
  out of storage for its line table, or whose job the internal reader
  refused, ended with no answer at all; it answers `500`. The submit no
  longer holds a second copy of the JCL. A malformed `Content-Length` such as
  `abc` is answered `400`; it used to be read as an empty body, and on a USS
  PUT that emptied the file.
  The failure reported in #412 has not been reproduced: on a test system the
  largest free block stayed whole through a 28 MB upload and the submits that
  followed it. #412 stays open until it is checked again where it was seen.

### Known limitations

- **Collect and detections still read a failed snapshot as "no matches"**
  (#407). Under a storage shortage a detection can report `detected` for a
  message that was there before the command, and a collect can return the
  block of a later identical command. The hardcopy log is fixed (above); these
  two need a change of convention and come later.

## [1.1.0] - 2026-09-14

The release that makes mvsMF **SMP4 installable**, which is why the minor
moves: every project in the ecosystem took one when it did. FMID `TZMF110`.

Built against **libc370 1.0.6**, **httpd 4.0.2** and **ufsd 1.2.2**.
**httpd 4.1.0 or later is what the install guide assumes** — it is the first
release carrying unversioned product data sets.

### Added

- **An SMP Release 4 install package** (`TZMF110`). `make package` builds it:
  an allocation job, an install job carrying the SYSMOD inline, and a samplib
  with the two members a site has to act on — the STEPLIB concatenation and
  the three route definitions. [docs/installation.md](docs/installation.md) is
  the guide, [docs/uninstall.md](docs/uninstall.md) the way back out.

  **The module installs into its own `MVSMF.LINKLIB`, not into httpd's**, and
  that library needs an `IEAAPF00` entry before it is concatenated into
  HTTPD's STEPLIB: every library in an authorized STEPLIB concatenation must
  be APF-authorized, or the whole task silently loses authorization. MVS 3.8j
  reads `IEAAPF00` at IPL, so that step needs one.

  **There is no SMP prerequisite on httpd**, deliberately. mvsMF is a CGI and
  does not run without it, but SMP's `REQ()` takes exact SYSMOD ids and has no
  range syntax, so the only expressible requirement is "exactly this level" —
  which fails both for an older httpd and for a system where a newer one was
  installed fresh. The floor is stated in the install guide, where it can be
  written as a floor.

### Changed

- **`make deploy` now targets `MVSMF.DEV.LINKLIB`** instead of a versioned
  library under the caller's HLQ. Three libraries, three owners: SMP owns
  `MVSMF.LINKLIB`, development owns `MVSMF.DEV.LINKLIB`, and httpd owns
  `HTTPD.LINKLIB`. Writing a development build into either of the other two
  makes something lie — SMP's inventory about what is installed, or the
  server's STEPLIB about which level runs.

- **Relinked against libc370 1.0.6.** Two stdio changes arrive with it, both on
  the write side of the data set API. An out-of-space write is a return code
  rather than ABEND SD37 (`libc370#176`): `ferror()` is set and `errno` is
  `ENOSPC`, where the abend used to reach the router's ESTAE and answer 500.
  And a stream that has failed now refuses every further write instead of
  accepting it into the FILE buffer and discarding it at flush time
  (`libc370#149`) — measured there as 46 of 50 writes reporting full length
  with not one record reaching the disk. The `ferror()`/`feof()` macros, which
  returned the raw flag value rather than 1/0, are corrected in the same
  header.

### Fixed

- **A data set PUT no longer reports success after losing records to a full
  data set** (#366). The relink above is what exposed it: an out-of-space write
  used to ABEND `SD37` into the router's ESTAE and answer 500, and now it
  returns. mvsMF flushes after every record but the physical I/O is per
  *block*, so whenever a record completes a block that block's write happens
  inside `fflush()` — whose return value was discarded. Measured on MVS
  2026-09-14 against a 194-record data set: a PUT of 200 records lost ten and
  answered `204`, where the same request on the previous build answered 500.
  The flush is checked now, and a full data set also reaches the operator as
  `MVSMF107E`.

- **A `USER=` on a submitted job card no longer produces invalid JCL** (#365).
  mvsMF injects `USER=`/`PASSWORD=` on every submit because MVS 3.8j does no
  userid propagation, and did so whatever the card already said — so a caller
  who wrote their own got two operands and `IEF652I MUTUALLY EXCLUSIVE
  KEYWORDS`. The card is cleared of both before mvsMF adds its own, so the
  authenticated identity always wins.

  **This deviates from the reference on purpose.** Measured against a real
  z/OSMF: a card carrying `USER=` comes back out of JESJCL byte for byte and
  the job runs under that userid. It can, because there the submitter's
  identity is propagated and SAF checks the card against it. Without
  propagation, honouring a card-supplied `USER=` does not run the job as that
  user — it loses the identity and the job runs as the PROD default. You
  cannot submit under a second identity by putting its credentials on the
  card; authenticate as that user instead.

### Known limitations

- **A PUT whose last block is partial still loses those records silently**
  (#366). The tail block is written by libc370's `@@ACLOSE`, which ends
  `FUNEXIT RC=0` unconditionally, and `fclose()` discards even that — so
  nothing in this repo can see the failure. In the measurement above that band
  is 195..199 records against a 194-record target: `204`, five to nine records
  gone. Closing it needs libc370 to report a failed close; `fclose()` returning
  `EOF` as C requires would be enough.

## [1.0.0] - 2026-09-06

First stable release. The API surface below has been in use against Zowe CLI,
Zowe Explorer and JetBrains plugins throughout the 0.x and `1.0.0-dev` line;
what 1.0.0 adds is the commitment to it.

Built against **libc370 1.0.4**, **httpd 4.0.2** and **ufsd 1.2.2**.
**httpd 4.0.1 is a hard minimum** — see *Known limitations*.

### Added

- **Data sets** (`/zosmf/restfiles/ds`) — list by `dslevel`, read, write,
  create, delete and rename, for sequential data sets and PDS members, with
  `X-IBM-Data-Type` text/binary/record, `X-IBM-Max-Items` paging, and ETag
  optimistic locking (`X-IBM-Return-Etag`, `If-Match`, `If-None-Match`).
- **Jobs** (`/zosmf/restjobs/jobs`) — submit inline JCL or from a data set,
  status, spool file list, spool records, purge. `retcode` needs the JES2
  usermod `SYZJ201`; the README says why and how to check.
- **USS files** (`/zosmf/restfiles/fs`) — list, read, write, create, delete
  through libufs/UFSD, IBM-1047, with the same ETag support.
- **Console services** (`/zosmf/restconsoles`) — issue an operator command,
  collect its response, detect unsolicited messages, read the hardcopy log.
  The data source is the Master Trace Table; MVS 3.8j has no EMCS consoles and
  its active SYSLOG is not browsable.
- **Token login** (`/zosmf/services/authenticate`) and `/zosmf/info`.

### Changed

- **Relinked against libc370 1.0.4.** This is the delivery mechanism for that
  library's stdio fixes — a concurrent `printf()` that corrupted the stream, a
  `fclose()` that tore a FILE down outside its lock, a `DEQ` that dropped its
  scope bits — none of which reach a module until *that module* is rebuilt.
  Take httpd 4.0.2 and ufsd 1.2.2 with it; they are the same relink.
- **The submit response reports the owner mvsMF actually injected** (#210).
  It used to answer with the caller's userid regardless of what went into the
  `USER=` on the job card.
- **The `-({volume-serial})` data set routes are withdrawn** (#336). They were
  registered and the volume operand was captured and then discarded, so a
  request naming the wrong volume was answered as if it had named the right
  one. Unregistered is honest; implementing them properly needs a
  volume-addressed SCRATCH/RENAME that libc370 does not have yet.

### Fixed

- **An uncorrectable I/O error no longer truncates a reply silently** (#362).
  libc370 1.0.4 turns a media error into `ferror()` + `EIO` instead of ABEND
  S001, and deliberately leaves `feof()` clear — so every read loop that reads
  `0`/`NULL` as end of data would have ended on a bad track exactly as it ends
  at the end of the data. Six paths were exposed by the upgrade: the three
  download modes and the PDS directory walk now drop the connection rather
  than end a short body cleanly, `dataset_etag()` returns no stamp rather than
  one over a prefix of the resource, and a JCL data set that cannot be read in
  full is not submitted to JES2. New operator message `MVSMF106E`.

### Known limitations

- **`restconsoles` and `restjobs` are authenticated but not authorized**
  (#347, #345). Any userid that can log in can issue any operator command from
  console 0 and read the whole Master Trace Table; on jobs, `owner=*` and the
  by-jobid paths reach another user's spool output and purge. The README
  security note carries the mitigation. MVS 3.8j security products have no
  JESSPOOL class and no console authority reachable from `MGCR`, so both need
  a policy invented rather than delegated.
- **Data set creation is authorized only by the ambient ACEE** (#329). RAKF
  does refuse it, and the refusal is the reference's dynalloc 500 — what is
  open is which identity decides.
- **`X-IBM-Data-Type: record` is wrong on RECFM=V for reads and unimplemented
  for writes** (#361, #245), and the binary write path mis-frames V records
  (#244). Text mode round-trips V correctly; the three are ranked as one
  ordered block in `TODO.md`.
- **The dataset listing (`?dslevel=`) is not authorized**, deliberately: real
  z/OSMF does not gate it either, and gating it would make mvsMF stricter than
  the thing it clones (#229, measured).
- **`DSORG=DA` data sets cannot be written** (#76) — QSAM extends past the
  primary allocation and `SD37`s.
- **USS files are capped at 64 KB** by UFSD's direct-block layout.
- **An httpd older than 4.0.1 abends the CGI on every unauthenticated request**
  (#363). `http_realm` is the last member of the HTTPX vector and mvsMF calls it
  unguarded to build the `WWW-Authenticate` challenge, so on an older server the
  load reads past the end of the table. There is no version field in the vector
  to test against; the fix that scales is one on the httpd side.

## [1.0.0-dev] - 2026-08-25

Prerelease of the above, built against libc370 1.0.3 and httpd 4.0.1.
