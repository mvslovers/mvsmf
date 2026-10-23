#include <stdio.h>
#include <string.h>
#include <mvs/wto.h>
#include <mvs/recovery.h>
#include <mvs/link.h>   /* clib_find_cde -- MVSMF914I's module extent (#425) */
#include <ibm/mvs/ihacde.h>
#include <ibm/mvs/ihaxtlst.h>
#include <mvs/jes2.h>
#include <mvs/lock.h>   /* unlock, LOCK_EXC -- console lock recovery (#214) */

#include "router.h"
#include "dsapi.h"      /* DSLIST_LOCK_RNAME -- list lock recovery (#436) */
#include "common.h"
#include "httpcgi.h"
#include "abendmsg.h"
#include "mvsmfmsg.h"


#define INITIAL_BUFFER_SIZE 4096

// Context for ESTAE-protected handler invocation.
// Captures the handler's return code since try() only returns 0/abend.
struct handler_ctx {
    RouteHandler handler;
    Session *session;
    int rc;
};

//
// private function prototypes
//

static int handler_thunk(struct handler_ctx *ctx);
static void report_abend_where(void);
static int peek_code_thunk(const unsigned char *from, unsigned char *to);
static int safe_fclose_thunk(FILE *fp);

static int route_matching_middleware(Session *session);
static int path_vars_extracting_middleware(Session *session);

static unsigned char hex_nibble(char c);
static int is_hex_digit(char c);
static void percent_decode(Session *session, char *str);

static HttpMethod parseMethod(const char *method);
static Route *find_route(Router *router, HttpMethod method, const char *path);
static int path_is_known(Router *router, const char *path);
static int is_pattern_match(const char *pattern, const char *path);
static int extract_path_vars(Session *session, const char *pattern, const char *path);

//
// public functions
//

void init_router(Router *router) 
{
    memset(router, 0, sizeof(Router));  

    add_middleware(router, "RouteMatching", route_matching_middleware);
    add_middleware(router, "PathVars", path_vars_extracting_middleware);
}

void init_session(Session *session, Router *router, HTTPD *httpd, HTTPC *httpc) 
{
    memset(session, 0, sizeof(Session));
    session->router = router;
    session->httpd = httpd;
    session->httpc = httpc;
}

void add_route(Router *router, HttpMethod method, const char *pattern, RouteHandler handler) 
{
    if (router->route_count >= MAX_ROUTES) {
        wtof(MSG_ROUTES_FULL, MAX_ROUTES);
        return;
    }

    if (!pattern || !handler) {
        wtof(MSG_ROUTE_INVALID);
        return;
    }

    Route *route = &router->routes[router->route_count++];
    route->method = method;
    route->pattern = pattern;
    route->handler = handler;

}

void add_middleware(Router *router, const char *middleware_name, MiddlewareHandler handler)
{
    if (router->middleware_count >= MAX_MIDDLEWARES) {
        wtof(MSG_MIDDLEWARES_FULL, MAX_MIDDLEWARES);
        return;
    }

    Middleware *middleware = &router->middlewares[router->middleware_count++];
    middleware->name = middleware_name;
    middleware->handler = handler;
}

