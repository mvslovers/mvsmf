#ifndef HTTPR_H
#define HTTPR_H

#include "httpd.h"

#define httpx httpr->httpd->httpx

// Forward declaration
typedef struct httpr HTTPR;

typedef enum {
    GET,
    POST,
    PUT,
    DELETE,
    HEAD,
    OPTIONS,
    PATCH
} HttpMethod;

typedef int (*RouteHandler)(HTTPR *httpr);

typedef struct {
    HttpMethod method;
    const char *pattern;
    RouteHandler handler;
} Route;

#define MAX_ROUTES 100

struct httpr {
    HTTPD *httpd; 
    HTTPC *httpc; 
    size_t route_count;
    Route routes[MAX_ROUTES];
};

void init_router(HTTPR *httpr, HTTPD *httpd, HTTPC *httpc);
void add_route(HTTPR *httpr, HttpMethod method, const char *pattern, RouteHandler handler);
int  handle_request(HTTPR *httpr);

#endif // HTTPR_H
