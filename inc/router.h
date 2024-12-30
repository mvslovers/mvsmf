#ifndef HTTPR_H
#define HTTPR_H

#include <stddef.h>
#include "acee.h"
#include "httpd.h"

#define MAX_ROUTES 100
#define MAX_MIDDLEWARES 10

#define httpx session->httpd->httpx

// Forward declaration
typedef struct route Route;
typedef struct router Router;
typedef struct middleware Middleware;
typedef struct session Session;
typedef int (*RouteHandler)(Session *session);
typedef int (*MiddlewareHandler)(Session *session);

typedef enum {
    GET,
    POST,
    PUT,
    DELETE,
    HEAD,
    OPTIONS,
    PATCH
} HttpMethod;

struct route {
    HttpMethod method;
    const char *pattern;
    RouteHandler handler;
};

struct middleware {
    char *name;
    MiddlewareHandler handler;
};

struct router {  
    size_t route_count;
    Route routes[MAX_ROUTES];
    size_t middleware_count;
    Middleware middlewares[MAX_ROUTES];
};

struct session {
    Router *router;
    HTTPD *httpd; 
    HTTPC *httpc; 
    ACEE *acee; 
    ACEE *old_acee;
    void *user_data;         
    char *session_id;        
    time_t created_at;       
    time_t last_accessed;    
};

//
// public functions
//

void init_router(Router *router);
void init_session(Session *session, Router *router, HTTPD *httpd, HTTPC *httpc);
void add_route(Router *router, HttpMethod method, const char *pattern, RouteHandler handler);
void add_middleware(Router *router, char *middleware_name, MiddlewareHandler handler);
int  handle_request(Router *router, Session *session);

//
// internal functions
//

char* _get_host(HTTPD *httpd, HTTPC *httpc);
int   _send_response(Session *session, int status_code, const char *content_type, const char *data);
int   _recv(HTTPC *httpc, char *buf, int len);

#endif // HTTPR_H
