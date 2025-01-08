#ifndef ROUTER_H
#define ROUTER_H

/**
 * @file router.h
 * @brief HTTP request routing and middleware framework for MVS 3.8j
 *
 * Provides routing functionality for HTTP requests with support for
 * path parameters, middleware chains, and request handlers.
 */

#include <stddef.h>
#include "acee.h"
#include "httpd.h"

/** @brief Memory alignment for half word */
#define HALF_WORD_ALIGNMENT 16

/** @brief Memory alignment for full word */
#define FULL_WORD_ALIGNMENT 32

/** @brief Maximum number of routes that can be registered */
#define MAX_ROUTES 100

/** @brief Maximum number of middlewares that can be registered */
#define MAX_MIDDLEWARES 10

#define httpx session->httpd->httpx

// Forward declarations
typedef struct route Route;
typedef struct router Router;
typedef struct middleware Middleware;
typedef struct session Session;
typedef int (*RouteHandler)(Session *session);
typedef int (*MiddlewareHandler)(Session *session);

/**
 * @brief HTTP method enumeration
 */
typedef enum {
    GET,
    POST,
    PUT,
    DELETE,
    HEAD,
    OPTIONS,
    PATCH
} HttpMethod;

/**
 * @brief Route definition structure
 */
struct route {
    HttpMethod method;      /**< HTTP method for this route */
    const char *pattern;    /**< URL pattern with optional parameters */
    RouteHandler handler;   /**< Handler function for this route */
} __attribute__((aligned(FULL_WORD_ALIGNMENT)));

/**
 * @brief Middleware definition structure
 */
struct middleware {
    char *name;                /**< Middleware name for identification */
    MiddlewareHandler handler; /**< Middleware handler function */
} __attribute__((aligned(HALF_WORD_ALIGNMENT)));

/**
 * @brief Router configuration structure
 */
struct router {
    size_t route_count;                    /**< Number of registered routes */
    Route routes[MAX_ROUTES];              /**< Array of registered routes */
    size_t middleware_count;               /**< Number of registered middlewares */
    Middleware middlewares[MAX_ROUTES];    /**< Array of registered middlewares */
} __attribute__((aligned(FULL_WORD_ALIGNMENT)));

/**
 * @brief Session context structure
 */
struct session {
    Router *router;        /**< Reference to the router */
    HTTPD *httpd;          /**< HTTPD server instance */
    HTTPC *httpc;          /**< HTTP client connection */
    ACEE *acee;            /**< RACF ACEE for authenticated user */
    ACEE *old_acee;        /**< Previous ACEE for restoration */
    void *user_data;       /**< Custom user data */
    char *session_id;      /**< Unique session identifier */
    time_t created_at;     /**< Session creation timestamp */
    time_t last_accessed;  /**< Last access timestamp */
} __attribute__((aligned(FULL_WORD_ALIGNMENT)));

/**
 * @brief Initializes a new router instance
 *
 * Sets up a router with default middleware for route matching
 * and path variable extraction.
 *
 * @param router Pointer to Router structure to initialize
 */
void init_router(Router *router) asm("RTR0001");

/**
 * @brief Initializes a new session context
 *
 * Sets up a session with the given router and HTTP context.
 *
 * @param session Session to initialize
 * @param router Router for request handling
 * @param httpd HTTPD server instance
 * @param httpc HTTP client connection
 */
void init_session(Session *session, Router *router, HTTPD *httpd, HTTPC *httpc) asm("RTR0002");

/**
 * @brief Adds a new route to the router
 *
 * Registers a handler for a specific HTTP method and URL pattern.
 *
 * @param router Router to add route to
 * @param method HTTP method for the route
 * @param pattern URL pattern with optional parameters
 * @param handler Handler function for the route
 */
void add_route(Router *router, HttpMethod method, const char *pattern, RouteHandler handler) asm("RTR0003");

/**
 * @brief Adds a new middleware to the router
 *
 * Registers a middleware function to be executed before route handlers.
 *
 * @param router Router to add middleware to
 * @param middleware_name Name of the middleware
 * @param handler Middleware handler function
 */
void add_middleware(Router *router, char *middleware_name, MiddlewareHandler handler) asm("RTR0004");

/**
 * @brief Handles an incoming HTTP request
 *
 * Executes middleware chain and routes request to appropriate handler.
 *
 * @param router Router containing routes and middleware
 * @param session Current session context
 * @return 0 on success, negative value on error
 */
int handle_request(Router *router, Session *session) asm("RTR0005");

#endif // ROUTER_H
