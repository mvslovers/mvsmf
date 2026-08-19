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

/** @brief The z/OSMF error report for an authorization refusal (#228, #315)
 *
 * Measured against a real z/OSMF (version 29 / z/OS 05.29.00): a member read of
 * a data set the caller may not open answers
 *
 *   500 {"category":4,"rc":8,"reason":0,"message":"LMOPEN error",
 *        "details":["ISRZ002 Authorization failed - You may not use this
 *                    protected data set. Open 913 abend."]}
 *
 * So 500 is the conformant status for a denial and always was -- 403 is wrong
 * twice over, being absent from the z/OSMF list (#250) and not what the
 * reference sends. The status is the one field mvsMF already had right.
 *
 * `category 4` is MEASURED, not documented. It is defined in neither
 * zosmferr.h nor jobsapi_msg.h, and those two already disagree with each other
 * (CATEGORY_VSAM 3 vs 7, CATEGORY_UNEXPECTED 7 vs 8), so do not promote it to a
 * general "authorization category" on the strength of one observation.
 *
 * The reason stays the reference's 0 rather than becoming a project-specific
 * code: fidelity is the point, and the distinction the project would otherwise
 * carry in `reason` is in `details[]` here, which is where the reference puts
 * it. The name exists for readability, not to introduce a new code.
 *
 * `message` is the reference's string verbatim. `ISRZ002` is deliberately NOT
 * reproduced -- it is an ISPF message id, and mvsMF runs no ISPF library
 * management, so quoting it would name a component that is not there.
 */
#define CATEGORY_AUTHORIZATION 4
#define REASON_NOT_AUTHORIZED  0
#define ERR_MSG_NOT_AUTHORIZED "LMOPEN error"

/** Default `details[]` sentence for a refusal caught by a pre-check.
 *
 * The reference's own text ends "Open 913 abend." -- true for it, since OPEN is
 * what refused. A pre-check that answers before the fopen() has taken no abend,
 * so it stops one clause earlier. #315 supplies the abend-carrying variant for
 * the ESTAE path.
 */
#define ERR_MSG_DENIED_DETAIL \
	"Authorization failed - You may not use this protected data set."

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
 * @brief Sends the WWW-Authenticate challenge on a 401
 *
 * No-op for any other status, and withheld from a browser fetch/XHR: there the
 * challenge makes the browser open its native credential dialog and withhold
 * the response until it is dismissed, which bypasses the Desktop's own
 * session-expired handling (#324, measured).
 *
 * @param session Current session context
 * @param status HTTP status code about to be sent
 * @return 0 on success, negative value on error
 */
int send_auth_challenge(Session *session, int status) asm("CMN0017");

/**
 * @brief Hands back the session cookie to a Basic-authenticated caller
 *
 * Implicit login (#324 C1): the reference z/OSMF establishes its session on any
 * Basic-authenticated request, not only at its login endpoint, and does not
 * re-issue it to a caller already presenting the cookie. No-op unless the
 * request carried an Authorization header and httpd resolved a token.
 *
 * @param session Current session context
 * @return 0 on success (including the no-op), negative value on error
 */
int send_session_cookie(Session *session) asm("CMN0018");

/**
 * @brief Sends the headers every mvsMF response carries
 *
 * Cache-Control, Pragma, X-Content-Type-Options and Content-Language, written
 * once for all fourteen response sites (#324). Framing stays with the caller:
 * Content-Type, Content-Length and Transfer-Encoding depend on the status, and
 * a 204 or 304 must carry none of them.
 *
 * @param session Current session context
 * @return 0 on success, negative value on error
 */
int send_common_headers(Session *session) asm("CMN0016");

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
 * @brief Sends a whole buffer to the client, or fails
 *
 * The one raw send in mvsMF -- every streaming handler and every JSON
 * response goes through it. Short writes are resumed and a no-progress
 * return (0, a full socket send buffer) is paused and retried within a
 * bounded budget, so the loop can neither spin at 100% CPU nor silently
 * drop the tail of a record (issue #298).
 *
 * Do not call http_send() directly. A bare loop over it is the httpd#199
 * defect, and a single unchecked call truncates whatever it did not send --
 * today invisible only because those routes happen to be chunked.
 *
 * The buffer must already carry the bytes the client is to receive; no
 * translation happens here.
 *
 * A failure leaves the client at CSTATE_DONE, which stops the handler's
 * remaining output rather than letting each later call wait out its own
 * budget for a peer that is gone, and clears keepalive so the connection is
 * closed instead of reused -- the body is short of the Content-Length it
 * announced, so the next response on that socket would be appended to a
 * truncated one.
 *
 * @param session Current session context
 * @param buf Bytes to send
 * @param len Number of bytes; <= 0 succeeds without sending
 * @return 0 when everything was sent, -1 otherwise
 */
int send_all(Session *session, const UCHAR *buf, int len) asm("CMN0014");

/**
 * @brief Answers a request refused by an authorization check (issue #228)
 *
 * Sends the z/OSMF error report a denial produces -- see
 * CATEGORY_AUTHORIZATION above for the measurement it mirrors.
 *
 * It lives here rather than in dsapi.c because the same body has a second
 * producer: #315 maps the router's S913 ESTAE recovery onto it, so a denial
 * caught by OPEN and one refused by a pre-check answer identically. Two copies
 * would drift, and a client would see two bodies for one condition.
 *
 * @param session The session
 * @param detail  One sentence for the `details[]` array, or NULL for the
 *                default. It must not claim an abend the caller did not take:
 *                the reference always reaches the S913 and says so, a
 *                pre-check that refuses first has not.
 * @return 0 on success, negative on send failure
 */
int send_not_authorized(Session *session, const char *detail) asm("CMN0015");

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

/**
 * @brief Reads exactly @p len bytes, waiting out an empty receive buffer
 *
 * httpd sets every accepted socket non-blocking, so a recv() that finds
 * the buffer empty returns -1/EWOULDBLOCK at once -- "the client has not
 * sent it yet", not an error. Reads one byte at a time (MVS 3.8j TCP/IP
 * ring buffer bug); see the note above receive_raw_data() in common.c.
 *
 * @param httpc Client connection
 * @param buf Destination buffer
 * @param len Number of bytes to read
 * @return Bytes read -- short only on peer close -- or -1 on error/timeout
 */
int receive_raw_data(HTTPC *httpc, char *buf, int len) asm("CMN0021");

/**
 * @brief Reads up to @p len bytes, waiting out an empty receive buffer
 *
 * The bulk counterpart of receive_raw_data(): one recv() of up to @p len
 * bytes, retried on EWOULDBLOCK against the same budget. Used where the
 * caller already tolerates a short read and wants the larger granularity.
 *
 * @param httpc Client connection
 * @param buf Destination buffer
 * @param len Maximum number of bytes to read
 * @return Bytes read (>0), 0 on orderly close, -1 on error/timeout
 */
int receive_raw_some(HTTPC *httpc, char *buf, int len) asm("CMN0022");

#endif // COMMON_H
