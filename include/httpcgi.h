#ifndef HTTPCGI_H
#define HTTPCGI_H
/*
** HTTPCGI.H - CGI module interface for the HTTP Daemon
**
** This header provides everything needed to write an external CGI module
** for the HTTPD server.  It is intentionally minimal: no UFS, no MQTT,
** no Lua, no crent370 internals.
**
** Usage:
**   #include "httpcgi.h"
**
**   In each function that uses the httpx macro layer, obtain the function
**   vector first:
**
**     HTTPX *httpx = http_get_httpx(httpd);
**     http_resp(httpc, 200);
**     http_printf(httpc, "Content-Type: text/plain\r\n\r\n");
**     http_printf(httpc, "Hello World\n");
**
** Copyright (c) 2016, 2024 Mike Rayborn. All rights reserved.
*/

#include <stddef.h>     /* size_t                   */
#include <stdio.h>      /* FILE                     */
#include <stdarg.h>     /* va_list                  */
#include <time64.h>     /* time64_t (crent370)      */

#include "dbg.h"        /* debug helpers            */
#include "errors.h"     /* errno values             */

/* ------------------------------------------------------------------ */
/* Basic typedefs (no dependency)                                      */
/* ------------------------------------------------------------------ */

typedef unsigned char   UCHAR;
typedef unsigned short  USHRT;
typedef unsigned int    UINT;
typedef unsigned long   ULONG;

/* ------------------------------------------------------------------ */
/* Forward declarations — CGI modules hold pointers, never dereference */
/* ------------------------------------------------------------------ */

typedef struct httpd    HTTPD;      /* HTTP Daemon (server) — opaque    */
typedef struct cred     CRED;       /* Credentials          — opaque    */
typedef struct ufs      UFS;        /* UFS filesystem       — opaque    */
typedef struct ufsfile  UFSFILE;    /* UFS file handle      — opaque    */
typedef struct mqtc     MQTC;       /* MQTT client          — opaque    */
typedef struct cib      CIB;        /* Console info block   — opaque    */
#include <socket.h>                 /* struct in_addr                   */

/* ------------------------------------------------------------------ */
/* Types with full definitions required by CGI modules                 */
/* ------------------------------------------------------------------ */

typedef struct httpc    HTTPC;      /* HTTP Client                      */
typedef struct httpm    HTTPM;      /* HTTP Mime type                   */
typedef struct httpx    HTTPX;      /* HTTP function vector             */
typedef struct httpv    HTTPV;      /* HTTP variable                    */
typedef struct httpcgi  HTTPCGI;    /* CGI path registration            */
typedef enum   cstate   CSTATE;     /* HTTP Client state                */
typedef enum   rdw      RDW;        /* RDW option                       */

/* HTTP client state */
enum cstate {
    CSTATE_IN=0,                    /* read request from client         */
    CSTATE_PARSE,                   /* parse request headers            */
    CSTATE_GET,                     /* process GET request              */
    CSTATE_HEAD,                    /* process HEAD request             */
    CSTATE_PUT,                     /* process PUT request              */
    CSTATE_POST,                    /* process POST request             */
    CSTATE_DELETE,                  /* process DELETE request           */
    CSTATE_DONE=10,                 /* processing complete              */
    CSTATE_REPORT,                  /* report results (log)             */
    CSTATE_RESET,                   /* reset client info                */
    CSTATE_CLOSE                    /* release client                   */
};

/* RDW option */
enum rdw {
    RDW_NONE=0,                     /* no RDW (default)                 */
    RDW_B2,                         /* Big Endian 2 byte                */
    RDW_L2,                         /* Little Endian 2 byte             */
    RDW_B4,                         /* Big Endian 4 byte                */
    RDW_L4                          /* Little Endian 4 byte             */
};

/* HTTP variable */
struct httpv {
    char    eye[8];                 /* 00 eye catcher                   */
#define HTTPV_EYE   "*HTTPV*"       /* ...                              */
    char    *value;                 /* 08 => variable value             */
    char    name[2];                /* 0C "name, 0, value, 0"           */
};

