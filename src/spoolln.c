#include "spoolln.h"

/*
 * The per-record decision of the spool walk, in its own translation unit so
 * test/host/tstspln.c can drive the real function -- jobsapi.c itself cannot
 * compile on the host. Same arrangement as jclines.c/tstjcln.c.
 *
 * See spoolln.h for what the two rules are and why the skip must not count.
 */

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'spool_line_action'");
#endif
int
spool_line_action(int jclin, unsigned limit, unsigned count,
                  const char *line, unsigned linelen)
{
	/* The cap first: it is the logical end of the data set, and a record
	   beyond it is not ours to look at at all. */
	if (limit && count >= limit) {
		return SPOOL_LINE_STOP;
	}

	if (!jclin) {
		return SPOOL_LINE_EMIT;
	}

	/* An empty record cannot be a JCL statement either. jesprint() does not
	   hand those out today (esc_print() drops linelen 0), so this is here for
	   the contract rather than for a case that occurs. */
	if (!linelen) {
		return SPOOL_LINE_SKIP;
	}

	/* Character literal, never 0x61: the record is raw EBCDIC here -- the
	   caller translates on the way out -- and on the host this TU compiles
	   against ASCII test data. Both agree as long as nobody spells the
	   code point out. */
	return (line[0] == '/') ? SPOOL_LINE_EMIT : SPOOL_LINE_SKIP;
}
