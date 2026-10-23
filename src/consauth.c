/* CONSAUTH.C
** RACF glue for the console and test endpoint gate (#460), see
** include/consauth.h.
**
** authdec.c holds the decision and builds on the host; this file is the part
** that needs MVS: the ACEE httpd resolved for the request and racf_auth().
*/
#include <string.h>

#include <mvs/racf.h>

#include "authdec.h"
#include "common.h"
#include "consauth.h"
#include "httpcgi.h"

/* racf_auth() returns SAF's own code: 0 permitted, 4 no profile, 8 denied.
 * http_check_auth() folds 4 into 0 and would leave the endpoints open on a
 * system that never defined the profile, which is the one answer this gate
 * must not give. */
#ifdef __MVS__
__asm__("\n&FUNC	SETC 'consauth_racf'");
#endif
static int
consauth_racf(void *arg)
{
	return racf_auth((ACEE *)arg, "FACILITY", "MVSMF.CONSOLE",
			RACF_ATTR_READ);
}

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'console_authorize'");
#endif
int
console_authorize(Session *session)
{
	ACEE *acee = NULL;
	int verdict;

	if (session && session->httpc)
		acee = http_get_acee(session->httpc);

	verdict = authdec_gate(acee != NULL, consauth_racf, acee);
	if (verdict == AUTHDEC_ALLOW)
		return 0;

	/* No WTO: the client caused this, and consapi.c reads the Master Trace
	 * Table, so a console line would come back out of the console API. */
	if (verdict == AUTHDEC_NOACEE) {
		sendErrorResponse(session, HTTP_STATUS_UNAUTHORIZED,
			CATEGORY_AUTHORIZATION, RC_ERROR, REASON_NOT_AUTHORIZED,
			ERR_MSG_NOT_AUTHORIZED, NULL, 0);
	} else {
		send_not_authorized(session, ERR_MSG_CONSOLE_DENIED);
	}

	/* -1, NOT the send's return code: both senders answer 0 for a refusal
	 * that went out fine, which would read as "permitted". */
	return -1;
}