/* HTTP client context (4096 bytes) */
struct httpc {
    char        eye[8];             /* 00 eye catcher                   */
#define HTTPC_EYE   "*HTTPC*"       /* ...                              */
    HTTPD       *httpd;             /* 08 => HTTPD (server)             */
    HTTPV       **env;              /* 0C variables array               */

    short       state;              /* 10 current state (CSTATE)        */
    UCHAR       subtype;            /* 11 sub type (if any)             */
    UCHAR       substate;           /* 12 sub state (if any)            */
    int         socket;             /* 14 socket                        */
    unsigned    addr;               /* 18 client IP address             */
    int         port;               /* 1C client port                   */

    FILE        *fp;                /* 20 file handle                   */
    volatile unsigned len;          /* 24 length of data in buf         */
    volatile unsigned pos;          /* 28 position in buf               */
    unsigned    sent;               /* 2C bytes sent                    */

    double      start;              /* 30 start time in seconds         */
    double      end;                /* 38 end time in seconds           */

    UCHAR       rdw;                /* 40 RDW option                    */
    UCHAR       unused;             /* 41 available                     */
    short       resp;               /* 42 response code                 */
    CRED        *cred;              /* 44 client credential             */
    UFS         *ufs;               /* 48 UFS handle    (opaque)        */
    UFSFILE     *ufp;               /* 4C UFS file ptr  (opaque)        */

    UCHAR       ssi;                /* 50 Server Side Include enable    */
    UCHAR       ssilevel;           /* 51 SSI processing level          */
#define SSI_LEVEL_MAX   10          /* ... max SSI processing level     */
    UCHAR       unused1;            /* 52 available                     */
    UCHAR       unused2;            /* 53 available                     */
    unsigned    unused3;            /* 54 available                     */

#define CBUFSIZE (0x1000-0x0058)    /* ... 4096-88 = 4008               */
    UCHAR       buf[CBUFSIZE];      /* 58 data buffer                   */
};                                  /* 1000 (4096 bytes)                */

/* HTTP mime type */
struct httpm {
    UCHAR       *ext;               /* 00 File Extension                */
    UCHAR       *type;              /* 04 Mime type                     */
    int         binary;             /* 08 Binary flag                   */
};                                  /* 0C (12 bytes)                    */

/* CGI path registration */
struct httpcgi {
    UCHAR       eye[8];             /* 00 Eye catcher                   */
#define HTTPCGI_EYE  "HTTPCGI"      /* ...                              */
    UCHAR       wild;               /* 08 '*' or '?' in path name       */
    UCHAR       login;              /* 09 login required                */
    USHRT       len;                /* 0A Path length                   */
    char        *path;              /* 0C Path name to match            */
    char        *pgm;               /* 10 external program name         */
};                                  /* 14 (20 bytes)                    */

/* HTTP function execution vector */
struct httpx {
    char        eye[8];             /* 00 eye catcher                   */
#define HTTPX_EYE   "*HTTPX*"       /* ...                              */
    HTTPD       *httpd;             /* 08 => HTTPD (server)             */
    char        *unused2;           /* 0C available                     */

