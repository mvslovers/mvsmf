#ifndef AUTHMW_H
#define AUTHMW_H

/**
 * @file authmw.h
 * @brief Authentication middleware for MVS 3.8j HTTP requests
 *
 * Provides Basic Authentication functionality using RACF for user validation.
 * Handles credential verification and ACEE management for authenticated sessions.
 */

#include "router.h"

/**
 * @brief Authenticates HTTP requests using Basic Auth
 *
 * Validates the Authorization header for Basic Auth credentials.
 * Decodes credentials and validates them against RACF.
 * Creates and stores ACEE in session upon successful authentication.
 *
 * @param session Current session context
 * @return 0 on success, negative value on error
 *
 * Error cases:
 * - HTTP 401 if Authorization header is missing
 * - HTTP 401 if invalid Authorization type
 * - HTTP 401 if invalid Base64 encoding
 * - HTTP 401 if invalid credential format
 * - HTTP 401 if invalid credentials
 */
int authentication_middleware(Session *session) asm("AUTHMW00");

#endif // AUTHMW_H
