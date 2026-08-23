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
 * See docs/endpoints/console/ (issue-command, collect, detections, hardcopy-log).
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

/**
 * @brief Get messages from the hardcopy log.
 *
 * GET /zosmf/restconsoles/v1/log[?timeRange=&time=&timestamp=&hardcopy=&sysName=&direction=]
 * Returns { timezone, totalItems, nextTimestamp, source, items[] } drawn from
 * the Master Trace Table (3.8j has no OPERLOG and the active SYSLOG on spool
 * is not browsable). Coverage is the MTT window (recent), not a deep archive.
 *
 * @param session Current session context
 * @return 0 on success, negative value on error
 */
int consoleLogHandler(Session *session) asm("CAPI0004");

/**
 * @brief Take the console correlation lock (#214).
 *
 * One mvsMF command block may be open in the Master Trace Table at a time.
 * Every caller of SVC 34 in this address space must bracket itself with these,
 * or it writes an echo into somebody else's open block -- which includes
 * /zosmf/test?fn=cmd, not just the console API.
 *
 * Returns 0 when the caller may issue (also when no per-CGI context exists, in
 * which case the request proceeds UNSERIALIZED), -1 when the acquire budget is
 * exhausted and the caller should answer 429.
 *
 * @param session Current session context
 * @return 0 to proceed, -1 if busy
 */
int console_lock_acquire(Session *session) asm("CLKACQ");

/**
 * @brief Release the console correlation lock if this session holds it.
 *
 * Idempotent. The router's ESTAE releases it too (session_cleanup), because it
 * recovers the worker rather than ending its task -- so an ENQ held across an
 * abend outlives the request.
 *
 * @param session Current session context
 */
void console_lock_release(Session *session) asm("CLKREL");

#endif // CONSAPI_H
