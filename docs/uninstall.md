# Removing mvsMF

This removes mvsMF from an MVS 3.8j system: the SMP inventory entries, then the
data sets, then the two configuration changes the install made.

**This is for *removing* the product. It is not the way to upgrade.** From
1.2.0 onwards each release's SYSMOD deletes its predecessor, so an upgrade is
just RECEIVE/APPLY/ACCEPT of the new package — and running the `DELETE` step
below in between scratches the data sets the new install is about to use.

## Why UCLIN and not RESTORE/REJECT

Both are refused once the FMID has been accepted, and the install job accepts
it in the same run as the APPLY (`accept_fmid = true`, so a later PTF can be
RESTOREd). `UCLIN` edits the inventory directly and is the only way back.

## 1. Free the inventory entries

`MVSMF` is the only module, which makes this short. Delete the **element**
entries, not just the SYSMOD: SMP keys element ownership on `MOD(name)`, so a
SYSMOD id that is free while `MOD(MVSMF)` still belongs to someone else buys
nothing — a later install would report `NOT SEL` and copy nothing at RC 00.

Both zones need their own block: `CDS` is the target zone, `ACDS` the
distribution zone. Skip one and the id survives there.

```jcl
//MVSMFUCL JOB (SYS),'MVSMF UNINSTALL',
//             CLASS=A,MSGCLASS=H,MSGLEVEL=(1,1),
//             REGION=4096K
//UCLIN   EXEC SMPAPP
//SMPCNTL  DD  *
 UCLIN CDS .
  DEL SYSMOD(TZMF140) MOD(MVSMF) .
  DEL MOD(MVSMF) .
  DEL LMOD(MVSMF) .
  DEL SYSMOD(TZMF140) .
  DEL SYSMOD(TZMF130) .
  DEL SYSMOD(TZMF120) .
  DEL SYSMOD(TZMF110) .
 ENDUCL .
 RESETRC .
 UCLIN ACDS .
  DEL SYSMOD(TZMF140) MOD(MVSMF) .
  DEL MOD(MVSMF) .
  DEL SYSMOD(TZMF140) .
  DEL SYSMOD(TZMF130) .
  DEL SYSMOD(TZMF120) .
  DEL SYSMOD(TZMF110) .
 ENDUCL .
/*
//LIST    EXEC SMPAPP
//SMPCNTL  DD  *
 RESETRC .
 LIST CDS  SYSMOD(TZMF140) .
 LIST ACDS SYSMOD(TZMF140) .
 LIST CDS  SYSMOD(TZMF130) .
 LIST ACDS SYSMOD(TZMF130) .
 LIST CDS  SYSMOD(TZMF120) .
 LIST ACDS SYSMOD(TZMF120) .
 LIST CDS  SYSMOD(TZMF110) .
 LIST ACDS SYSMOD(TZMF110) .
/*
//
```

A `DEL` that finds its entry reports `HMA2550 UPDATE COMPLETE`. A `DEL` for an
id that the system never held reports `HMA2532 ** SYSMOD ENTRY … TO BE DELETED
DOES NOT EXIST` and `HMA2560 UPDATE PROCESSING TERMINATED`, and the `UCLIN`
block ends with RC 08. That is no fault: the id is free. A system that has only
ever held 1.4.0 has no `TZMF110`, so the job above ends with RC 08 there.

**Keep the `RESETRC` between the two blocks.** Without it, SMP ignores the
whole `UCLIN ACDS` block after the RC 08 of the first one (`HMA2293 ** CONTROL
STATEMENT IGNORED DUE TO PREVIOUS ERROR`, RC 12), and the distribution zone
keeps its entries.

The `LIST` at the end is the check: **RC 04 with the id reported as not found
means it is free.** A hit prints `TYPE`, `STATUS` and the FMID it belongs to —
the id is still taken.

**Name every level that was ever installed on the system, not only the current
one.** The block above lists `TZMF140`, `TZMF130`, `TZMF120` and `TZMF110`; add a pair for each
further level if the system has seen more. A level that an upgrade already
deleted is left as a tombstone — `TYPE = FUNCTION / DELBY = …` — which `LIST`
reports at **RC 00**, so it still reads as occupied and still has to go.