    int         (*http_in)(HTTPC*);
                                    /* 10 read input from client        */
    int         (*http_parse)(HTTPC*);
                                    /* 14 parse input from client       */
    int         (*http_get)(HTTPC*);
                                    /* 18 process GET request           */
    int         (*http_head)(HTTPC*);
                                    /* 1C process HEAD request          */
    int         (*http_put)(HTTPC*);
                                    /* 20 process PUT request           */
    int         (*http_post)(HTTPC*);
                                    /* 24 process POST request          */
    int         (*http_done)(HTTPC*);
                                    /* 28 done with request             */
    int         (*http_report)(HTTPC*);
                                    /* 2C report results                */
    int         (*http_reset)(HTTPC*);
                                    /* 30 reset for next request        */
    int         (*http_close)(HTTPC*);
                                    /* 34 all done, close client        */
    int         (*http_send)(HTTPC*,const UCHAR *,int);
                                    /* 38 send data asis to client      */
    UCHAR *     (*http_decode)(UCHAR*);
                                    /* 3C decode escaped string         */
    int         (*http_del_env)(HTTPC *, const UCHAR *name);
                                    /* 40 delete variable               */
    unsigned    (*http_find_env)(HTTPC *, const UCHAR *name);
                                    /* 44 find variable                 */
    int         (*http_set_env)(HTTPC *, const UCHAR *, const UCHAR *);
                                    /* 48 set variable                  */
    HTTPV *     (*http_new_env)(const UCHAR *, const UCHAR *);
                                    /* 4C allocate new variable         */
    int         (*http_set_http_env)(HTTPC *, const UCHAR *, const UCHAR *);
                                    /* 50 set HTTP variable             */
    int         (*http_set_query_env)(HTTPC *, const UCHAR *, const UCHAR *);
                                    /* 54 set QUERY variable            */
    UCHAR *     (*http_get_env)(HTTPC *, const UCHAR *);
                                    /* 58 get variable value            */
    UCHAR *     (*http_date_rfc1123)(time64_t, UCHAR *, size_t);
                                    /* 5C format a RFC1123 date         */
    int         (*http_printv)(HTTPC *, const char *, va_list);
                                    /* 60 printv                        */
    int         (*http_printf)(HTTPC *,  const char *, ... );
                                    /* 64 printf                        */
    int         (*http_resp)(HTTPC *, int);
                                    /* 68 send response                 */
    UCHAR *     (*http_server_name)(HTTPD *);
                                    /* 6C get server name               */
    int         (*http_resp_not_implemented)(HTTPC *);
                                    /* 70 501 not implemented           */
    UCHAR *     (*http_etoa)(UCHAR *, int);
                                    /* 74 convert EBCDIC to ASCII       */
    UCHAR *     (*http_atoe)(UCHAR *, int);
                                    /* 78 convert ASCII to EBCDIC       */
    void *      (*array_new)(unsigned);
                                    /* 7C allocate dynamic array        */
    int         (*array_add)(void *, void *);
                                    /* 80 add item to array             */
    int         (*array_addf)(void *, const char *, ... );
                                    /* 84 add formatted string          */
    unsigned    (*array_count)(void *);
                                    /* 88 count items in array          */
    int         (*array_free)(void *);
                                    /* 8C free dynamic array            */
    void *      (*array_get)(void *, unsigned);
                                    /* 90 get item by index             */
    unsigned    (*array_size)(void *);
                                    /* 94 size of array in items        */
    void *      (*array_del)(void *, unsigned);
                                    /* 98 delete item from array        */
    int         (*http_cmp)(const UCHAR *, const UCHAR *);
                                    /* 9C caseless string compare       */
    int         (*http_cmpn)(const UCHAR *, const UCHAR *, int);
                                    /* A0 caseless string compare n     */
    int         (*http_dbgw)(const char *, int);
                                    /* A4 debug write                   */
    int         (*http_dbgs)(const char *);
                                    /* A8 debug puts                    */
    int         (*http_dbgf)(const char *fmt, ...);
                                    /* AC debug printf                  */
    int         (*http_dump)(void *, int, const char *, ...);
                                    /* B0 debug hex dump                */
    int         (*http_enter)(const char *, ...);
                                    /* B4 debug enter function          */
    int         (*http_exit)(const char *, ...);
                                    /* B8 debug exit function           */
    double *    (*http_secs)(double *);
                                    /* BC current time as double        */
    const HTTPM *(*http_mime)(const UCHAR *);
                                    /* C0 get mime for document         */
    int         (*http_resp_internal_error)(HTTPC *);
                                    /* C4 500 internal server error     */
    int         (*http_resp_not_found)(HTTPC *, const UCHAR *);
                                    /* C8 404 not found                 */
    FILE *      (*http_open)(HTTPC *, const UCHAR *, const HTTPM *);
                                    /* CC open path name                */
    int         (*http_send_binary)(HTTPC *);
                                    /* D0 send file binary              */
    int         (*http_read)(FILE *, UCHAR *, int, int);
                                    /* D4 read file/dataset             */
    int         (*http_send_file)(HTTPC *, int);
                                    /* D8 send file                     */
    int         (*http_send_text)(HTTPC *);
                                    /* DC send file text                */
    int         (*http_is_busy)(HTTPC *);
                                    /* E0 is client busy                */
    int         (*http_set_busy)(HTTPC *);
                                    /* E4 add client to busy array      */
    int         (*http_reset_busy)(HTTPC *);
                                    /* E8 remove client from busy       */
    int         (*http_process_clients)(void);
                                    /* EC process clients               */
    char *      (*http_ntoa)(struct in_addr in);
                                    /* F0 format network address        */
    int         (*http_console)(CIB *cib);
                                    /* F4 process console command       */
    int         (*http_process_client)(HTTPC *);
                                    /* F8 process a client              */
    int         (*http_link)(HTTPC *, const char *);
                                    /* FC link to external program      */
    HTTPCGI *   (*http_find_cgi)(HTTPD *httpd, const char *path);
                                    /* 100 find cgi for path name       */
    HTTPCGI *   (*http_add_cgi)(HTTPD *httpd, const char *pgm,
                                const char *path, int login);
                                    /* 104 add cgi for pgm and path     */
    int         (*http_process_cgi)(HTTPC *httpc, HTTPCGI *cgi);
                                    /* 108 process CGI request          */
    int         (*mqtc_pub)(MQTC *mqtc, unsigned qos, unsigned retain,
                            const char *topic_name,
                            const char *application_message);
                                    /* 10C publish MQTT topic           */
};

