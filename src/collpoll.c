#include <stdlib.h>

#include "collpoll.h"

/*
 * The collect poll in its own translation unit, so test/host/tstcolpl.c can
 * drive the real function. See collpoll.h for why a poll that cannot be made
 * has to stay distinct from an empty block.
 */

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'collect_poll'");
#endif
int collect_poll(Session *session, collect_corr_fn corr, const char *cmd_upper,
                 int echo_secs, size_t cap, unsigned *delivered, char **resp)
{
	unsigned total = 0;
	char *buf;
	int r;

	buf = malloc(cap);
	if (!buf) return COLLECT_POLL_FAILED;
	buf[0] = '\0';

	r = corr(session, cmd_upper, buf, cap, *delivered, &total, echo_secs,
	         (int *)0);
	if (r == MTT_SNAP_FAILED) {
		free(buf);
		return COLLECT_POLL_FAILED;
	}

	/* The count only moves forward: a block shorter than what was already
	 * delivered is not ours to count against (#214). */
	if (total > *delivered) *delivered = total;

	*resp = buf;
	return 0;
}
