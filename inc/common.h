#ifndef COMMON_H
#define COMMON_H

#include "json.h"
#include "router.h"
#include <stddef.h>

#define ENV_NAME_SIZE 256

// HTTP Status Codes
#define HTTP_STATUS_OK 200          // Success
#define HTTP_STATUS_CREATED 201     // Resource created
#define HTTP_STATUS_ACCEPTED 202    // Request accepted, processing not complete
#define HTTP_STATUS_BAD_REQUEST 400 // Incorrect parameters
#define HTTP_STATUS_FORBIDDEN 403   // Forbidden
#define HTTP_STATUS_NOT_FOUND 404   // Resource not found
#define HTTP_STATUS_INTERNAL_SERVER_ERROR 500 // Programming error

// HTTP Status Messages
#define HTTP_MSG_OK "OK"
#define HTTP_MSG_CREATED "Created"
#define HTTP_MSG_ACCEPTED "Accepted"
#define HTTP_MSG_BAD_REQUEST "Bad Request"
#define HTTP_MSG_INTERNAL_SERVER_ERROR "Internal Server Error"

// Content Types
#define HTTP_CONTENT_TYPE_NONE "n/a"
#define HTTP_CONTENT_TYPE_JSON "application/json"

// Return codes
#define RC_SUCCESS 	 0 // Success condition
#define RC_WARNING 	 4 // Warning condition
#define RC_ERROR 	 8   // Error condition
#define RC_AUTH 	12   // Authorization error
#define RC_SEVERE 	16 // Severe error

//
// Request handling
//

/**
 * Gets a query parameter from the request URL
 *
 * @param session Current session context
 * @param name Name of the query parameter
 * @return Value of the parameter or NULL if not found
 */
char *getQueryParam(Session *session, const char *name) 		asm("CMN0001");

/**
 * Gets a path parameter from HTTP headers
 *
 * @param session Current session context
 * @param name Name of the path parameter (e.g. "job-name")
 * @return Value of the parameter or NULL if not found
 */
char *getPathParam(Session *session, const char *param_name) 	asm("CMN0002");

/**
 * Gets a header parameter from HTTP request
 *
 * @param session Current session context
 * @param name Name of the header parameter
 * @return Value of the parameter or NULL if not found
 */
char *getHeaderParam(Session *session, const char *name) 		asm("CMN0003");


//
// Response handling
//

/**
 * Sends default HTTP headers for a response
 *
 * @param session Current session context
 * @param status HTTP status code
 * @param content_type Content type of response
 * @return 0 on success, negative value on error
 */
int sendDefaultHeaders(Session *session, int status, const char *content_type,
                       size_t content_length) asm("CMN0010");

/**
 * Sends a JSON response with given status code
 *
 * @param session Current session context
 * @param status HTTP status code to send
 * @param builder JsonBuilder containing the response data
 * @return 0 on success, negative value on error
 */
int sendJSONResponse(Session *session, int status,
                     JsonBuilder *builder) asm("CMN0011");

/**
 * Sends an error response with details
 *
 * @param session Current session context
 * @param status HTTP status code
 * @param category Error category
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
