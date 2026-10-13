//WRONGLEN JOB (ACCT),'MVSMF WRONGLEN',CLASS=A,MSGCLASS=H
//* A data set whose label says VB/125/129 while its first block is a
//* 160-byte FB block: every read of it ends in a wrong-length record,
//* i.e. an I/O error after the status has gone out (#421). WRITE puts
//* the FB data down, REDECL opens it DISP=MOD under the VB attributes
//* and writes nothing, which rewrites the label and nothing else.
//* The suite replaces @DSN@ before submitting.
//WRITE    EXEC PGM=IEBGENER
//SYSPRINT DD SYSOUT=*
//SYSIN    DD DUMMY
//SYSUT1   DD *
LINE ONE
LINE TWO
/*
//SYSUT2   DD DSN=@DSN@,DISP=(NEW,CATLG),UNIT=SYSDA,
//            SPACE=(TRK,(1,1)),DCB=(RECFM=FB,LRECL=80,BLKSIZE=800)
//REDECL   EXEC PGM=IEBGENER
//SYSPRINT DD SYSOUT=*
//SYSIN    DD DUMMY
//SYSUT1   DD DUMMY,DCB=(RECFM=VB,LRECL=125,BLKSIZE=129)
//SYSUT2   DD DSN=@DSN@,DISP=MOD,
//            DCB=(RECFM=VB,LRECL=125,BLKSIZE=129)
