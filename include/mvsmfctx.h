#ifndef MVSMFCTX_H
#define MVSMFCTX_H

/**
 * @file mvsmfctx.h
 * @brief Per-CGI persistent mvsMF context block + cursor store accessor.
 *
 * httpd's cgictx service hands each CGI one persistent context block, keyed by
 * an 8-byte eyecatcher. mvsMF hangs request-spanning globals (currently the
 * console cursor store) off MVSMF_CTX. See issue #143.
 */

#include "ntstore.h"

#define MVSMF_CTX_EYE  "MVSMFCTX"        /* 8 bytes, stamped by http_cgictx_get */

typedef struct mvsmf_ctx {
    char            eye[8];      /* 00 "MVSMFCTX"                               */
    unsigned short  len;         /* 08 sizeof(MVSMF_CTX)                        */
    unsigned short  ver;         /* 0A layout version (>= 1)                    */
    void           *kvstore;     /* 0C NT_STORE *, lazily created               */
    void           *rsvd[4];     /* 10 room for future request-spanning globals */
} MVSMF_CTX;

/** The per-CGI persistent context from httpd's cgictx. NULL if the cgictx
 *  service is unavailable (the feature then degrades gracefully). */
MVSMF_CTX *mvsmf_ctx_get(void *httpd)                                  asm("MVCTXGET");

/** The cursor store anchored in the context, lazily created. NULL on failure. */
NT_STORE *mvsmf_kvstore(void *httpd)                                   asm("MVKVSGET");

#endif /* MVSMFCTX_H */
