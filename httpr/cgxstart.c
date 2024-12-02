/*********************************************************************/
/*                                                                   */
/*  cgistart.c - common gateway interface startup/termination code   */
/*                                                                   */
/*********************************************************************/

/* Callers of C program may be from TSO or Batch.
   TSO supplies the args in a struct like:
   00 length of args first byte
   01 length of args second byte
   02 always zero
   03 length of program name in args starting in byte 04
   04 args....

   For TSO, the length of args includes the 4 byte prefix area size.

   Batch supplies the args in a struct like:
   00 length of args first byte
   01 length of args second byte
   02 args....

   For Batch, the args are those specified in the PARM='...' for
   the EXEC statement in the JCL.
*/

#include "httpd.h"

#define MAXPARMS 50 /* maximum number of arguments we can handle */

extern int main(int argc, char **argv);
extern void __exita(int status);

/* initialize to 0 to prevent linkage editor from trying to resolve httpx */
HTTPX *httpx = 0;

/* we want to use the httpx pointer in the httpd struct for the various
   http_xxx functions, so we define httpx to do just that
*/
#define httpx   (httpd->httpx)

/* we want the internal label for __start as "cgistart" for use with dumps */
__asm__("\n&FUNC    SETC 'cgistart'");
int
__start(char *p, char *pgmname, int tsojbid, void **pgmr1)
{
    CLIBGRT     *grt    = __grtget();
    HTTPD       *httpd  = NULL;
    HTTPC       *httpc  = NULL;
    int         x;
    int         argc;
    unsigned    u;
    char        *argv[MAXPARMS + 1];
    int         rc;
    int         parmLen;
    int         progLen;
    char        parmbuf[310];

    /* we're going to process the callers parameter list first so we
       can decide is we'll bypass the opens for the permanent datasets.
    */
    if (pgmr1) {
        /* save the program parameter list values (max 10 pointers)
           note: the first pointer is always the raw EXEC PGM=...,PARM
           or CPPL (TSO) address.
        */
        for(x=0; x < 10; x++) {
            u = (unsigned)pgmr1[x];
            /* add to array of pointers from caller */
            arrayadd(&grt->grtptrs, (void*)(u&0x7FFFFFFF));

            if (u) {
                if (strcmp((void*)u, HTTPD_EYE)==0) {
                    /* this is a HTTPD pointer */
                    httpd        = (HTTPD*)(u&0x7FFFFFFF);
                    grt->grtapp1 = httpd;
                }
                if (strcmp((void*)u, HTTPC_EYE)==0) {
                    /* this is a HTTPC pointer */
                    httpc        = (HTTPC*)(u&0x7FFFFFFF);
                    grt->grtapp2 = httpc;
                }
            }

            if (u&0x80000000) break; /* end of VL style address list */
        }
    }

    /* if we got a HTTPC and we didn't get a HTTPD,
       then use the HTTPD from the HTTPC handle */
    if (httpc && !httpd) {
        httpd = httpc->httpd;
        grt->grtapp1 = httpd;
    }

    /* need to know if this is a TSO environment straight away
       because it determines how the permanent files will be
       opened */
    parmLen = ((unsigned int)p[0] << 8) | (unsigned int)p[1];
    if ((parmLen > 0) && (p[2] == 0)) {
        grt->grtflag1 |= GRTFLAG1_TSO;
        progLen = (unsigned int)p[3];
    }

    stdout = fopen("DD:HTTPDOUT", "w");
    if (!stdout && !httpc) __exita(EXIT_FAILURE);

    stderr = fopen("DD:HTTPDERR", "w");
    if (!stderr && !httpc) {
        if (stdout) {
            printf("HTTPDERR DD not defined\n");
            fclose(stdout);
        }
        __exita(EXIT_FAILURE);
    }

    stdin = fopen("DD:HTTPDIN", "r");
    if (!stdin) stdin = fopen("'NULLFILE'", "r");
    if (!stdin && !httpc) {
        if (stderr) fprintf(stderr, "HTTPDIN DD not defined\n");
        if (stdout) fclose(stdout);
        if (stderr) fclose(stderr);
        __exita(EXIT_FAILURE);
    }

    /* load any environment variables */
    if (loadenv("dd:SYSENV")) {
        /* no SYSENV DD, try ENVIRON DD */
        loadenv("dd:ENVIRON");
    }

    /* initialize time zone offset for this thread */
    tzset();

    if (parmLen >= sizeof(parmbuf) - 2) {
        parmLen = sizeof(parmbuf) - 1 - 2;
    }
    if (parmLen < 0) parmLen = 0;

    /* We copy the parameter into our own area because
       the caller hasn't necessarily allocated room for
       a terminating NUL, nor is it necessarily correct
       to clobber the caller's area with NULs. */
    memset(parmbuf, 0, sizeof(parmbuf));
    if (grt->grtflag1 & GRTFLAG1_TSO) {
        parmLen -= 4;
        memcpy(parmbuf, p+4, parmLen);
    }
    else {
        memcpy(parmbuf, p+2, parmLen);
    }
    p = parmbuf;

    if (grt->grtflag1 & GRTFLAG1_TSO) {
        argv[0] = p;
        for(x=0;x<=progLen;x++) {
            if (argv[0][x]==' ') {
                argv[0][x]=0;
                break;
            }
        }
        p += progLen;
    }
    else {       /* batch or tso "call" */
        argv[0] = pgmname;
        pgmname[8] = '\0';
        pgmname = strchr(pgmname, ' ');
        if (pgmname) *pgmname = '\0';
    }

    while (*p == ' ') p++;

    x = 1;
    if (*p) {
        while(x < MAXPARMS) {
            char srch = ' ';

            if (*p == '"') {
                p++;
                srch = '"';
            }
            argv[x++] = p;
            p = strchr(p, srch);
            if (!p) break;

            *p = '\0';
            p++;
            /* skip trailing blanks */
            while (*p == ' ') p++;
            if (*p == '\0') break;
        }
    }
    argv[x] = NULL;
    argc = x;
#if 0
	rc = 0;
	printf("HTTP/1.0 200 OK\n\n");
	printf("{ \"%s\" }\n", "cgistart");
#else
    rc = main(argc, argv);
#endif
    __exit(rc);
    return (rc);
}

int
printf(const char *format, ...)
{
    CLIBPPA     *ppa    = __ppaget();
    CLIBGRT     *grt    = __grtget();
    HTTPD       *httpd  = grt->grtapp1;
    HTTPC       *httpc  = grt->grtapp2;
    va_list arg;
    int ret;

#if 0
    wtof("printf in cgistart httpd=%08X, httpc=%08X, httpx=%08X, grt=%08X, ppa=%08X",
         httpd, httpc, httpx, grt, ppa);
#endif

    va_start(arg, format);
    if (httpc && httpx && httpx->http_printv) {
#if 0
		vwtof(format, arg);
#endif
        ret = (httpx->http_printv)(httpc, format, arg);
    }
    else {
        ret = vfprintf(stdout, format, arg);
    }
    va_end(arg);

    return (ret);
}
