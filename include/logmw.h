#ifndef LOGMW_H
#define LOGMW_H

/**
 * @file logmw.h
 * @brief Logging middleware for MVS 3.8j HTTP requests
 *
 * Provides request logging functionality for HTTP requests.
 * Logs request details including method, path, status code and timing.
 */

#include "router.h"

/**
 * @brief Logs HTTP request details
 *
 * Records information about incoming HTTP requests including:
 * - Request method and path
 * - Client information
 * - Response status code
 * - Request processing time
 *
 * @param session Current session context
 * @return 0 to continue middleware chain, negative value on error
 */
int logging_middleware(Session *session) asm("LOGMW00");

#endif // LOGMW_H
