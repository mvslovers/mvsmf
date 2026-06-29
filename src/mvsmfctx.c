#include "mvsmfctx.h"
#include "ntstore.h"
#include "mvssupa.h"    /* __getm */
#include "cliblock.h"   /* lock / unlock, LOCK_EXC */
#include "httpcgi.h"    /* HTTPD, HTTPX, http_get_httpx, http_cgictx_get */

/*
 * Per-CGI persistent mvsMF context + lazy cursor store.
 *
 * mvsmf_ctx_get() returns the one persistent context block httpd keeps per CGI
 * for the "MVSMFCTX" eyecatcher (created on first use). If httpd's cgictx
 * service is unavailable it returns NULL, so mvsmf_kvstore() returns NULL, the
 * cursor store is unavailable, and console collect degrades to an empty (OK)
 * response.
 */

__asm__("\n&FUNC	SETC 'mvsmf_ctx_get'");
MVSMF_CTX *mvsmf_ctx_get(void *httpd)
{
	HTTPD *hd = (HTTPD *)httpd;

	if (!hd) {
		return (MVSMF_CTX *)0;
	}

#ifdef http_cgictx_get
	{
		/* httpx is needed because http_cgictx_get() routes through the httpd
		 * httpx vector (httpcgi.h macro). */
		HTTPX *httpx = http_get_httpx(hd);
		return (MVSMF_CTX *)http_cgictx_get(hd, MVSMF_CTX_EYE,
		                                    sizeof(MVSMF_CTX));
	}
#else
	/* httpd dependency predates the cgictx service: the store is unavailable
	 * and console collect degrades to an empty (OK) response. Activates
	 * automatically once the httpd dep provides http_cgictx_get. */
	return (MVSMF_CTX *)0;
#endif
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
