/*
 * tstrecl.c - #233 regression: framing a text upload into data set records.
 *
 * Two defects on the text write path, both in four copies of the same loop in
 * dsapi.c:
 *
 *   1. A blank line produced a zero-length record. write_record() stripped the
 *      terminator, fwrite() then wrote nothing, and libc370's fflush() returned
 *      at its empty-buffer guard -- the record vanished and the upload still
 *      answered 204.
 *   2. The length guard ran before the byte was stored AND counted the
 *      terminator, so the usable line length was LRECL-2: a line of exactly 80
 *      characters into an FB80 data set was rejected with "Record too long".
 *
 * Fix: the terminator is never buffered, so the limit counts content only, and
 * a terminated empty line is emitted as a single blank (libc370 pads a short
 * record out to LRECL).
 *
 * ====================================================================
 * This test drives the REAL state machine: src/reclines.c is #included
 * below, so a later refactor stays covered. dsapi.c itself cannot compile
 * on the host (MVS intrinsics, HLASM labels, live sockets), which is why
 * the framing lives in its own TU.
 * ====================================================================
 *
 * The input streams are built from ASCII bytes, never from the compiler's
 * '\n': under cc370 that literal is EBCDIC 0x15, while an HTTP body carries
 * 0x0A. Each escape sits in its own string literal so the hex escape cannot
 * swallow the following character. Content bytes are compared against the same
 * literals that produced them, so their encoding does not matter.
 *
 * Runs on host via `make test-host`.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <mbtcheck.h>

#include "../../src/reclines.c"

#define LF	"\x0a"
#define CR	"\x0d"

/* ---- harness --------------------------------------------------------------
 * Feeds bytes through the real recline_put() and records every record it
 * hands back, exactly as the dsapi.c loops do. */

#define MAX_RECS	8
#define MAX_RECLEN	100
#define CANARY		0x7E	/* guards the bytes past content_max */

static char	g_buf[MAX_RECLEN + 8];
static char	g_rec[MAX_RECS][MAX_RECLEN];
static size_t	g_reclen[MAX_RECS];
static int	g_nrec;
static int	g_toolong;

static RECLINE	g_rl;

static void feed_start(size_t content_max)
{
	memset(g_buf, CANARY, sizeof(g_buf));
	memset(g_rec, 0, sizeof(g_rec));
	memset(g_reclen, 0, sizeof(g_reclen));
	g_nrec    = 0;
	g_toolong = 0;
	recline_init(&g_rl, g_buf, content_max);
}

/* One chunk of the body. Call repeatedly on the same stream to model a chunk
 * boundary -- the RECLINE keeps its state across calls, as it does in the
 * handlers. */
static void feed(const char *bytes, size_t n)
{
	char   *rec;
	size_t  rec_len;
	size_t  i;
	int     act;

	for (i = 0; i < n; i++) {
		act = recline_put(&g_rl, bytes[i], &rec, &rec_len);
		/* No early exit: an over-long line no longer stops the stream, it
		   loses its overflow and framing continues -- which is the whole
		   point of #243. The handlers read rl.truncated after the body. */
		if (act == RECLINE_RECORD && g_nrec < MAX_RECS) {
			memcpy(g_rec[g_nrec], rec, rec_len);
			g_reclen[g_nrec] = rec_len;
			g_nrec++;
		}
	}
	g_toolong = g_rl.truncated;
}

/* The end of the body: a trailing record only if content is pending. */
static int feed_end(void)
{
	char   *rec;
	size_t  rec_len;

	if (!recline_flush(&g_rl, &rec, &rec_len)) {
		return 0;
	}
	if (g_nrec < MAX_RECS) {
		memcpy(g_rec[g_nrec], rec, rec_len);
		g_reclen[g_nrec] = rec_len;
		g_nrec++;
	}
	return 1;
}

/* Record n equals the given bytes. */
static int rec_is(int n, const char *want, size_t want_len)
{
	if (n >= g_nrec) {
		return 0;
	}
	return g_reclen[n] == want_len && memcmp(g_rec[n], want, want_len) == 0;
}