/* Eye-catcher for HTTPD pointer identification (ABI constant) */
#define HTTPD_EYE   "*HTTPD*"

/* ------------------------------------------------------------------ */
/* Accessor: get the HTTPX function vector from an HTTPD pointer.      */
/*                                                                     */
/* httpx is always at offset 0x08 in struct httpd — this is an ABI    */
/* commitment.  Using a macro avoids any link-time dependency on       */
/* httpd's NCALIB.                                                     */
/* ------------------------------------------------------------------ */

#define http_get_httpx(h)  (*(HTTPX **)((char *)(h) + 8))

/* ------------------------------------------------------------------ */
/* Macro layer — all http_* calls go through the httpx vector.         */
/* Requires HTTPX *httpx to be in scope before use:                    */
/*   HTTPX *httpx = http_get_httpx(httpd);                             */
/* ------------------------------------------------------------------ */

#define http_in(httpc) \
    ((httpx->http_in)((httpc)))

#define http_parse(httpc) \
    ((httpx->http_parse)((httpc)))

#define http_get(httpc) \
    ((httpx->http_get)((httpc)))

#define http_head(httpc) \
    ((httpx->http_head)((httpc)))

#define http_put(httpc) \
    ((httpx->http_put)((httpc)))

#define http_post(httpc) \
    ((httpx->http_post)((httpc)))

#define http_done(httpc) \
    ((httpx->http_done)((httpc)))

#define http_report(httpc) \
    ((httpx->http_report)((httpc)))

#define http_reset(httpc) \
    ((httpx->http_reset)((httpc)))

#define http_close(httpc) \
    ((httpx->http_close)((httpc)))

#define http_send(httpc,buf,len) \
    ((httpx->http_send)((httpc),(buf),(len)))

#define http_decode(str) \
    ((httpx->http_decode)((str)))

#define http_del_env(httpc,name) \
    ((httpx->http_del_env)((httpc),(name)))

#define http_find_env(httpc,name) \
    ((httpx->http_find_env)((httpc),(name)))

#define http_set_env(httpc,name,value) \
    ((httpx->http_set_env)((httpc),(name),(value)))

#define http_new_env(name,value) \
    ((httpx->http_new_env)((name),(value)))

#define http_set_http_env(httpc,name,value) \
    ((httpx->http_set_http_env)((httpc),(name),(value)))

#define http_set_query_env(httpc,name,value) \
    ((httpx->http_set_query_env)((httpc),(name),(value)))

#define http_get_env(httpc,name) \
    ((httpx->http_get_env)((httpc),(name)))

#define http_date_rfc1123(t,buf,size) \
    ((httpx->http_date_rfc1123)((t),(buf),(size)))

#define http_printv(httpc,fmt,args) \
    ((httpx->http_printv)((httpc),(fmt),(args)))

