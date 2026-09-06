# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

mvsMF is a **CGI module**: it runs inside HTTPD's address space with its own
statically linked C runtime, so the libc370 version named in an entry below is
the one *this* module was built against. Relinking the server does not change
it, and `HTTPD005I` reports the server's, not mvsMF's.

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
