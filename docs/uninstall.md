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

Every `DEL` reports `HMA2550 UPDATE COMPLETE`. The `LIST` at the end is the
check: **RC 04 with the id reported as not found means it is free.** A hit
prints `TYPE`, `STATUS` and the FMID it belongs to — the id is still taken.

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

<!-- MEASURE: what the job above does on such a system: return codes, which DEL
     fail, what LIST shows afterwards -->

Ask SMP which id the system carries:

```
 LIST CDS MOD(MVSMF) .
```

`FMID = TZMF150` (or any other id that is not in the job above) means that you
are in the right section. Run the job above with three changes:

1. The owner of the module is the development id: in both zones, the first
   `DEL` statement names `TZMF150` instead of `TZMF140`.
2. `DEL SYSMOD(TZMF150) .` is added in both zones, above the one for
   `TZMF140`.
3. `LIST CDS SYSMOD(TZMF150) .` and `LIST ACDS SYSMOD(TZMF150) .` are added to
   the `LIST` step. It has ten statements then, and every one of them must show
   its id as not found.

<!-- MEASURE: the modified job: UCLIN return codes and messages per zone, the
     LIST, LIST CDS/ACDS MOD(MVSMF) afterwards -->

If a release is to follow, leave out steps 2 and 3: the configuration stays, and
the install job of the release package copies into the libraries that exist.
**Do not run the allocation job `MVSMFALC`**; it allocates the libraries `NEW`
and fails on libraries that exist. `UCLIN` has not touched the libraries: until
the release is installed, `MVSMF.LINKLIB` still holds the module of the
development build. After the install, list the members of `MVSMF.LINKLIB`, look
for the `HMA2380` line (see [installation.md](installation.md)), and check that
`LIST CDS MOD(MVSMF) .` shows the `FMID` of the release and not `TZMF150`.

<!-- MEASURE: the release install over the cleaned system, and the control run
     of the release installed over the development build without this section -->

**What has not been measured.** <!-- MEASURE: replace after the runs -->

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
