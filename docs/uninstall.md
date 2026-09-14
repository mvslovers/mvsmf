# Removing mvsMF

This removes mvsMF from an MVS 3.8j system: the SMP inventory entries, then the
data sets, then the two configuration changes the install made.

**This is for *removing* the product. It is not the way to upgrade.** From
1.1.1 onwards each release's SYSMOD deletes its predecessor, so an upgrade is
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
  DEL SYSMOD(TZMF110) MOD(MVSMF) .
  DEL MOD(MVSMF) .
  DEL LMOD(MVSMF) .
  DEL SYSMOD(TZMF110) .
 ENDUCL .
 UCLIN ACDS .
  DEL SYSMOD(TZMF110) MOD(MVSMF) .
  DEL MOD(MVSMF) .
  DEL SYSMOD(TZMF110) .
 ENDUCL .
/*
//LIST    EXEC SMPAPP
//SMPCNTL  DD  *
 RESETRC .
 LIST CDS  SYSMOD(TZMF110) .
 LIST ACDS SYSMOD(TZMF110) .
/*
//
```

Every `DEL` reports `HMA2550 UPDATE COMPLETE`. The `LIST` at the end is the
check: **RC 04 with the id reported as not found means it is free.** A hit
prints `TYPE`, `STATUS` and the FMID it belongs to — the id is still taken.

Add a `DEL SYSMOD(...)` pair for every level that was ever installed on the
system, not only the current one. Today that is `TZMF110` alone, since 1.0.0
and 1.0.1 shipped without a `[distribution]` and were never SMP-installed.

`LMOD` exists only in the CDS; there is nothing to delete for it in the ACDS.

## 2. Undo the configuration

Both changes have to go, and in this order.

**Take the routes out of the httpd parmlib member** (`//HTTPPRM`) — the three
`MOD=MVSMF` lines. A route pointing at a module that is gone answers
`HTTPD908E EXTERNAL PROGRAM … could not be loaded`, and that message blames the
STEPLIB whatever the real cause was.

**Take `MVSMF.LINKLIB` out of the HTTPD procedure's STEPLIB concatenation.**
A STEPLIB naming a data set that no longer exists stops the started task from
starting at all.

Then `P HTTPD` / `S HTTPD`.

Leaving the APF entry in `SYS1.PARMLIB(IEAAPF00)` is harmless — it names a data
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
