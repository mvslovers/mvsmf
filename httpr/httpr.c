#include <stdio.h>
#include <string.h>

#include "httpr.h"
#include "httpd.h"

// internal functions declaration
static HttpMethod parseMethod(const char *method); 
static Route *find_route(HTTPR *httpr, HttpMethod method, const char *path);
static int is_pattern_match(const char *pattern, const char *path);
static int extract_path_vars(HTTPR *httpr, const char *pattern, const char *path);

//
// public functions
//

void init_router(HTTPR *httpr, HTTPD *httpd, HTTPC *httpc) 
{
    memset(httpr, 0, sizeof(HTTPR));  
    httpr->httpd = httpd;
    httpr->httpc = httpc;
}

void add_route(HTTPR *httpr, HttpMethod method, const char *pattern, RouteHandler handler) 
{
    if (httpr->route_count >= MAX_ROUTES) {
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

    Route *route = &httpr->routes[httpr->route_count++];
    route->method = method;
    route->pattern = pattern_copy;
    route->handler = handler;

}

int handle_request(HTTPR *httpr) 
{
    if (httpr == NULL) {
        wtof("Invalid HTTPR pointer");
        return -1;
    } 
    // needed for http_get_env
    HTTPD *httpd = httpr->httpd;

    char *method = (char *) http_get_env(httpr->httpc, (const UCHAR *) "REQUEST_METHOD");
    char *path = (char *) http_get_env(httpr->httpc, (const UCHAR *) "REQUEST_PATH");

    HttpMethod reqMethod = parseMethod(method);
    if (reqMethod == -1) {
        http_resp(httpr->httpc, 405);
        return -1;
    }

    Route *route = find_route(httpr, reqMethod, path);
    
    if (route == NULL) {
        wtof("Unknown route requested. %s %s",   
            (char *) http_get_env(httpr->httpc, (const UCHAR *) "REQUEST_METHOD"),
            (char *) http_get_env(httpr->httpc, (const UCHAR *) "REQUEST_URI"));

        http_resp(httpr->httpc, 404);
        return -1;
    }

    extract_path_vars(httpr, route->pattern, path);
    
    // call the handler
    return route->handler(httpr);
}

//
// internal functions
//

static 
HttpMethod parseMethod(const char *method) 
{
    if (strcmp(method, "GET") == 0) return GET;
    if (strcmp(method, "POST") == 0) return POST;
    if (strcmp(method, "PUT") == 0) return PUT;
    if (strcmp(method, "DELETE") == 0) return DELETE;
    
    return (HttpMethod) -1; 
}

static 
Route *find_route(HTTPR *httpr, HttpMethod method, const char *path)
{
    int i = 0;
    for (i = 0; i < httpr->route_count; i++) {
        if (httpr->routes[i].method == method && 
            is_pattern_match(httpr->routes[i].pattern, path)) {
            return &httpr->routes[i];
        }
    }
    return NULL;
}

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

static 
int extract_path_vars(HTTPR *httpr, const char *pattern, const char *path) 
{
    if (httpr == NULL || pattern == NULL || path == NULL) {
        return -1;
    }

    HTTPD *httpd = httpr->httpd;
    HTTPC *httpc = httpr->httpc;

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
}
