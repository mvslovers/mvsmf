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

/** @brief HTTP status codes */
#define HTTP_STATUS_OK 200                    /**< Success */
#define HTTP_STATUS_CREATED 201               /**< Resource created */
#define HTTP_STATUS_ACCEPTED 202              /**< Request accepted */
#define HTTP_STATUS_BAD_REQUEST 400           /**< Invalid parameters */
#define HTTP_STATUS_UNAUTHORIZED 401          /**< Unauthorized */
#define HTTP_STATUS_FORBIDDEN 403             /**< Forbidden */
#define HTTP_STATUS_NOT_FOUND 404             /**< Resource not found */
#define HTTP_STATUS_INTERNAL_SERVER_ERROR 500 /**< Server error */

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

#endif // COMMON_H