int handle_request(Router *router, Session *session) 
{
    if (router == NULL || session == NULL) {
        wtof(MSG_ROUTER_NULL);
        return -1;
    } 

    HTTPC *httpc = session->httpc;

    char *method = (char *) http_get_env(httpc, (const UCHAR *) "REQUEST_METHOD");
    char *raw_path = (char *) http_get_env(httpc, (const UCHAR *) "REQUEST_PATH");
    char path[1024];

    // Percent-decode the request path (e.g. %28/%29 -> parentheses)
    strncpy(path, raw_path, sizeof(path) - 1);
    path[sizeof(path) - 1] = '\0';
    percent_decode(session, path);

    HttpMethod reqMethod = parseMethod(method);
    if ((int)reqMethod == -1) {
        http_resp(httpc, 405);
        return -1;
    }

    // Execute middlewares in sequence.
    // NOTE: middlewares run outside ESTAE protection — they must be
    // crash-safe. An abend here will not be caught by the try() below.
    size_t i = 0;
    for (i = 0; i < router->middleware_count; i++) {
        int rc = router->middlewares[i].handler(session);
        if (rc != 0) {
            return rc;  // Middleware aborted the chain
        }
    }

    Route *route = find_route(router, reqMethod, path);

    if (route == NULL) {
        // A path some route serves, asked with a method none registered for
        // it, is a 405 -- not a 404 (#418). Like the reference, no Allow.
        if (path_is_known(router, path)) {
            char msg[64];

            snprintf(msg, sizeof(msg),
                     "Http method %s is not supported by this URL", method);
            sendErrorResponse(session, HTTP_STATUS_METHOD_NOT_ALLOWED, 6, 4, 7, msg, NULL, 0);
            return -1;
        }
        sendErrorResponse(session, HTTP_STATUS_NOT_FOUND, 6, 4, 7, "Not Found", NULL, 0);
        return -1;
    }

    extract_path_vars(session, route->pattern, path);

    // call the handler with ESTAE protection
    struct handler_ctx ctx;
    int try_rc;

    ctx.handler = route->handler;
    ctx.session = session;
    ctx.rc = 0;

    try_rc = try(handler_thunk, &ctx);
    if (try_rc != 0) {
        unsigned abend = tryrc();
        unsigned sys = (abend >> 12) & 0xFFF;
        unsigned usr = abend & 0xFFF;
        // on the stack, not static: MVSMF is RENT, and this runs in the
        // recovery path where a second abend would be unrecoverable
        char msg[ABEND_MSG_SIZE];
        wtof(MSG_HANDLER_ABEND, sys, usr, method, path);
        // before session_cleanup(): its try()s would overwrite tryinfo()
        report_abend_where();
        session_cleanup(session);
        if (!session->headers_sent) {
            /* An S913 is not a failure, it is a refusal OPEN made, and the
               reference reports it as one -- measured, a real z/OSMF answers a
               data set it may not open with category 4 / "LMOPEN error" and the
               explanation in details[], and takes the same S913 doing it. So
               this is the same body a pre-check produces (#228), differing only
               in the sentence: that one has abended and says so.

               Every other abend keeps the generic report with its code (#256).
               S213 in particular must not fall in here -- it is "cannot open
               sequentially", not a denial. */
            const char *denial = abend_denial_detail(sys);

            if (denial) {
                const char *details[1];

                details[0] = denial;
                sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
                    CATEGORY_AUTHORIZATION, RC_ERROR, REASON_NOT_AUTHORIZED,
                    ERR_MSG_NOT_AUTHORIZED, details, 1);
            } else {
                // the abend code is all the caller gets -- the console message
                // stays behind on the system (#256)
                abend_message(msg, sizeof(msg), sys, usr);
                sendErrorResponse(session, 500, 6, 8, 99, msg, NULL, 0);
            }
        } else {
            wtof(MSG_HEADERS_SENT);
        }
        return -1;
    }
    return ctx.rc;
}

// The module entry point (ld370 -e @@CRT0). MVSMF913I measures from it
// because it is the one address the running copy and the link map share:
// `file370 -v` prints it as entry=.
extern char mvsmf_ep[] asm("@@CRT0");

// MVSMF913I: where the abend just reported by MVSMF901E happened (#425). Until
// libc370 2.11.0 only the completion code survived the retry, so a stray abend
// could be located only from a dump, and the S0C7/S0C1 of #425 took none when
// they happened. Silent when there is no PSW to report.
__asm__("\n&FUNC    SETC 'report_abend_where'");
static void report_abend_where(void)
{
    const TRYINFO *ti = tryinfo();
    unsigned ep = (unsigned) mvsmf_ep;
    long at;
    long r14;

    if (!ti || (ti->psw[0] == 0 && ti->psw[1] == 0)) {
        return;
    }

    at  = abend_ep_offset(abend_instr_addr(ti->psw), ep);
    r14 = abend_ep_offset(ti->r14, ep);

    wtof(MSG_HANDLER_PSW, ti->psw[0], ti->psw[1],
         (ti->psw[1] >> 30) & 3, ti->psw[0] & 0xFFFF,
         at < 0 ? '-' : '+', at < 0 ? -at : at,
         r14 < 0 ? '-' : '+', r14 < 0 ? -r14 : r14);

    // MVSMF914I: what the bytes there are. In #425 the code at a function
    // entry was not what was linked, and these bytes are the only trace of
    // whatever wrote them. Only for an instruction inside this copy of MVSMF:
    // the console is readable by every authenticated user, and outside the
    // module the 16 bytes could be a buffer with another session's request
    // or credentials. The extent comes from the CDE whose entry point is
    // ours; no such CDE, no message. Read under try(): a second abend here
    // must cost this message only. After MVSMF913I, since this try() resets
    // tryinfo().
    {
        unsigned char code[16];
        unsigned      w[4];
        unsigned      start = 0;
        unsigned      len   = 0;
        unsigned      instr = abend_instr_addr(ti->psw);
        CDE          *cde   = clib_find_cde("MVSMF");
        int           i;

        if (cde && !(cde->CDATTR & CDMIN) && cde->xtlst
            && (cde->CDENTPT & 0x00FFFFFF) == (ep & 0x00FFFFFF)) {
            start = cde->xtlst->xtlmsbad;
            len   = cde->xtlst->xtlmsbln;
        }
        // the whole 16-byte window, not just the instruction, must be ours
        if (!abend_in_range(instr - 8, start, len)
            || !abend_in_range(instr + 7, start, len)) {
            return;
        }

        memset(code, 0, sizeof(code));
        if (try(peek_code_thunk, (const unsigned char *) (instr - 8),
                code) != 0) {
            return;
        }
        for (i = 0; i < 4; i++) {
            w[i] = (unsigned) code[i * 4] << 24 | (unsigned) code[i * 4 + 1] << 16
                 | (unsigned) code[i * 4 + 2] << 8 | (unsigned) code[i * 4 + 3];
        }
        wtof(MSG_HANDLER_CODE, w[0], w[1], w[2], w[3]);
    }
}

