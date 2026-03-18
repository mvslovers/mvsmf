#include <stdio.h>
#include <string.h>
#include <clibwto.h>
#include <clibtry.h>
#include <libufs.h>

#include "router.h"
#include "common.h"
#include "httpcgi.h"
#include "xlate.h"


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

static int route_matching_middleware(Session *session);
static int path_vars_extracting_middleware(Session *session);

static unsigned char hex_nibble(char c);
static int is_hex_digit(char c);
static void percent_decode(char *str);

static HttpMethod parseMethod(const char *method);
static Route *find_route(Router *router, HttpMethod method, const char *path);
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
        wtof("MAX_ROUTES limit reached.");
        return;
    }

    if (!pattern || !handler) {
        wtof("Invalid route parameters");
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
        wtof("MVSMF12E MAX_MIDDLEWARES limit reached.");
        return;
    }

    Middleware *middleware = &router->middlewares[router->middleware_count++];
    middleware->name = middleware_name;
    middleware->handler = handler;
}

int handle_request(Router *router, Session *session) 
{
    if (router == NULL || session == NULL) {
        wtof("Invalid Router or Session pointer");
        return -1;
    } 

    // needed for http_get_env
    HTTPD *httpd = session->httpd;
    HTTPC *httpc = session->httpc;

    char *method = (char *) http_get_env(httpc, (const UCHAR *) "REQUEST_METHOD");
    char *raw_path = (char *) http_get_env(httpc, (const UCHAR *) "REQUEST_PATH");
    char path[1024];

    // Percent-decode the request path (e.g. %28/%29 -> parentheses)
    strncpy(path, raw_path, sizeof(path) - 1);
    path[sizeof(path) - 1] = '\0';
    percent_decode(path);

    HttpMethod reqMethod = parseMethod(method);
    if (reqMethod == -1) {
        http_resp(httpc, 405);
        return -1;
    }

    // Execute all middlewares in sequence
    size_t i = 0;
    for (i = 0; i < router->middleware_count; i++) {
        int rc = router->middlewares[i].handler(session);
        if (rc != 0) {
            return rc;  // Middleware aborted the chain
        }
    }

    Route *route = find_route(router, reqMethod, path);

    if (route == NULL) {
        wtof("MVSMF01W No route for %s %s", method, path);
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
        wtof("MVSMF99E Handler abend S%03X U%04d for %s %s",
             sys, usr, method, path);
        session_cleanup(session);
        sendErrorResponse(session, 500, 6, 8, 99,
            "Internal server error (abend recovery)", NULL, 0);
        return -1;
    }
    return ctx.rc;
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
void session_register_file(Session *session, FILE *fp)
{
    if (!session || !fp) return;
    if (session->open_file_count >= MAX_SESSION_FILES) {
        wtof("MVSMF98W session file tracking full, cannot register");
        return;
    }
    session->open_files[session->open_file_count++] = fp;
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
void session_fclose(Session *session, FILE *fp)
{
    if (!session || !fp) return;
    session_unregister_file(session, fp);
    fclose(fp);
}

__asm__("\n&FUNC    SETC 'ses_cleanup'");
void session_cleanup(Session *session)
{
    int i;
    if (!session) return;

    // Close tracked FILE handles.
    // Reset buffer pointer so fclose does NOT flush dirty data —
    // the original I/O error (e.g. D37) would re-abend on flush.
    for (i = 0; i < session->open_file_count; i++) {
        FILE *fp = session->open_files[i];
        if (fp) {
            wtof("MVSMF99I Recovery: closing %s (DD:%s)",
                 fp->dataset, fp->ddname);
            fp->upto = fp->buf;  // discard buffer — no flush
            fclose(fp);
            session->open_files[i] = NULL;
        }
    }
    session->open_file_count = 0;

    // close UFS file handle (UFSFILE *) if tracked
    if (session->ufs_file) {
        wtof("MVSMF99I Recovery: closing UFS file at %p",
             session->ufs_file);
        ufs_fclose((void *)&session->ufs_file);
    }

    // close UFS session if tracked
    if (session->ufs) {
        wtof("MVSMF99I Recovery: freeing UFS session at %p",
             session->ufs);
        ufsfree((void *)&session->ufs);
    }
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
percent_decode(char *str)
{
	char *src = str;
	char *dst = str;

	while (*src) {
		if (*src == '%' && is_hex_digit(src[1]) && is_hex_digit(src[2])) {
			unsigned char ascii_val = (hex_nibble(src[1]) << 4) | hex_nibble(src[2]);
			mvsmf_atoe(&ascii_val, 1);
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
    // wtof("MVSMF42D TODO: MATCHING ROUTES");

    // Hier kommt die eigentliche RouteMatching-Logik

    return 0;
}

__asm__("\n&FUNC	SETC 'path_vars_extracting_middleware'");
static 
int path_vars_extracting_middleware(Session *session) 
{
    // wtof("MVSMF42D TODO: EXTRACTING PATH VARS");

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
    for (i = 0; i < router->route_count; i++) {
        if (router->routes[i].method == method) {
            if (is_pattern_match(router->routes[i].pattern, path)) {
                return &router->routes[i];
            }
        }
    }
    return NULL;
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

    HTTPD *httpd = session->httpd;
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
