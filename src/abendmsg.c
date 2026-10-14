#include <stdio.h>
#include <stddef.h>

#include "abendmsg.h"

/*
 * The client-visible message for a handler abend. See abendmsg.h for why the
 * abend code belongs in the response, and issue #256 for what its absence cost.
 */

#define ABEND_B37	0xB37
#define ABEND_D37	0xD37
#define ABEND_E37	0xE37

/* Insufficient authority to open. The one abend code that is an authorization
 * decision rather than a failure. */
#define ABEND_913	0x913

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'abend_message'");
#endif
void
abend_message(char *buf, size_t size, unsigned sys, unsigned usr)
{
	const char *detail = NULL;

	switch (sys) {
		case ABEND_B37:	detail = "out of space on the volume";			break;
		case ABEND_D37:	detail = "primary extent full, no secondary allocation";	break;
		case ABEND_E37:	detail = "extent limit reached";			break;
		default:	break;
	}

	if (sys == 0) {
		/* a user abend carries no system code -- U0100, not S000 */
		snprintf(buf, size, "Internal server error (abend U%04d)", usr);
	} else if (detail) {
		snprintf(buf, size, "Internal server error (abend S%03X: %s)",
			 sys, detail);
	} else {
		snprintf(buf, size, "Internal server error (abend S%03X)", sys);
	}
}

/*
 * Whether an abend is a denial, and what to say about it. See abendmsg.h.
 */
#ifdef __MVS__
__asm__("\n&FUNC	SETC 'abend_denial_detail'");
#endif
const char *
abend_denial_detail(unsigned sys)
{
	if (sys != ABEND_913) {
		return NULL;
	}

	return "Authorization failed - You may not use this protected data set."
	       " Open 913 abend.";
}

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'abend_instr_addr'");
#endif
unsigned
abend_instr_addr(const unsigned psw[2])
{
	unsigned addr = psw[1] & 0x00FFFFFF;
	unsigned ilc  = (psw[1] >> 30) & 3;

	return (addr - ilc * 2) & 0x00FFFFFF;
}

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'abend_ep_offset'");
#endif
long
abend_ep_offset(unsigned addr, unsigned ep)
{
	return (long) (addr & 0x00FFFFFF) - (long) (ep & 0x00FFFFFF);
}