1.0.0 and 1.0.1 shipped without a `[distribution]` and were never
SMP-installed, so there is nothing below `TZMF110`.

`LMOD` exists only in the CDS; there is nothing to delete for it in the ACDS.

### A development build with a later FMID

A development build of `main` is packaged under the FMID of the release that
`main` is heading for. A build of 1.5.0-dev carries `TZMF150`, although 1.5.0 is
not released. If you installed such a package by SMP, the system holds an id
that the job above does not name, and that id owns `MOD(MVSMF)`. The job cannot
free it. A package that was built with a throwaway id of its own (`[smp] fmid`
in `mbt.toml`) is the same case with another name. Wherever this section says
`TZMF150`, read your id.

The job above does not clean such a system. On a system that holds `TZMF150`,
its first statement fails in the target zone:

```
  DEL SYSMOD(TZMF140) MOD(MVSMF) .
HMA3572 ** MOD MVSMF TO BE DELETED FROM ENTRY DOES NOT EXIST
HMA2560    UPDATE PROCESSING TERMINATED - UPDATE NOT COMPLETE
```

The statements after it still run. `DEL MOD(MVSMF)` and `DEL LMOD(MVSMF)` remove
the module and the load module entry although `TZMF150` owns them, and
`SYSMOD TZMF150` stays in the target zone with status `REC APP ACC`. The id
that owns the module is not freed.

Ask SMP which id the system carries:

```jcl
//MVSMFQRY JOB (SYS),'MVSMF QUERY',
//             CLASS=A,MSGCLASS=H,MSGLEVEL=(1,1),
//             REGION=4096K
//LIST    EXEC SMPAPP
//SMPCNTL  DD  *
 LIST CDS  MOD(MVSMF) .
 LIST ACDS MOD(MVSMF) .
/*
//
```

The releases of mvsMF that SMP installs are `TZMF110`, `TZMF120`, `TZMF130` and
`TZMF140`. If `FMID` is one of them, the job above is the one to run. Any other
`FMID` (`TZMF150` for a build of 1.5.0-dev) means that you are in this section.
On a system that holds the development build the output reads:

```
 LIST CDS  MOD(MVSMF) .
SMPCDS  MODULE ENTRIES
  NAME
MVSMF     LASTUPD         = TZMF150  TYPE=ADD
          LIBRARIES       = DISTLIB=AMVSMFLD
          FMID            = TZMF150
          RMID            = TZMF150
          LMOD            = MVSMF
```

Run the job above with three changes:

1. The owner of the module is the development id: in both zones, the first
   `DEL` statement names `TZMF150` instead of `TZMF140`.
2. `DEL SYSMOD(TZMF150) .` is added in both zones, above the one for
   `TZMF140`.
3. `LIST CDS SYSMOD(TZMF150) .` and `LIST ACDS SYSMOD(TZMF150) .` are added to
   the `LIST` step. It has ten statements then, and every one of them must show
   its id as not found.

The modified job, on a system that held 1.4.0 and then the development build
`TZMF150`, ends with RC 08. Both `UCLIN` blocks run to the end. The RC 08 comes
only from the ids the system never held (`TZMF110`, and on some systems
`TZMF120` too); every other `DEL` reports `HMA2550`:

