#include <stdio.h>
#include <string.h>

#include "router.h"
#include "common.h"
#include "httpd.h"


#define INITIAL_BUFFER_SIZE 4096

//	
// private function prototypes
//

static int route_matching_middleware(Session *session);
static int path_vars_extracting_middleware(Session *session);

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

    const char *pattern_copy = strdup(pattern);
    if (!pattern_copy) {
        wtof("Memory allocation failed for route pattern");
        return;
    }

    Route *route = &router->routes[router->route_count++];
    route->method = method;
    route->pattern = pattern_copy;
    route->handler = handler;

}

void add_middleware(Router *router, char *middleware_name, MiddlewareHandler handler)
{
    if (router->middleware_count >= MAX_MIDDLEWARES) {
        wtof("MVSMF12E MAX_MIDDLEWARES limit reached.");
        return;
    }

    Middleware *middleware = &router->middlewares[router->middleware_count++];
    middleware->name = strdup(middleware_name);
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
    char *path = (char *) http_get_env(httpc, (const UCHAR *) "REQUEST_PATH");
    
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
        sendErrorResponse(session, HTTP_STATUS_NOT_FOUND, 6, 4, 7, "Not Found", NULL, 0);        
        return -1;
    }

    extract_path_vars(session, route->pattern, path);

    // call the handler
    return route->handler(session);
}

//
// private functions
//

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
        if (router->routes[i].method == method && 
            is_pattern_match(router->routes[i].pattern, path)) {
            return &router->routes[i];
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
            while (*pattern && *pattern != '}') pattern++;
            if (*pattern == '}') pattern++;

            while (*path && *path != '/' && *path != '(' && *path != ')') path++;
        } else {
            if (*pattern == *path) {
                pattern++;
                path++;
            } else {
                return 0;
            }
        }
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
            const char *var_start = pattern;
            while (*pattern && *pattern != '}') pattern++;
            int var_name_len = pattern - var_start;
            char var_name[256];
            strncpy(var_name, var_start, var_name_len);
            var_name[var_name_len] = '\0';
            if (*pattern == '}') pattern++;

            const char *pattern_next = pattern;
            while (*pattern_next && *pattern_next != '/' && *pattern_next != '(' && *pattern_next != ')') pattern_next++;

            const char *value_start = path;
            while (*path && *path != *pattern_next) path++;
            int value_len = path - value_start;
            char value[1024];
            strncpy(value, value_start, value_len);
            value[value_len] = '\0';

            char env_name[256];
            sprintf(env_name, "HTTP_%s", var_name);
            http_set_env(httpc, (UCHAR *) env_name, (UCHAR *) strdup(value));
            
            //insert(vars, strdup(var_name), strdup(value));

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
