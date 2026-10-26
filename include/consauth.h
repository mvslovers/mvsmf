#ifndef CONSAUTH_H
#define CONSAUTH_H

/**
 * @file consauth.h
 * @brief Authorization check of the console service and /zosmf/test (#460)
 *
 * authdec.h decides; this file asks.  A request is served only when RACF
 * answers rc 0 for READ on FACILITY MVSMF.CONSOLE under the request's own
 * ACEE.  No ACEE, no profile and no READ are all refused.  See
 * internals/authorization.md.
 */

#include "router.h"

/** @brief Detail of the refusal (`details[]` of the error report) */
#define ERR_MSG_CONSOLE_DENIED \
	"Authorization failed - You may not use this service."

/**
 * @brief Check that the caller may use the console service or /zosmf/test.
 *
 * Call it as the first statement of a handler, before any output.
 *
 * @param session Current session context
 * @return 0 when permitted.  -1 when refused: the response has been sent and
 *         the handler must return -1 without touching anything.
 */
int console_authorize(Session *session) asm("CNSAUTHZ");

#endif /* CONSAUTH_H */
