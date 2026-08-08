//MVSMFACT JOB (ACCT),'ACTIVATE MVSMF',CLASS=A,MSGCLASS=H,
//         NOTIFY=&SYSUID
//*
//* Compress the httpd STEPLIB and copy a freshly deployed MVSMF
//* into it.
//*
//* WHY THIS EXISTS
//*   `make deploy` RECEIVEs the load module into the deploy
//*   LINKLIB and stops there -- it does not touch the running
//*   server. httpd loads the CGI fresh per request from its own
//*   STEPLIB, so copying the member there activates a new build
//*   with no httpd restart.
//*
//*   That STEPLIB fills up. Every replace-copy orphans the old
//*   member's space, and once the data set is at its extent
//*   limit the copy fails IEF450I ... ABEND SE37. That failure
//*   is clean -- it abends before writing, so the existing
//*   member and the running server are unharmed -- but nothing
//*   is activated until the library is compressed.
//*
//* BEFORE YOU SUBMIT
//*   Both steps use DISP=OLD, because IEBCOPY COMPRESS cannot
//*   run against a library httpd holds SHR through its STEPLIB.
//*   The job therefore WAITS in the enqueue until httpd releases
//*   it. Either stop httpd first, or submit this and then stop
//*   httpd -- it starts the moment the STC ends. Note that a
//*   waiting job occupies an initiator.
//*
//*     P HTTPD          (3270 / console)
//*     <this job runs>
//*     S HTTPD
//*
//* CHECK THE NAMES
//*   Both data sets below are installation-specific. The STEPLIB
//*   name differs per stand -- it has been HTTPD.LINKLIB and
//*   HTTPD.LINKLIBT on different systems, so confirm which one
//*   holds the MVSMF member before submitting:
//*
//*     GET /zosmf/restfiles/ds?dslevel=HTTPD
//*     GET /zosmf/restfiles/ds/<candidate>/member
//*
//*   The deploy library is the one `make deploy` reports as its
//*   target, built from MBT_MVS_HLQ in .env.
//*
//* AFTERWARDS
//*   GET /zosmf/test?fn=version returns the git hash the live
//*   module was built from. IEBCOPY also prints IEB144I with the
//*   tracks left, which is the early warning for the next SE37.
//*
//COMPRESS EXEC PGM=IEBCOPY
//SYSPRINT DD SYSOUT=*
//LIB      DD DSN=HTTPD.LINKLIB,DISP=OLD
//SYSIN    DD *
  COPY INDD=LIB,OUTDD=LIB
/*
//ACTIVATE EXEC PGM=IEBCOPY
//SYSPRINT DD SYSOUT=*
//IN       DD DSN=IBMUSER.MVSMF.V1R0M0D.LINKLIB,DISP=SHR
//OUT      DD DSN=HTTPD.LINKLIB,DISP=OLD
//SYSIN    DD *
  COPY INDD=((IN,R)),OUTDD=OUT
  SELECT MEMBER=MVSMF
/*
