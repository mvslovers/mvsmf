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
#include "httpcgi.h"

/** @brief Memory alignment for half word */
#define HALF_WORD_ALIGNMENT 16

/** @brief Memory alignment for full word */
#define FULL_WORD_ALIGNMENT 32

/** @brief Maximum number of routes that can be registered */
#define MAX_ROUTES 100

/** @brief Maximum number of middlewares that can be registered */
#define MAX_MIDDLEWARES 10

/** @brief Maximum number of tracked open files per session (ESTAE recovery) */
#define MAX_SESSION_FILES 4

#define httpx http_get_httpx(session->httpd)

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
    const char *name;          /**< Middleware name for identification */
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
    int headers_sent;      /**< Non-zero after HTTP headers written to socket */
    // Resource tracking for ESTAE abend recovery
    FILE *open_files[MAX_SESSION_FILES];  /**< Tracked FILE handles */
    int open_file_count;                  /**< Number of tracked files */
    void *ufs;             /**< UFS session (opaque, libufs UFS *) */
    void *ufs_file;        /**< UFS file handle (opaque, libufs UFSFILE *) */
    void (*ufs_cleanup)(struct session *s); /**< UFS cleanup callback (set by ussapi) */
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
void add_middleware(Router *router, const char *middleware_name, MiddlewareHandler handler) asm("RTR0004");

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

/**
 * @brief Register a FILE handle for ESTAE recovery cleanup
 * @return 0 on success, -1 if tracking table is full
 */
int session_register_file(Session *session, FILE *fp) asm("RTR0006");

/**
 * @brief Unregister a FILE handle after successful fclose
 */
void session_unregister_file(Session *session, FILE *fp) asm("RTR0007");

/**
 * @brief Unregister and close a tracked FILE handle
 */
void session_fclose(Session *session, FILE *fp) asm("RTR0008");

/**
 * @brief Close all tracked resources (ESTAE recovery)
 *
 * Closes all registered FILE handles, UFS file handles and UFS sessions.
 * Called by the router after catching a handler abend.
 */
void session_cleanup(Session *session) asm("RTR0009");

#endif // ROUTER_H
