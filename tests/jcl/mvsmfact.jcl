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
//*   That method needs mvsMF, so it is unavailable in the one
//*   case where the name matters most: a server that cannot
//*   load MVSMF at all. httpd's own /.dm answers it instead --
//*   it reads HTTPD's storage from inside HTTPD, so the TIOT it
//*   walks is the running task's own.
//*
//*     /.dm?m=21C&l=16      PSATOLD -> current TCB
//*     /.dm?m=<tcb>&l=16    +0C = TCBTIO -> TIOT
//*     /.dm?m=<tiot>&l=256  first entry is STEPLIB; +0C is the
//*                          3-byte SWA address of its JFCB
//*     /.dm?m=<jfcb>&l=80   +10 begins the JFCB, whose first 44
//*                          bytes are the DSN
//*
//*   Measured from the running STC (STC01875) on 2026-09-06:
//*   the value below, HTTPD's own deploy library. It was
//*   HTTPD.V4R0M1.LINKLIB on 2026-08-25 -- an httpd upgrade
//*   moves this name and leaves the previous library behind,
//*   still populated, no longer read, and a copy into it
//*   activates nothing while every step reports success.
//*
//*   The port matters as much as the name. There is more than
//*   one httpd on this network, and a second one on the same
//*   HOST answers a different port from a different STEPLIB and
//*   a different MVS system entirely. Read MBT_MVS_PORT from
//*   .env, ask THAT server which STC is active, and take the
//*   STEPLIB from THAT job -- the whole chain, not just the
//*   host name. Measured wrong once (2026-09-06, port 8083 vs
//*   8080): every step was green and the module went to an
//*   unrelated system.
//*
//*   The deploy library is the one `make deploy` reports as its
//*   target, built from MBT_MVS_HLQ in .env.
//*
//*   IT MOVES WITH THE PROJECT VERSION. The V1R0M1D above is
//*   [project].version in project.toml, so every version bump
//*   leaves this card pointing at the PREVIOUS release's
//*   library -- which still exists, still holds a module, and
//*   copies it with IEB154I SUCCESSFULLY COPIED. Nothing in
//*   the job log says the wrong build was activated; only
//*   ?fn=version does. It read V1R0M0D from the 1.0.0 release
//*   until 2026-09-14. Take the name from what `make deploy`
//*   printed, not from this file.
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
//IN       DD DSN=IBMUSER.MVSMF.V1R0M1D.LINKLIB,DISP=SHR
//OUT      DD DSN=HTTPD.V4R0M2D.LINKLIB,DISP=SHR
//SYSIN    DD *
  COPY INDD=((IN,R)),OUTDD=OUT
  SELECT MEMBER=MVSMF
/*
