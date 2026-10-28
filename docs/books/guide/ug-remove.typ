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

#note[If you installed a development build of the main branch with SMP, its
FMID is a later one than the jobs of this chapter name (#cmd("TZMF150") for a
build of 1.5.0-dev). Go to @ug-remove-dev first.]

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
not the system ever held the release. An id that an upgrade deleted is not gone: the zone keeps an
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
//
```

A #cmd("DEL") that finds its entry reports #cmd("HMA2550 UPDATE COMPLETE"). A
#cmd("DEL") for an id that the system never held reports #cmd("HMA2532") and
#cmd("HMA2560"), and the #cmd("UCLIN") block ends with return code 08. That is
no fault: the id is free, and the statements after it still run. A system that
has only ever held 1.4.0 has no #cmd("TZMF110"), so the job above ends with
return code 08 there. This is its output:

#screen(raw(read("../ex/ug-remove/uclin-release.txt"), block: true))

*Keep the #cmd("RESETRC") between the two blocks.* Without it, SMP ignores the
whole #cmd("UCLIN ACDS") block after the return code 08 of the first one
(#cmd("HMA2293 ** CONTROL STATEMENT IGNORED DUE TO PREVIOUS ERROR"), return code
12), and the distribution zone keeps its entries. The job gives no other sign.

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

== You Installed a Development Build with a Later FMID <ug-remove-dev>

#idx("development build")#idx("TZMF150")#idx("FMID", "development build")
A development build of the main branch was packaged under the FMID of the
release that the branch is heading for. A build of 1.5.0-dev carried
#cmd("TZMF150"), although 1.5.0 is not released. A current #cmd("mbt") refuses
to package a pre-release without an FMID of its own, so a package of this kind
comes from an older #cmd("mbt"). If you installed such a package with SMP, the
system holds an id that the job of @ug-remove-uclin does not name, and that id
owns #cmd("MOD(MVSMF)"). The job cannot free it. A package that was built with a
throwaway id of its own is the same case with another name. Wherever this
section says #cmd("TZMF150"), read your id.

On a system that holds #cmd("TZMF150"), the first statement of the job fails in
the target zone. #cmd("TZMF140") does not own the module:

#screen(raw(read("../ex/ug-remove/dev-fail.txt"), block: true))

The statements after it still run. #cmd("DEL MOD(MVSMF)") and
#cmd("DEL LMOD(MVSMF)") remove the module and the load module entry although
#cmd("TZMF150") owns them, and #cmd("SYSMOD TZMF150") stays in the target zone
with the status #cmd("REC APP ACC"). The id that owns the module is not freed.

=== Detecting the Development Build

Ask SMP which id owns the module:

```
//MVSMFQRY JOB (SYS),'MVSMF QUERY',
//             CLASS=A,MSGCLASS=H,MSGLEVEL=(1,1),
//             REGION=4096K
//LIST    EXEC SMPAPP
//SMPCNTL  DD *
 LIST CDS  MOD(MVSMF) .
 LIST ACDS MOD(MVSMF) .
