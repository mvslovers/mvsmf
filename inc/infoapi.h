#ifndef INFOAPI_H
#define INFOAPI_H

#include "router.h"

/**
 * Handles the z/OSMF information retrieval request
 * Returns system information in JSON format as specified in the z/OSMF REST API
 *
 * @param session Current session context
 * @return RC_SUCCESS on success, RC_ERROR on error
 */
int infoHandler(Session *session) asm("IAPI0000");

#endif // INFOAPI_H