// Thunk for the MVSMF914I read: copy 16 bytes, ESTAE-protected by the caller.
__asm__("\n&FUNC    SETC 'peek_code_thunk'");
static int peek_code_thunk(const unsigned char *from, unsigned char *to)
{
    memcpy(to, from, 16);
    return 0;
}

// Thunk for ESTAE-protected handler invocation.
// Called by try(), stores the handler's return value in ctx->rc.
__asm__("\n&FUNC    SETC 'handler_thunk'");
static int handler_thunk(struct handler_ctx *ctx)
{
    ctx->rc = ctx->handler(ctx->session);
    return 0;
}

//
// session resource tracking
//

__asm__("\n&FUNC    SETC 'ses_reg_file'");
int session_register_file(Session *session, FILE *fp)
{
    if (!session || !fp) return -1;
    if (session->open_file_count >= MAX_SESSION_FILES) {
        wtof(MSG_FILES_FULL);
        return -1;
    }
    session->open_files[session->open_file_count++] = fp;
    return 0;
}

__asm__("\n&FUNC    SETC 'ses_unreg_file'");
void session_unregister_file(Session *session, FILE *fp)
{
    int i;
    if (!session || !fp) return;
    for (i = 0; i < session->open_file_count; i++) {
        if (session->open_files[i] == fp) {
            // shift remaining entries down
            session->open_file_count--;
            for (; i < session->open_file_count; i++) {
                session->open_files[i] = session->open_files[i + 1];
            }
            session->open_files[session->open_file_count] = NULL;
            return;
        }
    }
}

__asm__("\n&FUNC    SETC 'ses_fclose'");
int session_fclose(Session *session, FILE *fp)
{
    if (!session || !fp) return 0;
    session_unregister_file(session, fp);
    return fclose(fp);
}

__asm__("\n&FUNC    SETC 'ses_reg_jes'");
int session_register_jes(Session *session, JES *jes)
{
    if (!session || !jes) return -1;
    if (session->open_jes) {
        // one slot, and no path opens two at a time -- see router.h. Say so
        // rather than overwrite, which would leak the handle in the slot.
        wtof(MSG_JES_TRACKED);
        return -1;
    }
    session->open_jes = jes;
    return 0;
}

__asm__("\n&FUNC    SETC 'ses_jesclose'");
void session_jesclose(Session *session, JES **jes)
{
    if (!jes || !*jes) return;
    if (session && session->open_jes == *jes) {
        session->open_jes = NULL;
    }
    jesclose(jes);
}

// Thunk for ESTAE-protected jesclose() during recovery.
// Returns 0 on success; a secondary abend is caught by try().
__asm__("\n&FUNC    SETC 'safe_jesclose'");
static int safe_jesclose_thunk(JES *jes)
{
    JES *local = jes;

    jesclose(&local);
    return 0;
}

// Thunk for ESTAE-protected fclose during recovery.
// Returns 0 on success; a secondary abend is caught by try().
__asm__("\n&FUNC    SETC 'safe_fclose'");
static int safe_fclose_thunk(FILE *fp)
{
    if (fp->buf) {
        fp->upto = fp->buf;  // discard buffer — no flush
    }
    fclose(fp);
    return 0;
}