```
 UCLIN CDS .
  DEL SYSMOD(TZMF150) MOD(MVSMF) .
HMA2550    UPDATE COMPLETE FOR TZMF150
  DEL MOD(MVSMF) .
HMA2550    UPDATE COMPLETE FOR MVSMF
  DEL LMOD(MVSMF) .
HMA2550    UPDATE COMPLETE FOR MVSMF
  DEL SYSMOD(TZMF150) .
HMA2550    UPDATE COMPLETE FOR TZMF150
  DEL SYSMOD(TZMF140) .
HMA2550    UPDATE COMPLETE FOR TZMF140
  DEL SYSMOD(TZMF130) .
HMA2550    UPDATE COMPLETE FOR TZMF130
  DEL SYSMOD(TZMF120) .
HMA2550    UPDATE COMPLETE FOR TZMF120
  DEL SYSMOD(TZMF110) .
HMA2532 ** SYSMOD ENTRY TZMF110 TO BE DELETED DOES NOT EXIST
HMA2560    UPDATE PROCESSING TERMINATED - UPDATE NOT COMPLETE
 ENDUCL .
HMA2050    UCLIN PROCESSING COMPLETED - HIGHEST RETURN CODE IS 08
 RESETRC .
HMA2050    RESETRC PROCESSING COMPLETED - HIGHEST RETURN CODE IS 00
 UCLIN ACDS .
```

The `UCLIN ACDS` block reports the same. All ten `LIST` statements then end
with RC 04 and the id reported as not found, and so do `LIST CDS MOD(MVSMF) .`,
`LIST ACDS MOD(MVSMF) .` and `LIST CDS LMOD(MVSMF) .`.

**Without the `RESETRC` between the blocks the section fails.** The `UCLIN ACDS`
block is then ignored (`HMA2293`, RC 12), and the distribution zone keeps
`MOD(MVSMF)` with `FMID = TZMF150`, `TZMF150` and the tombstones. The target
zone is clean, the distribution zone is not.

If a release is to follow, leave out sections 2 and 3 below: the configuration
stays, and the install job of the release package copies into the libraries that
exist. If the product is to go away, continue with sections 2 and 3 as for a
release; that path has not been run after a development build.
**Do not run the allocation job `MVSMFALC`**; it allocates the libraries `NEW`
and fails on libraries that exist. `UCLIN` has not touched the libraries: until
the release is installed, `MVSMF.LINKLIB` still holds the module of the
development build. After the install, list the members of `MVSMF.LINKLIB`, look
for the `HMA2380` line (see [installation.md](installation.md)), and check that
`LIST CDS MOD(MVSMF) .` shows the `FMID` of the release and not `TZMF150`.

The release install over the cleaned system (1.4.0, install job without
`MVSMFALC`) ends with RC 00. `APPLY` and `ACCEPT` complete, and `HMA2380`
reports the copy into both libraries:

```
HMA2380    COPY SUCCESSFUL - MOD=MVSMF - LMOD=MVSMF - LIBRARY=LINKLIB - SYSMOD=TZMF140 - RETURN CODE=00
HMA2380    COPY SUCCESSFUL - MOD=MVSMF - LMOD=MVSMF - LIBRARY=AMVSMFLD - SYSMOD=TZMF140 - RETURN CODE=00
```

`MVSMF.LINKLIB` and `MVSMF.AMVSMFLD` each hold the member `MVSMF`;
`MVSMF.SAMPLIB` holds `MVSMFPRM` and `MVSMFSTC`. In both zones
`LIST … MOD(MVSMF) .` now shows `FMID = TZMF140` and `RMID = TZMF140`. After
the install `TZMF130` shows as a tombstone (`DELBY = TZMF140`) in both zones: a
hit at RC 00. That is the state of a release, not a leftover.

**Without this section the release does not install over a development
build.** `APPLY` stops with

```
HMA3792 ** SYSMOD TZMF140 SELECTED FOR APPLY IS DELETED
HMA3703 ** APPLY PROCESSING TERMINATED BECAUSE FUNCTION SYSMOD TZMF140 FAILED
```

and the job ends with RC 12. Nothing is installed: the development build keeps
running and `LIST CDS MOD(MVSMF) .` still shows `FMID = TZMF150`. The reason is
that `TZMF150` has deleted `TZMF140` in the inventory. A failure that is this
loud is easy to read; the one below is not.

