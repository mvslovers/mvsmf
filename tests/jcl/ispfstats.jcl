//ISPFSTAT JOB (ACCT),'MVSMF ISPFSTAT',CLASS=A,MSGCLASS=H
//* A PDS whose directory entries carry ISPF statistics (#573). Nothing on
//* the system writes them for a test: IEBUPDTE stows four bytes of user
//* data and mvsMF's own PUT none, so this stows them itself, one record
//* of data and one directory entry per member:
//*
//*   WITHST   30 bytes: 1.05, created and changed 2015/08/12, 05:48:43,
//*            22 / 22 / 3 lines, IBMUSER, not SCLM
//*   SCLMMEM  30 bytes: 12.34, created 2024/02/29, changed 1999/12/31,
//*            23:59:59, 1000 / 65535 / 0 lines, MVSMF, SCLM
//*   EXTEND   40 bytes, the extended form: no statistics are reported
//*   FOREIGN  30 bytes of some other tool's user data: none either
//*   PLAIN    no user data at all
//*
//* The suite replaces @DSN@ before submitting.
//ASM      EXEC ASMFCG
//ASM.SYSIN DD *
STOWER   CSECT
         STM   14,12,12(13)
         BALR  12,0
         USING *,12
         ST    13,SAVE+4
         LA    13,SAVE
         OPEN  (PDS,(OUTPUT))
         LA    5,TAB
         LA    6,NENT
NEXT     WRITE DECB,SF,PDS,REC
         CHECK DECB
         NOTE  PDS
         L     3,0(,5)
         STCM  1,B'1110',8(3)
         STOW  PDS,(3),A
         LTR   15,15
         BNZ   BAD
         LA    5,4(,5)
         BCT   6,NEXT
         SR    15,15
BAD      LR    2,15
         CLOSE PDS
         LR    15,2
         L     13,SAVE+4
         L     14,12(13)
         LM    2,12,28(13)
         BR    14
SAVE     DC    18F'0'
REC      DC    CL80'ISPF STATISTICS FIXTURE'
PDS      DCB   DDNAME=PDS,DSORG=PO,MACRF=(W)
TAB      DC    A(L1,L2,L3,L4,L5)
NENT     EQU   (*-TAB)/4
L1       DC    CL8'WITHST',XL3'000000',X'0F'
         DC    X'01050043',X'0115224F',X'0115224F',X'0548'
         DC    X'001600160003',CL8'IBMUSER',X'0000'
L2       DC    CL8'SCLMMEM',XL3'000000',X'0F'
         DC    X'0C228059',X'0124060F',X'0099365F',X'2359'
         DC    X'03E8FFFF0000',CL8'MVSMF',X'0000'
L3       DC    CL8'EXTEND',XL3'000000',X'14'
         DC    X'0C228059',X'0124060F',X'0099365F',X'2359'
         DC    X'03E8FFFF0000',CL8'MVSMF',X'0000'
         DC    XL10'00'
L4       DC    CL8'FOREIGN',XL3'000000',X'0F'
         DC    CL30'USER DATA OF ANOTHER TOOL'
L5       DC    CL8'PLAIN',XL3'000000',X'00'
         END
/*
//GO.PDS   DD DSN=@DSN@,DISP=(NEW,CATLG),UNIT=SYSDA,
//            SPACE=(TRK,(1,1,5)),DCB=(RECFM=F,LRECL=80,BLKSIZE=80)
