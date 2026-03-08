#ifndef INFOAPI_H
#define INFOAPI_H

/**
 * @file infoapi.h
 * @brief z/OSMF Information API implementation for MVS 3.8j
 *
 * Implements the z/OSMF Information retrieval service API endpoints.
 * Provides system information and API capabilities in z/OSMF compatible format.
 */

#include "router.h"

/**
 * @brief Retrieves z/OSMF system information
 *
 * Returns system information in JSON format as specified in the z/OSMF REST API.
 * Includes details about the system, API version, and available services.
 *
 * @param session Current session context
 * @return 0 on success, negative value on error
 */
int infoHandler(Session *session) asm("IAPI0000");

#endif // INFOAPI_H
