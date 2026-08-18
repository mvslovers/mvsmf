/*
 * sendall.c - the send loop and its no-progress policy (issue #298).
 *
 * See include/sendall.h for why this is its own TU and why the loop never
 * advances by the return value without checking it first.
 *
 * Portable C on purpose: no httpd headers, no MVS services, no statics. The
 * host test #includes it (test/host/tstsend.c) so the loop it drives is the
 * one that runs on MVS, not a copy of it.
 */

#include "sendall.h"

#ifdef __MVS__
__asm__("\n&FUNC    SETC 'send_bytes'");
#endif
int
send_bytes(void *ctx, const SEND_OPS *ops, const unsigned char *buf, int len)
{
	int pos = 0;
	int stall = 0;

	if (len <= 0) {
		return 0;
	}

	/* Entry guard, not just a loop guard: once a send has failed, the
	   handler's error path comes straight back here through
	   sendErrorResponse(). Without this it would pay the full stall budget
	   a second time for a client that is already gone (httpd#203). */
	if (ops->aborted(ctx)) {
		return -1;
	}

	while (pos < len) {
		int rc = ops->send(ctx, &buf[pos], len - pos);

		if (rc < 0) {
			return -1;      /* dead socket */
		}

		if (rc > 0) {
			/* Progress resets the budget: a slow but advancing client
			   must not be cut off at attempt 101 just because it took
			   that many turns to drain. */
			pos += rc;
			stall = 0;
			continue;
		}

		/* rc == 0: the receive window is closed. Wait it out -- but only
		   while waiting can still pay off, and only within the budget.
		   Never advance pos here; that is the whole defect. */
		if (ops->aborted(ctx)) {
			return -1;
		}

		if (++stall > SEND_STALL_MAX) {
			ops->giveup(ctx, stall);
			return -1;
		}

		ops->pause(ctx);
	}

	return 0;
}