// Thunk for ESTAE-protected DEQ during recovery.
// Returns 0 on success; a secondary abend is caught by try().
__asm__("\n&FUNC    SETC 'safe_unlock'");
static int safe_unlock_thunk(void *anchor)
{
    unlock(anchor, LOCK_EXC);
    return 0;
}

// Same for the data set list ENQ, which is named, not addressed (#436).
__asm__("\n&FUNC    SETC 'safe_unlkres'");
static int safe_unlock_dslist_thunk(void *unused)
{
    (void)unused;
    unlock_res(DSLIST_LOCK_RNAME, LOCK_EXC);
    return 0;
}

__asm__("\n&FUNC    SETC 'ses_cleanup'");
void session_cleanup(Session *session)
{
    int i;
    if (!session) return;

    // Close tracked FILE handles under individual ESTAE protection.
    // A corrupted pointer from the original abend must not prevent
    // cleanup of the remaining resources.
    for (i = 0; i < session->open_file_count; i++) {
        FILE *fp = session->open_files[i];
        if (fp) {
            wtof(MSG_RECOVERY_CLOSE, fp->dataset, fp->ddname);
            if (try(safe_fclose_thunk, fp) != 0) {
                wtof(MSG_RECOVERY_ABEND, i);
            }
            session->open_files[i] = NULL;
        }
    }
    session->open_file_count = 0;

    // The JES handle holds the JES2 spool data sets. Left open it costs the
    // address space their DCBs for good, and an abend inside jesjob() is
    // exactly the case that skips the handler's own jesclose() (issue #286).
    if (session->open_jes) {
        JES *jes = session->open_jes;

        session->open_jes = NULL;
        wtof(MSG_RECOVERY_JES);
        if (try(safe_jesclose_thunk, jes) != 0) {
            wtof(MSG_RECOVERY_JES_ABEND);
        }
    }

    // The console correlation ENQ (#214). Unlike a data set or a JES handle
    // this costs no storage, but leaving it held is worse: every later console
    // command waits its full acquire budget and then answers 429, for the life
    // of the STC. session_cleanup() runs on the worker that took it, which is
    // what makes the DEQ legal here -- the ENQ is task-scoped and this task
    // survived the abend.
    if (session->console_lock) {
        void *anchor = session->console_lock;

        session->console_lock = NULL;
        wtof(MSG_RECOVERY_CONSLK);
        if (try(safe_unlock_thunk, anchor) != 0) {
            wtof(MSG_RECOVERY_CONSLK_ABEND);
        }
    }

    // The data set list ENQ (#436), for the reason the console one is above:
    // left held, every later list waits for it for the life of the STC.
    if (session->dslist_lock) {
        session->dslist_lock = 0;
        wtof(MSG_RECOVERY_DSLSTLK);
        if (try(safe_unlock_dslist_thunk, NULL) != 0) {
            wtof(MSG_RECOVERY_DSLSTLK_ABEND);
        }
    }

    // UFS session lifecycle is managed by HTTPD (http_get_ufs).
    // HTTPD's worker ESTAE handles cleanup on abend.
}

//
// private functions
//

__asm__("\n&FUNC    SETC 'hex_nibble'");
static unsigned char
hex_nibble(char c)
{
	if (c >= '0' && c <= '9') return c - '0';
	if (c >= 'A' && c <= 'F') return c - 'A' + 10;
	if (c >= 'a' && c <= 'f') return c - 'a' + 10;
	return 0;
}

__asm__("\n&FUNC    SETC 'is_hex_digit'");
static int
is_hex_digit(char c)
{
	return (c >= '0' && c <= '9') ||
	       (c >= 'A' && c <= 'F') ||
	       (c >= 'a' && c <= 'f');
}

// Decode percent-encoded characters in-place.
// URL percent-encoding uses ASCII byte values (e.g. %28 = ASCII '(').
// Since we run on EBCDIC, decoded bytes must be converted from ASCII to EBCDIC.
__asm__("\n&FUNC    SETC 'percent_decode'");
static void
percent_decode(Session *session, char *str)
{
	char *src = str;
	char *dst = str;

	while (*src) {
		if (*src == '%' && is_hex_digit(src[1]) && is_hex_digit(src[2])) {
			unsigned char ascii_val = (hex_nibble(src[1]) << 4) | hex_nibble(src[2]);
			http_atoe(&ascii_val, 1);
			*dst = (char)ascii_val;
			src += 3;
		} else {
			*dst = *src;
			src++;
		}
		dst++;
	}
	*dst = '\0';
}

