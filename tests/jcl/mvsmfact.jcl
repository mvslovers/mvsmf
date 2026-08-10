//MVSMFACT JOB (ACCT),'ACTIVATE MVSMF',CLASS=A,MSGCLASS=H,
//         NOTIFY=&SYSUID
//*
//* Copy a freshly deployed MVSMF into the httpd STEPLIB.
//*
//* WHY THIS EXISTS
//*   `make deploy` RECEIVEs the load module into the deploy
//*   LINKLIB and stops there -- it does not touch the running
//*   server. httpd loads the CGI fresh per request from its own
//*   STEPLIB, so copying the member there activates the new
//*   build immediately, with no httpd restart.
//*
//*   DISP=SHR on OUT is deliberate: httpd holds the STEPLIB SHR,
//*   so DISP=OLD would make this job sit in the enqueue until
//*   the server is stopped. There is no reason to stop it.
//*
//* CHECK THE NAMES
//*   Both data sets below are installation-specific.
//*
//*   The STEPLIB: read it off the RUNNING started task, do not
//*   guess from the data set list -- several HTTPD.LINKLIB*
//*   data sets may exist and only one is in use.
//*
//*     GET /zosmf/restjobs/jobs?owner=*&prefix=HTTPD*
//*       -> find the ACTIVE STC
//*     GET /zosmf/restjobs/jobs/HTTPD/<stcid>/files/3/records
//*       -> XXSTEPLIB DD DISP=SHR,DSN=<the answer>
//*
//*   The deploy library is the one `make deploy` reports as its
//*   target, built from MBT_MVS_HLQ in .env.
//*
//* AFTERWARDS
//*   GET /zosmf/test?fn=version returns the git hash the live
//*   module was built from -- it must equal the HEAD you built.
//*
//*   IEBCOPY prints IEB144I with the tracks left. Every replace
//*   copy orphans the old member's space, so that number only
//*   falls. At the extent limit the copy fails IEF450I ... ABEND
//*   SE37; that failure is clean (it abends before writing, so
//*   the existing member and the running server are unharmed),
//*   but nothing activates until the library is compressed --
//*   COPY INDD=LIB,OUTDD=LIB with DISP=OLD, which is the one
//*   case that does need P HTTPD / S HTTPD around it.
//*
//ACTIVATE EXEC PGM=IEBCOPY
//SYSPRINT DD SYSOUT=*
//IN       DD DSN=IBMUSER.MVSMF.V1R0M0D.LINKLIB,DISP=SHR
//OUT      DD DSN=HTTPD.LINKLIB,DISP=SHR
//SYSIN    DD *
  COPY INDD=((IN,R)),OUTDD=OUT
  SELECT MEMBER=MVSMF
/*
