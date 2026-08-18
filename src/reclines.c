#include <stddef.h>

#include "reclines.h"

/*
 * Byte stream to fixed-length records. See reclines.h for the framing rules
 * and why they live in their own translation unit; issues #198 and #233 for
 * what four copies of this cost.
 *
 * ASCII values, deliberately: the payload is still ASCII at this point --
 * write_record() translates it to EBCDIC afterwards -- so the compiler's
 * character literals (EBCDIC under cc370) would be the wrong bytes here.
 */
#define ASCII_LF	0x0A
#define ASCII_CR	0x0D
#define ASCII_BLANK	0x20

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'recline_init'");
#endif
void
recline_init(RECLINE *rl, char *buf, size_t content_max)
{
	rl->buf         = buf;
	rl->len         = 0;
	rl->content_max = content_max;
	rl->pending_lf  = 0;
	rl->truncated   = 0;
}

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'recline_put'");
#endif
int
recline_put(RECLINE *rl, char c, char **rec, size_t *rec_len)
{
	/* The LF of a CRLF pair: the CR already ended the record. Cleared on any
	   byte, so a lone CR followed by content behaves like a terminator too --
	   and the byte is consumed by the caller's normal read loop, which is what
	   keeps the Content-Length accounting straight. */
	if (rl->pending_lf) {
		rl->pending_lf = 0;
		if (c == ASCII_LF) {
			return RECLINE_MORE;
		}
	}

	if (c == ASCII_LF || c == ASCII_CR) {
		if (rl->len == 0) {
			/* A blank line is a real record of blanks. One blank is enough:
			   libc370's fixflush() pads to LRECL, while a zero-length record
			   would never reach the data set at all (#233). */
			rl->buf[0] = ASCII_BLANK;
			rl->len    = 1;
		}

		*rec     = rl->buf;
		*rec_len = rl->len;
		rl->len  = 0;

		if (c == ASCII_CR) {
			rl->pending_lf = 1;
		}
		return RECLINE_RECORD;
	}

	/* The terminator is never stored, so this counts content only: a line of
	   exactly content_max characters fits. Past that the byte is dropped and
	   the record is emitted short of the caller's line -- see reclines.h for
	   why truncating beats failing here. */
	if (rl->len >= rl->content_max) {
		rl->truncated = 1;
		return RECLINE_MORE;
	}

	rl->buf[rl->len++] = c;
	return RECLINE_MORE;
}

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'recline_flush'");
#endif
int
recline_flush(RECLINE *rl, char **rec, size_t *rec_len)
{
	if (rl->len == 0) {
		return 0;	/* body ended on a terminator -- no trailing record */
	}

	*rec     = rl->buf;
	*rec_len = rl->len;
	rl->len  = 0;
	return 1;
}