__asm__("\n&FUNC	SETC 'route_matching_middleware'");
static 
int route_matching_middleware(Session *sessionr) 
{
    (void)sessionr;
    // Hier kommt die eigentliche RouteMatching-Logik

    return 0;
}

__asm__("\n&FUNC	SETC 'path_vars_extracting_middleware'");
static 
int path_vars_extracting_middleware(Session *session) 
{
    (void)session;
    // Hier kommt die eigentliche PathVars-Logik

    return 0;
}

__asm__("\n&FUNC	SETC 'parseMethod'");
static 
HttpMethod parseMethod(const char *method) 
{
    if (strcmp(method, "GET") == 0) return GET;
    if (strcmp(method, "POST") == 0) return POST;
    if (strcmp(method, "PUT") == 0) return PUT;
    if (strcmp(method, "DELETE") == 0) return DELETE;
    
    return (HttpMethod) -1; 
}

__asm__("\n&FUNC	SETC 'find_route'");
static 
Route *find_route(Router *router, HttpMethod method, const char *path)
{
    int i = 0;
    for (i = 0; i < (int)router->route_count; i++) {
        if (router->routes[i].method == method) {
            if (is_pattern_match(router->routes[i].pattern, path)) {
                return &router->routes[i];
            }
        }
    }
    return NULL;
}

__asm__("\n&FUNC	SETC 'path_is_known'");
static
int path_is_known(Router *router, const char *path)
{
    int i = 0;
    for (i = 0; i < (int)router->route_count; i++) {
        if (is_pattern_match(router->routes[i].pattern, path)) {
            return 1;
        }
    }
    return 0;
}

__asm__("\n&FUNC	SETC 'is_pattern_match'");
static
int is_pattern_match(const char *pattern, const char *path)
{
    while (*pattern && *path) {
        if (*pattern == '{') {
            int is_wildcard = (*(pattern + 1) == '*');
            if (is_wildcard) pattern++;
            while (*pattern && *pattern != '}') pattern++;
            if (*pattern == '}') pattern++;

            if (is_wildcard) {
                /* {*var} consumes entire remaining path including slashes */
                while (*path) path++;
            } else {
                while (*path && *path != '/' && *path != '(' && *path != ')') path++;
            }
        } else {
            if (*pattern == *path) {
                pattern++;
                path++;
            } else {
                return 0;
            }
        }
    }

    /* A trailing {*wildcard} matches empty when path is already consumed */
    while (*pattern == '{' && *(pattern + 1) == '*') {
        while (*pattern && *pattern != '}') pattern++;
        if (*pattern == '}') pattern++;
    }

    return *pattern == '\0' && *path == '\0';
}

__asm__("\n&FUNC	SETC 'extract_path_vars'");
static
int extract_path_vars(Session *session, const char *pattern, const char *path)
{
    if (session == NULL || pattern == NULL || path == NULL) {
        return -1;
    }

    HTTPC *httpc = session->httpc;

    while (*pattern) {
        if (*pattern == '{') {
            pattern++;
            int is_wildcard = (*pattern == '*');
            if (is_wildcard) pattern++;
            const char *var_start = pattern;
            while (*pattern && *pattern != '}') pattern++;
            int var_name_len = pattern - var_start;
            char var_name[256];
            strncpy(var_name, var_start, var_name_len);
            var_name[var_name_len] = '\0';
            if (*pattern == '}') pattern++;

            const char *value_start = path;

            if (is_wildcard) {
                /* {*var} captures entire remaining path */
                while (*path) path++;
            } else {
                const char *pattern_next = pattern;
                while (*pattern_next && *pattern_next != '/' && *pattern_next != '(' && *pattern_next != ')') pattern_next++;

                while (*path && *path != *pattern_next) path++;
            }

            int value_len = path - value_start;
            char value[1024];
            strncpy(value, value_start, value_len);
            value[value_len] = '\0';

            /* Trim trailing spaces - clients like Zowe Explorer
               may pad names with spaces (e.g. member names to 8 chars) */
            while (value_len > 0 && value[value_len - 1] == ' ') {
                value[--value_len] = '\0';
            }

            char env_name[256];
            sprintf(env_name, "HTTP_%s", var_name);
            http_set_env(httpc, (UCHAR *) env_name, (UCHAR *) value);

        } else {
            if (*pattern == *path) {
                pattern++;
                path++;
            } else {
                return 0;
            }
        }
    }

	return 0;
}
