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

/**
 * @brief Collect (poll) the response of a previously issued command.
 *
 * GET /zosmf/restconsoles/consoles/{console-name}/solmsgs/{cmd-response-key}
 * Returns the response lines new since the previous poll; an empty response
 * signals "done". Unknown / evicted keys also return empty.
 *
 * @param session Current session context
 * @return 0 on success, negative value on error
 */
int consoleCollectHandler(Session *session) asm("CAPI0002");

/**
 * @brief Get the unsolicited-keyword detection result.
 *
 * GET /zosmf/restconsoles/consoles/{console-name}/detections/{detection-key}
 * Returns { "status": detected|waiting|expired, "msg": "..." }.
 *
 * @param session Current session context
 * @return 0 on success, negative value on error
 */
int consoleDetectHandler(Session *session) asm("CAPI0003");

#endif // CONSAPI_H