/* Nothing was written past the usable content length. */
static int canary_intact(size_t content_max)
{
	size_t i;

	for (i = content_max; i < sizeof(g_buf); i++) {
		if (g_buf[i] != (char)CANARY) {
			return 0;
		}
	}
	return 1;
}

static char	line80[80];
static char	line81[81];

int main(void)
{
	static const char blank = 0x20;		/* ASCII, as the record carries it */
	char              stream[128];

	printf("=== TSTRECL: #233 text record framing ===\n");

	memset(line80, 'A', sizeof(line80));
	memset(line81, 'A', sizeof(line81));

	/* 1. the reported case: a blank line is a record, not a no-op */
	feed_start(80);
	feed("ERSTE" LF LF "DRITTE" LF, 5 + 1 + 1 + 6 + 1);
	CHECK_EQ(g_nrec, 3, "blank line: three records for three lines");
	CHECK(rec_is(0, "ERSTE", 5), "blank line: first record is the first line");
	CHECK(rec_is(1, &blank, 1), "blank line: second record is one blank");
	CHECK(rec_is(2, "DRITTE", 6), "blank line: third record is the third line");
	CHECK_EQ(feed_end(), 0, "blank line: no trailing record after the last LF");

	/* 2. a line that exactly fills the record must be accepted (the bug) */
	feed_start(80);
	memcpy(stream, line80, 80);
	memcpy(stream + 80, LF, 1);
	feed(stream, 81);
	CHECK_EQ(g_toolong, 0, "LRECL: 80 columns into LRECL=80 accepted");
	CHECK_EQ(g_nrec, 1, "LRECL: one record");
	CHECK(rec_is(0, line80, 80), "LRECL: all 80 columns kept");
	CHECK(canary_intact(80), "LRECL: nothing written past the record length");

	/* 3. one column too many loses the overflow, and the record still lands.
	 *    Measured against real z/OSMF v29 (#243): it truncates to LRECL rather
	 *    than rejecting, and reports the truncation once at the end. */
	feed_start(80);
	memcpy(stream, line81, 81);
	memcpy(stream + 81, LF, 1);
	feed(stream, 82);
	CHECK_EQ(g_toolong, 1, "over-long: 81 columns into LRECL=80 flagged truncated");
	CHECK_EQ(g_nrec, 1, "over-long: the record is still emitted");
	CHECK(rec_is(0, line81, 80), "over-long: emitted at exactly 80 columns");
	CHECK(canary_intact(80), "over-long: nothing written past the record length");

	/* 3b. and the stream survives it -- everything after the over-long line
	 *     is written, which is the half of #243 that actually lost data. The
	 *     shape is the one measured on z/OSMF: 5 / 80 / 6. */
	feed_start(80);
	{
		char   body[256];	/* the measured body is 214 bytes -- stream[] is 128 */
		size_t n = 0;

		memcpy(body + n, "ERSTE", 5);   n += 5;
		memcpy(body + n, LF, 1);        n += 1;
		memset(body + n, 'X', 200);     n += 200;
		memcpy(body + n, LF, 1);        n += 1;
		memcpy(body + n, "DRITTE", 6);  n += 6;
		memcpy(body + n, LF, 1);        n += 1;
		feed(body, n);
	}
	CHECK_EQ(g_toolong, 1, "over-long mid-body: truncation flagged");
	CHECK_EQ(g_nrec, 3, "over-long mid-body: all three records emitted");
	CHECK(rec_is(0, "ERSTE", 5), "over-long mid-body: first record intact");
	CHECK_EQ((int)g_reclen[1], 80, "over-long mid-body: second record cut to 80");
	CHECK(rec_is(2, "DRITTE", 6), "over-long mid-body: the record AFTER it survives");
	CHECK(canary_intact(80), "over-long mid-body: nothing past the record length");

	/* 4. CRLF at exactly the record length -- the CR ends it, the LF is
	 *    swallowed and must not open a blank record */
	feed_start(80);
	memcpy(stream, line80, 80);
	memcpy(stream + 80, CR, 1);
	memcpy(stream + 81, LF, 1);
	feed(stream, 82);
	CHECK_EQ(g_toolong, 0, "CRLF: 80 columns plus CRLF accepted");
	CHECK_EQ(g_nrec, 1, "CRLF: one record, the LF did not start a second");
	CHECK(rec_is(0, line80, 80), "CRLF: all 80 columns kept");

	/* 5. a lone CR ends a record too, and the byte after it is ordinary
	 *    content -- no read-ahead, so the caller's byte count stays exact */
	feed_start(80);
	feed("AB" CR "CD" CR, 2 + 1 + 2 + 1);
	CHECK_EQ(g_nrec, 2, "lone CR: two records");
	CHECK(rec_is(0, "AB", 2), "lone CR: first record");
	CHECK(rec_is(1, "CD", 2), "lone CR: second record");
	CHECK_EQ(feed_end(), 0, "lone CR: nothing pending afterwards");

	/* 6. a body that does not end in a terminator still has a last record */
	feed_start(80);
	feed("ABC", 3);
	CHECK_EQ(g_nrec, 0, "no terminator: nothing written while reading");
	CHECK_EQ(feed_end(), 1, "no terminator: the tail becomes a record");
	CHECK(rec_is(0, "ABC", 3), "no terminator: the tail is the content");

	/* 7. a body ending in a terminator must not gain a phantom blank record */
	feed_start(80);
	feed("ABC" LF, 4);
	CHECK_EQ(g_nrec, 1, "trailing LF: one record");
	CHECK_EQ(feed_end(), 0, "trailing LF: no phantom trailing record");

	/* 8. a chunk boundary in mid-line keeps the line one record */
	feed_start(80);
	feed("AB", 2);
	feed("CD" LF, 3);
	CHECK_EQ(g_nrec, 1, "chunk split: one record across the boundary");
	CHECK(rec_is(0, "ABCD", 4), "chunk split: content joined");

	/* 9. a chunk boundary between the CR and the LF of one pair */
	feed_start(80);
	feed("AB" CR, 3);
	feed(LF "CD" LF, 4);
	CHECK_EQ(g_nrec, 2, "CRLF split: two records, the stray LF swallowed");
	CHECK(rec_is(0, "AB", 2), "CRLF split: first record");
	CHECK(rec_is(1, "CD", 2), "CRLF split: second record");

	/* 10. blank lines with CRLF endings */
	feed_start(80);
	feed(CR LF CR LF, 4);
	CHECK_EQ(g_nrec, 2, "CRLF blanks: two blank records");
	CHECK(rec_is(0, &blank, 1), "CRLF blanks: first is one blank");
	CHECK(rec_is(1, &blank, 1), "CRLF blanks: second is one blank");

	/* 11. the degenerate record length still holds one column, and a blank
	 *     line fits in it */
	feed_start(1);
	feed("A" LF LF "B" LF, 5);
	CHECK_EQ(g_toolong, 0, "LRECL=1: single columns accepted");
	CHECK_EQ(g_nrec, 3, "LRECL=1: three records");
	CHECK(rec_is(1, &blank, 1), "LRECL=1: the blank line still fits");
	CHECK(canary_intact(1), "LRECL=1: nothing written past the record length");

	feed_start(1);
	feed("AB" LF, 3);
	CHECK_EQ(g_toolong, 1, "LRECL=1: two columns flagged truncated");
	CHECK_EQ(g_nrec, 1, "LRECL=1: the record still lands");
	CHECK(rec_is(0, "A", 1), "LRECL=1: cut to the single column");

	/* 12. whatever the caller computes as the usable length is what gets
	 *     enforced -- RECFM=V passes LRECL-4, so the RDW is not spent on
	 *     content and a long line no longer spills into a second record */
	memset(stream, 'V', sizeof(stream));
	feed_start(4);
	feed(stream, 4);
	CHECK_EQ(g_toolong, 0, "content_max=4: four columns accepted");
	feed(stream, 1);
	CHECK_EQ(g_toolong, 1, "content_max=4: the fifth column is dropped");

	return mbt_test_summary("TSTRECL");
}