/*
//
```

The releases of mvsMF that SMP installs are #cmd("TZMF110"), #cmd("TZMF120"),
#cmd("TZMF130") and #cmd("TZMF140"). If #cmd("FMID") is one of them, the job of
@ug-remove-uclin is the one to run. Any other #cmd("FMID") means that you are
in this section. On a system that holds the development build the output reads:

#screen(raw(read("../ex/ug-remove/dev-owner-before.txt"), block: true))

=== Freeing the Ids

Run the job of @ug-remove-uclin with three changes:

+ The owner of the module is the development id. In both zones, the first
  #cmd("DEL") statement names #cmd("TZMF150") instead of #cmd("TZMF140").
+ #cmd("DEL SYSMOD(TZMF150) .") is added in both zones, above the one for
  #cmd("TZMF140").
+ #cmd("LIST CDS SYSMOD(TZMF150) .") and #cmd("LIST ACDS SYSMOD(TZMF150) .") are
  added to the #cmd("LIST") step of @ug-remove-check. It has ten statements
  then, and every one of them must show its id as not found.

Keep the #cmd("RESETRC") between the two #cmd("UCLIN") blocks. On a system that
held 1.4.0 and then the development build, the job ends with return code 08.
Both blocks run to the end. The 08 comes only from ids that the system never
held: #cmd("TZMF110") on the TK5 system, and #cmd("TZMF120") as well on the
MVS/CE system. Every other #cmd("DEL") reports #cmd("HMA2550"). This is the
target zone of the TK5 system:

#screen(raw(read("../ex/ug-remove/dev-uclcds.txt"), block: true))

The #cmd("UCLIN ACDS") block reports the same, without the statement for
#cmd("LMOD"). Then read the ten #cmd("LIST") statements as in
@ug-remove-check. These are the first two:

#screen(raw(read("../ex/ug-remove/dev-list-gone.txt"), block: true))

All ten end with return code 04 and the id reported as not found, and so do
#cmd("LIST CDS MOD(MVSMF)"), #cmd("LIST ACDS MOD(MVSMF)") and
#cmd("LIST CDS LMOD(MVSMF)").

*Without the #cmd("RESETRC") between the blocks this section fails.* The
#cmd("UCLIN ACDS") block is then ignored, and the distribution zone keeps
#cmd("MOD(MVSMF)") with #cmd("FMID = TZMF150"), #cmd("TZMF150") and the marks of
the older releases. The target zone is clean, the distribution zone is not:

#screen(raw(read("../ex/ug-remove/dev-noresetrc.txt"), block: true))

=== Installing the Release Afterwards

If a release is to follow, do not undo the configuration and do not scratch the
libraries (@ug-remove-config, @ug-remove-delete). The configuration stays, and
the install job of the release package copies into the libraries that exist.
*Do not run the allocation job #cmd("MVSMFALC")* (@ug-install-alloc). A new
allocation of an existing name fails. #cmd("UCLIN") has not touched the libraries. Until the
release is installed, #cmd("MVSMF.LINKLIB") still holds the module of the
development build.

The install of 1.4.0 over the cleaned system, with the install job and without
#cmd("MVSMFALC"), ends with return code 00. #cmd("APPLY") and #cmd("ACCEPT")
complete, and #cmd("HMA2380") reports the copy into both libraries. The apply
prints:

#screen(raw(read("../ex/ug-remove/dev-install-apply.txt"), block: true))

The accept prints the same line with #cmd("LIBRARY=AMVSMFLD"). Then check the
result as in @ug-install-check, in both zones. #cmd("MVSMF.LINKLIB") and
#cmd("MVSMF.AMVSMFLD") each hold the member #cmd("MVSMF"), and
#cmd("MVSMF.SAMPLIB") holds #cmd("MVSMFPRM") and #cmd("MVSMFSTC"). The two
#cmd("LIST") statements show the release as the owner of the module and not
#cmd("TZMF150"):

#screen(raw(read("../ex/ug-remove/dev-owner.txt"), block: true))

After the install, #cmd("TZMF130") shows in both zones as an entry of the type
#cmd("FUNCTION") with #cmd("DELBY = TZMF140"), and a #cmd("LIST") of it ends with
return code 00. That is the mark that a release leaves for its predecessor
(@ug-remove-uclin), not a leftover of the development build.

*Without this section the release does not install over a development build.*
The development build deleted #cmd("TZMF140") in the inventory. The apply stops
and the job ends with return code 12. Nothing is installed: the development build
keeps running, and #cmd("LIST CDS MOD(MVSMF)") still shows
#cmd("FMID = TZMF150"):

#screen(raw(read("../ex/ug-remove/dev-control-apply.txt"), block: true))

*Do not clean the target zone only.* If the #cmd("UCLIN CDS") block ran and the
#cmd("UCLIN ACDS") block did not (the missing #cmd("RESETRC") above), the
release install is quieter. The #cmd("APPLY") ends with return code 00 and puts
the new #cmd("MVSMF") into #cmd("MVSMF.LINKLIB"). Then the #cmd("ACCEPT") fails:

#screen(raw(read("../ex/ug-remove/dev-cdsonly-accept.txt"), block: true))

The target zone says #cmd("FMID = TZMF140"), while the distribution zone still
says #cmd("FMID = TZMF150"), and #cmd("MVSMF.AMVSMFLD") got no #cmd("HMA2380")
line. After every install, check the return code of the #cmd("ACCEPT") and the
#cmd("HMA2380") line for #cmd("AMVSMFLD"), not only those of the #cmd("APPLY").

=== The Running Build and the Development Library

On the TK5 system, #cmd("GET /zosmf/info") reported #cmd("zosmf_full_version")
as #cmd("1.5.0-dev") while the development build was in place, and as
#cmd("1.4.0") after the release install (@ug-ops-build). On the MVS/CE system the
value stayed #cmd("1.3.0") throughout. There the member lists, the
#cmd("HMA2380") lines and the #cmd("LIST") are the check.

#cmd("MVSMF.DEV.LINKLIB") is not part of any of this. #cmd("mbt deploy") writes
to it. SMP does not know it, and neither the #cmd("UCLIN") job nor the release
install touches it. If your HTTPD procedure names it in the STEPLIB ahead of
#cmd("MVSMF.LINKLIB"), HTTPD keeps loading the development build after the
release is installed. Read the STEPLIB, and take the library out of it or
scratch it, before you judge the result. The runs did not use a development
library.

=== What Was Measured

Two test systems. The TK5 system held 1.3.0 by SMP (#cmd("TZMF130"), with
#cmd("TZMF120") as its mark). The MVS/CE system held no mvsMF entry in SMP, and
its libraries were allocated with #cmd("MVSMFALC") before the first install. On
both, 1.4.0 was installed by SMP from its release package, and then the
development build over it. A missing id in a #cmd("UCLIN") block did not stop
the statements after it (#cmd("TZMF120") followed by #cmd("TZMF110") on the
MVS/CE system).

*What has not been measured.* A system with an older history than
#cmd("TZMF110"). A second development build installed over the first. A
development build under another throwaway id than #cmd("TZMF150"). The removal
of the product after a development build, that is this section followed by
@ug-remove-config and @ug-remove-delete. A production system.

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

SMP never owned #cmd("MVSMF.DEV.LINKLIB"), the library that #cmd("mbt deploy")
writes a development build to. Neither this chapter nor the install of a release
clears it. Scratch it yourself when you no longer need it
(@ug-remove-dev).
