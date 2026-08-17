#ifndef COMMON_H
#define COMMON_H

/**
 * @file common.h
 * @brief Common utilities and HTTP response handling for MVS 3.8j
 *
 * Provides shared functionality for HTTP request/response handling,
 * parameter extraction, and error responses in z/OSMF compatible format.
 */

#include "json.h"
#include "router.h"
#include <stddef.h>

/** @brief Memory alignment for full word */
#define FULL_WORD_ALIGNMENT 32

/** @brief Maximum size for environment variable names */
#define ENV_NAME_SIZE 256

/** @brief Decimal base for string to number conversion */
#define DECIMAL_BASE 10

/** @brief ASCII carriage return */
#define CR 0x0D

/** @brief ASCII line feed */
#define LF 0x0A

/** @brief EBCDIC line feed */
#define EBCDIC_LF 0x25

/** @brief EBCDIC newline (NEL) - used by CP037 A2E for ASCII LF (0x0A) */
#define EBCDIC_NEL 0x15

/** @brief HTTP status codes
 *
 * z/OSMF enumerates the status codes its API uses, and mvsMF is a clone of it:
 * 200, 204, 206, 304, 400, 401, 404, 405, 412, 413, 429, 500, 503. Do not add a
 * constant here for a code outside that set, however much better it reads --
 * 409, 414 and 507 were declined in #102, and 410 and 403 were removed again in
 * #250 after being introduced. httpd can put all of them on the wire; that is
 * not the constraint.
 *
 * 201 is the one code below that is outside the list and still correct: the
 * reference implementation was measured answering 201 to a data set create, so
 * it is what a clone does (#248).
 */
#define HTTP_STATUS_OK 200                    /**< Success */
#define HTTP_STATUS_CREATED 201               /**< Resource created - see above */
#define HTTP_STATUS_ACCEPTED 202              /**< Request accepted - unused */
#define HTTP_STATUS_NOT_MODIFIED 304          /**< If-None-Match still current */
#define HTTP_STATUS_BAD_REQUEST 400           /**< Invalid parameters */
#define HTTP_STATUS_UNAUTHORIZED 401          /**< Unauthorized */
#define HTTP_STATUS_NOT_FOUND 404             /**< Resource not found */
#define HTTP_STATUS_PRECONDITION_FAILED 412   /**< If-Match ETag no longer current */
#define HTTP_STATUS_INTERNAL_SERVER_ERROR 500 /**< Server error */
#define HTTP_STATUS_SERVICE_UNAVAILABLE 503  /**< Service unavailable */

/** @brief HTTP status messages */
#define HTTP_MSG_OK "OK"
#define HTTP_MSG_CREATED "Created"
#define HTTP_MSG_ACCEPTED "Accepted"
#define HTTP_MSG_BAD_REQUEST "Bad Request"
#define HTTP_MSG_INTERNAL_SERVER_ERROR "Internal Server Error"

/** @brief Content type definitions */
#define HTTP_CONTENT_TYPE_NONE "n/a"
#define HTTP_CONTENT_TYPE_JSON "application/json"

/** @brief Return codes */
#define RC_SUCCESS  0   /**< Success condition */
#define RC_WARNING  4   /**< Warning condition */
#define RC_ERROR    8   /**< Error condition */
#define RC_AUTH    12   /**< Authorization error */
#define RC_SEVERE  16   /**< Severe error */

/**
 * @brief Gets a query parameter from the request URL
 *
 * Extracts and returns the value of a named query parameter.
 * Returns NULL if parameter is not found.
 *
 * @param session Current session context
 * @param name Name of the query parameter
 * @return Value of parameter or NULL if not found
 */
char *getQueryParam(Session *session, const char *name) asm("CMN0001");

/**
 * @brief Gets a path parameter from HTTP headers
 *
 * Extracts and returns the value of a named path parameter.
 * Path parameters are extracted from URL patterns like /jobs/{jobname}.
 *
 * @param session Current session context
 * @param name Name of the path parameter
 * @return Value of parameter or NULL if not found
 */