#define http_printf(httpc,fmt,...) \
    ((httpx->http_printf)((httpc),(fmt),## __VA_ARGS__))

#define http_resp(httpc,resp) \
    ((httpx->http_resp)((httpc),(resp)))

#define http_server_name(httpd) \
    ((httpx->http_server_name)((httpd)))

#define http_resp_not_implemented(httpc) \
    ((httpx->http_resp_not_implemented)((httpc)))

#define http_etoa(buf,len) \
    ((httpx->http_etoa)((buf),(len)))

#define http_atoe(buf,len) \
    ((httpx->http_atoe)((buf),(len)))

#undef array_new
#define array_new(size) \
    ((httpx->array_new)((size)))

#undef array_add
#define array_add(varray,vitem) \
    ((httpx->array_add)((varray),(vitem)))

#undef array_addf
#define array_addf(varray,fmt,...) \
    ((httpx->array_addf)((varray),(fmt),## __VA_ARGS__))

#undef array_count
#define array_count(varray) \
    ((httpx->array_count)((varray)))

#undef array_free
#define array_free(varray) \
    ((httpx->array_free)((varray)))

#undef array_get
#define array_get(varray,indx) \
    ((httpx->array_get)((varray),(indx)))

#undef array_size
#define array_size(varray) \
    ((httpx->array_size)((varray)))

#undef array_del
#define array_del(varray,indx) \
    ((httpx->array_del)((varray),(indx)))

#define http_cmp(s1,s2) \
    ((httpx->http_cmp)((s1),(s2)))

#define http_cmpn(s1,s2,n) \
    ((httpx->http_cmpn)((s1),(s2),(n)))

#define http_dbgw(buf,len) \
    ((httpx->http_dbgw)((buf),(len)))

#define http_dbgs(str) \
    ((httpx->http_dbgs)((str)))

#define http_dbgf(fmt,...) \
    ((httpx->http_dbgf)((fmt),## __VA_ARGS__))

#define http_dump(buf,len,fmt,...) \
    ((httpx->http_dump)((buf),(len),(fmt),## __VA_ARGS__))

#define http_enter(fmt,...) \
    ((httpx->http_enter)((fmt),## __VA_ARGS__))

#define http_exit(fmt,...) \
    ((httpx->http_exit)((fmt),## __VA_ARGS__))

#define http_secs(secs) \
    ((httpx->http_secs)((secs)))

#define http_mime(path) \
    ((httpx->http_mime)((path)))

#define http_resp_internal_error(httpc) \
    ((httpx->http_resp_internal_error)((httpc)))

#define http_resp_not_found(httpc,path) \
    ((httpx->http_resp_not_found)((httpc),(path)))

#define http_open(httpc,path,mime) \
    ((httpx->http_open)((httpc),(path),(mime)))

#define http_send_binary(httpc) \
    ((httpx->http_send_binary)((httpc)))

#define http_read(fp,buf,size,rdw) \
    ((httpx->http_read)((fp),(buf),(size),(rdw)))

#define http_send_file(httpc,binary) \
    ((httpx->http_send_file)((httpc),(binary)))

#define http_send_text(httpc) \
    ((httpx->http_send_text)((httpc)))

#define http_is_busy(httpc) \
    ((httpx->http_is_busy)((httpc)))

#define http_set_busy(httpc) \
    ((httpx->http_set_busy)((httpc)))

#define http_reset_busy(httpc) \
    ((httpx->http_reset_busy)((httpc)))

#define http_process_clients() \
    ((httpx->http_process_clients)())

#define http_ntoa(addr) \
    ((httpx->http_ntoa)((addr)))

#define http_console(cib) \
    ((httpx->http_console)((cib)))

#define http_process_client(httpc) \
    ((httpx->http_process_client)((httpc)))

#define http_link(httpc,pgm) \
    ((httpx->http_link)((httpc),(pgm)))

#define http_find_cgi(httpd,path) \
    ((httpx->http_find_cgi)((httpd),(path)))

#define http_add_cgi(httpd,pgm,path,login) \
    ((httpx->http_add_cgi)((httpd),(pgm),(path),(login)))

#define http_process_cgi(httpc,cgi) \
    ((httpx->http_process_cgi)((httpc),(cgi)))

#define mqtc_pub(mqtc,qos,retain,topic,message) \
    ((httpx->mqtc_pub)((mqtc),(qos),(retain),(topic),(message)))

#endif /* HTTPCGI_H */
