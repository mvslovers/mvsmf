#ifndef RECLINES_H
#define RECLINES_H

#include <stddef.h>

/**
 * @file reclines.h
 * @brief Byte stream to fixed-length records: the framing used by the text
 *        write paths in dsapi.c.
 *
 * A text upload arrives as a stream of ASCII bytes and has to become data set
 * records. Both PUT handlers (sequential and PDS member) do that twice each --
 * once for Content-Length, once for chunked -- which is why the same off-by-one
 * had to be fixed in four places and was then wrong in four places again
 * (issues #198, #233). The state machine lives here so there is one copy of it,
 * and so test/host/tstrecl.c can exercise the real code on the host.
 *
 * The rules it implements:
 *
 *   - The terminator is never stored. `content_max` therefore counts payload
 *     only, and a line of exactly LRECL characters fits.
 *   - LF, CR and CRLF all end a record; the LF of a CRLF pair is swallowed
 *     through the normal byte loop, so the caller never has to read ahead
 *     (and never consumes a byte it did not count).
 *   - A blank line is a record, not a no-op: it is emitted as a single blank.
 *     libc370 pads a short record out to LRECL with blanks, but a zero-length
 *     fwrite() leaves its buffer empty and fflush() then returns at its
 *     empty-buffer guard -- the record would silently disappear (#233).
 *   - State survives a chunk boundary, including one that falls between the
 *     CR and the LF of a CRLF pair, so a line split across two chunks stays
 *     one record.
 *
 * The bytes are ASCII here: this runs before the ASCII->EBCDIC translation in
 * write_record(), so the terminators and the blank are ASCII values, not the
 * compiler's (EBCDIC) character literals.
 */

/* Result of recline_put(). */
#define RECLINE_MORE		0	/* byte consumed, record not complete yet */
#define RECLINE_RECORD		1	/* record complete, returned in rec/rec_len */
#define RECLINE_TOOLONG		2	/* content would exceed content_max         */

typedef struct {
	char	*buf;			/* caller's buffer, at least content_max bytes  */
	size_t	 len;			/* content bytes currently held in buf          */
	size_t	 content_max;	/* usable content bytes per record, must be > 0 */
	int	 pending_lf;		/* last byte was CR: a following LF belongs to it */
} RECLINE;

/**
 * Start framing into `buf`, which must hold at least `content_max` bytes.
 * `content_max` is the record's usable content length -- LRECL for RECFM=F,
 * LRECL-4 for RECFM=V (the RDW is not content), BLKSIZE for RECFM=U -- and
 * must be greater than zero.
 */
void recline_init(RECLINE *rl, char *buf, size_t content_max)	asm("MFRECINI");

/**
 * Feed one ASCII byte.
 *
 * Returns RECLINE_RECORD when the byte completed a record; *rec and *rec_len
 * then describe it, and remain valid until the next recline_put(). The caller
 * must write that record out before feeding the next byte -- the buffer is
 * reused, and write_record() translates it in place.
 *
 * Returns RECLINE_TOOLONG when the byte would be content number
 * content_max + 1. Nothing is stored and the stream cannot be continued; the
 * caller is expected to fail the request.
 *
 * Returns RECLINE_MORE otherwise; *rec and *rec_len are not touched.
 */
int recline_put(RECLINE *rl, char c, char **rec, size_t *rec_len)
														asm("MFRECPUT");

/**
 * Take the trailing record of a body that did not end in a terminator.
 *
 * Returns 1 with *rec/*rec_len set when content is pending, 0 when there is
 * none -- a body ending in a newline must not produce a phantom blank record.
 */
int recline_flush(RECLINE *rl, char **rec, size_t *rec_len)	asm("MFRECFLS");

#endif /* RECLINES_H */
