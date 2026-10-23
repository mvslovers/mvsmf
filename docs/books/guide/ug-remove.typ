#import "../bookmaster/bookmaster.typ": *

= Removing mvsMF <ug-remove>

#idx("removal")#idx("uninstall")
This chapter removes mvsMF (mvsmf) from a system. It frees the entries of
SMP4, takes the two changes of the installation out of the configuration of
HTTPD (httpd), and scratches the data sets. The chapter is for a product that
goes away. It is not the way to upgrade.

#note[An upgrade is the RECEIVE, APPLY and ACCEPT of the new package
(@ug-install-upgrade). The SYSMOD of a release deletes the SYSMOD of its
predecessor. If you run the data set deletion of this chapter in between, you
scratch the libraries the new install writes to.]

== Why UCLIN <ug-remove-why>

#idx("UCLIN")#idx("REJECT")
The install job accepts the SYSMOD in the same run as the APPLY. After the
ACCEPT, #cmd("REJECT") no longer works. The #cmd("UCLIN") statements edit the
inventory directly. They are the way back.

== Freeing the Inventory <ug-remove-uclin>

#idx("UCLIN", "removal")#idx("TZMF140")#idx("FMID", "spent ids")
The module #cmd("MVSMF") is the only element of the product. Delete the
element entries as well as the SYSMOD entries. SMP4 keys the ownership of an
element on #cmd("MOD(MVSMF)"). If the SYSMOD id is free and the module still
belongs to another SYSMOD, a later install reports #cmd("NOT SEL") and copies
nothing, and every step ends with return code 0.

Each of the two zones needs its own block. #cmd("CDS") is the target zone and
#cmd("ACDS") is the distribution zone. The entry for the load module,
#cmd("LMOD(MVSMF)"), exists in the target zone only.

#tab(caption: [The SYSMOD ids of mvsMF])[
  #table(columns: (1.2in, 1.2in, 1fr),
    [SYSMOD], [mvsMF release], [Note],
    [#cmd("TZMF140")], [1.4.0], [The current release. It deletes #cmd("TZMF130").],
    [#cmd("TZMF130")], [1.3.0], [Spent.],
    [#cmd("TZMF120")], [1.2.0], [Spent.],
    [#cmd("TZMF110")], [1.1.0], [Spent. The oldest release that SMP4 installed.],
  )
]

Each id is used once and never again. Name every id in both zones, whether or
not the system ever held the release. An id that the system never saw reports
nothing to do. An id that an upgrade deleted is not gone: the zone keeps an
entry of the type #cmd("FUNCTION") that says the next release deleted it. One
such entry remains per upgrade. If the job names only the current release and
its predecessor, older entries stay in the zone, and no message reports them.

This job removes all four ids from both zones:

```
//MVSMFUCL JOB (SYS),'MVSMF UNINSTALL',
//             CLASS=A,MSGCLASS=H,MSGLEVEL=(1,1),
//             REGION=4096K
//UCLIN   EXEC SMPAPP
//SMPCNTL  DD *
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
//
```

== Checking the Inventory <ug-remove-check>

#idx("LIST", "removal")
Do not stop at the return code of the UCLIN job. A return code says that the
job ran, not that the work happened. Run a #cmd("LIST") for every id in both
zones:

```
//MVSMFLST JOB (SYS),'MVSMF LIST',
//             CLASS=A,MSGCLASS=H,MSGLEVEL=(1,1)
//LIST    EXEC SMPAPP
//SMPCNTL  DD *
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

An id is free when its #cmd("LIST") ends with return code 4 and an empty list.
If the list prints the id, the id is still in the zone. An id that is in use
prints its type, its status and an FMID. The entry of a deleted release prints
the type #cmd("FUNCTION") and the entry #cmd("DELBY"), and SMP4 answers it with
return code 0. Read the output, not the return code.

== Undoing the Configuration <ug-remove-config>

#idx("HTTPPRM", "removal")#idx("STEPLIB", "removal")#idx("APF", "removal")
The installation changed two things in the configuration of HTTPD
(@ug-install-steplib, @ug-install-routes). Undo them in this order.

+ Take the four #cmd("MOD=MVSMF") route lines out of the member that the
  DD #cmd("HTTPPRM") of the HTTPD procedure names. A route that names a
  module HTTPD cannot load answers 503 and writes the message
  #cmd("HTTPD908E") with the text that the module could not be loaded. The
  message does not say why.
+ Take #cmd("MVSMF.LINKLIB") out of the STEPLIB concatenation of the HTTPD
  procedure.
+ Stop HTTPD with #cmd("/P HTTPD") and start it again.

HTTPD reads the STEPLIB and the route lines when it starts (@ug-ops-replace).
The running server keeps its old configuration until the restart.

If you added #cmd("MVSMF.LINKLIB") to the list of authorized libraries in
#cmd("SYS1.PARMLIB(IEAAPF00)"), the entry may stay. It names a data set that
does not exist. Remove it at the next IPL, because the member is read at IPL.
A data set that a later job allocates under the same name on the same volume
may inherit the authorization.

== Scratching the Data Sets <ug-remove-delete>

#idx("MVSMF.LINKLIB", "removal")#idx("IDCAMS")
Run this job only when the product goes away for good. Compare the names with
the names that the allocation job of the package used (@ug-install-alloc).

```
//MVSMFDEL JOB (SYS),'MVSMF DELETE',
//             CLASS=A,MSGCLASS=H,MSGLEVEL=(1,1)
//DELETE  EXEC PGM=IDCAMS
//SYSPRINT DD SYSOUT=*
//SYSIN    DD *
  DELETE MVSMF.LINKLIB
  DELETE MVSMF.AMVSMFLD
  DELETE MVSMF.MVSMFLOD
  DELETE MVSMF.SAMPLIB
  SET MAXCC = 0
/*
//
```

The install job scratches #cmd("MVSMF.MVSMFLOD") in its last step, so the data
set is there only after an install that stopped early. The statement
#cmd("SET MAXCC = 0") keeps the job from failing for a data set that does not
exist. Because of it, the return code does not tell you whether a data set
went away. Read the messages of IDCAMS, and list the catalog for the level
#cmd("MVSMF") to see that no data set remains.

== What Removal Leaves <ug-remove-left>

Removal does not touch what mvsMF wrote for its users through its own
services. The data sets that clients created, the jobs that clients
submitted, and the files in the UFSD container belong to the users who
created them. The SMP package has no files for the UFS, so removal leaves none
of its own there.