char *getPathParam(Session *session, const char *name) asm("CMN0002");

/**
 * @brief Gets a header parameter from HTTP request
 *
 * Extracts and returns the value of a named HTTP header.
 *
 * @param session Current session context
 * @param name Name of the header parameter
 * @return Value of header or NULL if not found
 */
char *getHeaderParam(Session *session, const char *name) asm("CMN0003");

/**
 * @brief Gets the scheme the client used to reach this server
 *
 * mvsMF cannot infer the scheme from its own connection: behind a
 * TLS-terminating reverse proxy it always sees plain HTTP, whatever the
 * client used. The proxy reports the original scheme in X-Forwarded-Proto,
 * so that header is the only source. Absent or anything but https, the
 * answer is http.
 *
 * @param session Current session context
 * @return "https" or "http" (a literal, never NULL — do not free)
 */
const char *getRequestScheme(Session *session) asm("CMN0004");

/**
 * @brief Sends default HTTP headers for a response
 *
 * Sends standard HTTP headers including status code, content type,
 * and cache control directives.
 *
 * @param session Current session context
 * @param status HTTP status code
 * @param content_type Content type of response
 * @param content_length Length of response body
 * @return 0 on success, negative value on error
 */
int sendDefaultHeaders(Session *session, int status, const char *content_type,
                      size_t content_length) asm("CMN0010");

/**
 * @brief Sends a JSON response
 *
 * Sends HTTP response with JSON content type and body from JsonBuilder.
 *
 * @param session Current session context
 * @param status HTTP status code
 * @param builder JsonBuilder containing response body
 * @return 0 on success, negative value on error
 */
int sendJSONResponse(Session *session, int status,
                    JsonBuilder *builder) asm("CMN0011");

/**
 * @brief Sends an error response in z/OSMF format
 *
 * Sends standardized error response with category, reason code,
 * message and optional details.
 *
 * @param session Current session context
 * @param status HTTP status code
 * @param category Error category code
 * @param rc Return code
 * @param reason Error reason code
 * @param message Error message
 * @param details Array of additional error details
 * @param details_count Number of detail entries
 * @return rc parameter value
 */
int sendErrorResponse(Session *session, int status, int category, int rc,
                     int reason, const char *message, const char **details,
                     int details_count) asm("CMN0012");

/**
 * @brief Answers a conditional read whose If-None-Match still holds
 *
 * No body and no Content-Type: the client keeps the representation it already
 * has, and a 304 that described a payload it is not sending would only invite
 * a client to believe there is one. The other headers mirror what the 200
 * would have carried, which is what RFC 9110 asks a 304 to do.
 *
 * The ETag goes out even when the request did not ask for one with
 * X-IBM-Return-Etag. That looks like it contradicts the opt-in, and does not:
 * a client sending If-None-Match is already speaking the ETag protocol, and
 * the stamp had to be computed to answer at all. Withholding it would only
 * cost the client its confirmation of which state it is now holding.
 *
 * Resource-agnostic on purpose — data sets and members answer with it (#263)
 * and so do USS files (#271). Anything specific to one of them belongs in the
 * caller, not here.
 *
 * @param session Current session context
 * @param etag The stamp the request's If-None-Match matched
 * @return 0 on success, negative value on error
 */
int send_not_modified(Session *session, const char *etag) asm("CMN0013");

/**
 * @brief Reads the full request body into a malloc'd buffer
 *
 * Supports both Content-Length and Transfer-Encoding: chunked.
 * Uses single-byte recv() to work around the MVS 3.8j TCP/IP
 * ring buffer bug. Caller must free the returned buffer.
 *
 * @param session Current session context
 * @param content Output pointer to allocated buffer (caller frees)
 * @param content_size Output size of received content
 * @return 0 on success, -1 on error
 */
int read_request_content(Session *session, char **content,
                        size_t *content_size) asm("CMN0020");

#endif // COMMON_H
