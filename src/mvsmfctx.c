#include "mvsmfctx.h"
#include "ntstore.h"
#include "mvssupa.h"    /* __getm */
#include "cliblock.h"   /* lock / unlock, LOCK_EXC */

/*
 * Per-CGI persistent mvsMF context + lazy cursor store.
 *
 * TODO(#143): mvsmf_ctx_get() must call httpd's http_cgictx_get() once it ships:
 *
 *     #include "httpcgi.h"
 *     return http_cgictx_get((HTTPD *)httpd, MVSMF_CTX_EYE, sizeof(MVSMF_CTX));
 *
 * Until then it returns NULL, so mvsmf_kvstore() returns NULL, the cursor store
 * is unavailable, and console collect degrades to an empty (OK) response.
 */

__asm__("\n&FUNC	SETC 'mvsmf_ctx_get'");
MVSMF_CTX *mvsmf_ctx_get(void *httpd)
{
	(void)httpd;
	return (MVSMF_CTX *)0;          /* TODO(#143): http_cgictx_get(...) */
}

__asm__("\n&FUNC	SETC 'mvsmf_kvstore'");
NT_STORE *mvsmf_kvstore(void *httpd)
{
	MVSMF_CTX *ctx = mvsmf_ctx_get(httpd);
	if (!ctx) {
		return (NT_STORE *)0;
	}

	if (!ctx->kvstore) {
		/* lazy init under the context latch, double-checked against a racing
		 * worker that initialised it first */
		lock((void *)&ctx->kvstore, LOCK_EXC);
		if (ctx->len == 0) {
			ctx->len = (unsigned short)sizeof(MVSMF_CTX);
			ctx->ver = 1;
		}
		if (!ctx->kvstore) {
			NT_STORE *store = (NT_STORE *)__getm(sizeof(NT_STORE));
			if (store) {
				nt_store_init(store);
				ctx->kvstore = store;
			}
		}
		unlock((void *)&ctx->kvstore, LOCK_EXC);
	}

	return (NT_STORE *)ctx->kvstore;
}
