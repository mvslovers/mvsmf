# ETag and conditional requests (`etag.c`)

Moved verbatim from `CLAUDE.md` on 2026-10-19; `CLAUDE.md` keeps the rules every session needs and points here.

Read before touching `etag.c`, `dataset_etag()`, `uss_etag()` or any `If-Match` / `If-None-Match` path.

- **etag.c**: The ETag stamp and `If-Match` parsing behind the optimistic
  locking on data sets and members (#152), and the same predicate answering
  `If-None-Match` on the read side (#263 — a match means 412 on a write, 304 on
  a read, wildcard included; there is no inverted variant).
  It also carries the USS side (#264 — `X-IBM-Return-Etag` and `If-Match` on
  `/restfiles/fs/{*filepath}` — and #271, which brought `If-None-Match` there
  too; the 304 response itself is `send_not_modified()` in `common.c`, hoisted
  out of `dsapi.c` when USS became its second caller).
  Deliberately free of MVS services so
  it unit-tests on the host (`TSTETAG`); the reading lives with the knowledge
  it needs — `dataset_etag()` in `dsapi.c` next to the DCB handling,
  `uss_etag()` in `ussapi.c` next to the UFS handling. Three rules that are
  load-bearing and all fail silently if broken: the stamp is computed over the
  **stored bytes**, never over the bytes sent (those depend on
  `X-IBM-Data-Type`, and on USS also on the IBM-1047 translation); the hash
  pass takes the **same bound** the send path uses, i.e.
  `get_fb_record_count()` for a sequential data set and `-1` for a member; and
  the ETag a PUT returns comes from **re-reading the closed resource**, never
  from hashing the request body — the write and read paths normalize in
  opposite directions, so a body-derived stamp makes every second save fail its
  own precondition.

  The two resource kinds fold content in differently and must not be mixed:
  `etag_update()` includes each record's length (data sets — the same bytes
  re-split are a different resource), `etag_update_raw()` does not (USS — a
  byte stream, where the read buffer size is an artefact and must not reach the
  value). On USS the precondition also runs *before* the truncating `"w"` open,
  which is why a directory is probed with `ufs_stat()` and falls through to the
  write path rather than being reported as a stale 412 — adding `If-Match` must
  not change how a non-file path is answered. That answer is the **400 ISDIR**
  the row below promises — since #269, and it stays `ufs_stat()` here on
  purpose: the write path may read its diagnosis off `ufs_last_rc()`, but a
  stale value in *this* check would skip a precondition silently, which is the
  one failure the feature exists to prevent.

  The **read** side needs no such probe and must not grow one: a failed hash
  there already means "no ETag, let the open below diagnose it", so a directory
  reaches the same 400 ISDIR it would without the header, and a missing file
  the same 404. That is what keeps `If-None-Match: *` — which is a 304 for any
  file that exists — from turning either of them into a 304.