**Do not clean the target zone only.** If the `UCLIN CDS` block runs and the
`UCLIN ACDS` block does not (the missing `RESETRC` above), the release install
ends with `APPLY` at RC 00 and the new `MVSMF` in `MVSMF.LINKLIB`, and then
`ACCEPT` fails with `HMA3792 ** SYSMOD TZMF140 SELECTED FOR ACCEPT IS DELETED`,
RC 12. The target zone then says `FMID = TZMF140`, while the distribution zone
still says `FMID = TZMF150`, and `MVSMF.AMVSMFLD` got no `HMA2380` line.
After every install, check the `ACCEPT` return code and the `HMA2380` line
for `AMVSMFLD` too, not only the `APPLY`.

On the TK5 system, `GET /zosmf/info` reports `zosmf_full_version` as
`1.5.0-dev` while the development build is in place and as `1.4.0` after the
release install. On the MVS/CE system the value stayed `1.3.0` throughout, so
the member lists, the `HMA2380` lines and the `LIST` are the check there.

**`MVSMF.DEV.LINKLIB` is not part of this.** `mbt deploy` writes to it, SMP does
not know it, and neither the `UCLIN` job nor the release install touches it.
If your `HTTPD` procedure names it in the `STEPLIB` ahead of `MVSMF.LINKLIB`,
HTTPD keeps loading the development build after the release is installed. Read
the `STEPLIB` and take the library out of it, or scratch it, before you judge
the result. The runs did not use a development library.

**What was measured on.** Two test systems. The TK5 system held 1.3.0 by SMP
(`TZMF130`, with `TZMF120` as its tombstone). The MVS/CE system held no mvsMF
entry in SMP, and its libraries were allocated with `MVSMFALC` before the first
install. On both, 1.4.0 was installed by SMP from its release package, then the
development build over it. A missing id in a `UCLIN` block did not stop the
statements after it (`TZMF120` followed by `TZMF110` on the MVS/CE system).

**What has not been measured.** A system with an older history than `TZMF110`.
A second development build installed over the first. A development build under
another throwaway id than `TZMF150`. The removal of the product after a
development build (sections 2 and 3). A production system.

## 2. Undo the configuration

Both changes have to go, and in this order.

**Take the routes out of the httpd parmlib member** (`//HTTPPRM`) — the four
`MOD=MVSMF` lines. A route pointing at a module that is gone answers
`HTTPD908E EXTERNAL PROGRAM … could not be loaded`, and that message blames the
STEPLIB whatever the real cause was.

**The profile `FACILITY MVSMF.CONSOLE` stays in `SYS1.SECURE.CNTL(PROFILES)`**
after the uninstall. Nothing reads it any more. Remove it with
`RDELETE MVSMF.CONSOLE CLASS(FACILITY)` (without `ID(...)` this deletes the
universal line and every group line of the resource) and reload with
`S RAKFPROF`.

**Take `MVSMF.LINKLIB` out of the HTTPD procedure's STEPLIB concatenation.**
A STEPLIB naming a data set that no longer exists stops the started task from
starting at all.

Then `P HTTPD` / `S HTTPD`.

If you added an APF entry to `SYS1.PARMLIB(IEAAPF00)`, leaving it is harmless — it names a data
set that no longer exists and authorizes nothing — but removing it keeps the
member honest. That part needs an IPL, so it can wait for the next one.

## 3. Scratch the data sets

**Only when the product is going away for good.** Check the names against what
`MVSMFALC` actually allocated before running this.

```jcl
//MVSMFDEL JOB (SYS),'MVSMF DELETE',
//             CLASS=A,MSGCLASS=H,MSGLEVEL=(1,1)
//DELETE  EXEC PGM=IDCAMS
//SYSPRINT DD  SYSOUT=*
//SYSIN    DD  *
  DELETE MVSMF.LINKLIB
  DELETE MVSMF.AMVSMFLD
  DELETE MVSMF.MVSMFLOD
  DELETE MVSMF.SAMPLIB
  SET MAXCC = 0
/*
//
```

`SET MAXCC = 0` is there so a data set that was never allocated does not fail
the job.

## What this does not touch

Nothing mvsMF wrote through its own API: data sets created by
`POST /zosmf/restfiles/ds`, jobs submitted through `PUT /zosmf/restjobs/jobs`,
USS files in the UFSD container. Those belong to whoever created them.
