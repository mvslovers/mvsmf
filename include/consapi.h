#ifndef CONSAPI_H
#define CONSAPI_H

/**
 * @file consapi.h
 * @brief z/OSMF Console services REST API for MVS 3.8j
 *
 * Implements the /zosmf/restconsoles endpoints. Commands are issued with
 * SVC 34 (MGCR) under the authenticated user's ACEE; responses are captured
 * from the Master Trace Table via libc370 clibmtt.
 *
 * See doc/endpoints/restconsoles-issue-command.md.
 */

#include "router.h"

/**
 * @brief Issue an MVS operator command.
 *
 * PUT /zosmf/restconsoles/consoles/{console-name}
 * Body: { "cmd": "...", "async": "Y|N", "system": "...", "sol-key": "..." }
 *
 * @param session Current session context
 * @return 0 on success, negative value on error
 */
int consoleIssueHandler(Session *session) asm("CAPI0001");

#endif // CONSAPI_H
