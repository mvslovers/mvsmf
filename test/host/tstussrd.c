/*
 * tstussrd.c - #423: a USS file GET whose read fails must not end as a
 * complete reply.
 *
 * ussGetHandler streams the file in a ufs_fread() loop after the 200 and the
 * headers are already out. A read that failed part-way ended that loop exactly
 * as the end of the file does, and nothing looked at ufs_ferror() afterwards:
 * the handler returned 0 and httpd closed the chunked body with a clean
 * terminator -- a 200 with a truncated file, indistinguishable from a whole one.
 *
 *   1. A whole file arrives complete, in order, translated when asked to
 *      (the loop's normal job, unchanged by the fix).
 *   2. A file that ends on a block boundary, and an empty one, are not errors.
 *   3. A read that fails after some blocks hands over what it read, then
 *      reports the failure's return code -- the caller can no longer mistake
 *      it for the end of the file.
 *   4. A failure on the very first read is reported too.
 *   5. A send that fails stops the loop and is NOT reported as a read failure.
 *
 * ====================================================================
 * This test drives the REAL loop: src/ussread.c is #included below.
 * ====================================================================
 */
#include <stdio.h>
#include <string.h>

#include <mbtcheck.h>

#include "../../src/ussread.c"

#define BLK    8
#define FILEMAX 64

struct reader {
	unsigned char file[FILEMAX];
	unsigned      size;        /* bytes the file holds */
	unsigned      pos;         /* read cursor */
	unsigned      fail_at;     /* reads fail from this offset on; ~0u = never */
	int           fail_rc;     /* what failed() reports for it */
	int           failed_asked;
	int           send_fail_at;/* the n-th send fails; 0 = never */
	int           sends;
	unsigned char got[FILEMAX];
	unsigned      sent;
};

static unsigned
op_read(void *ctx, void *buf, unsigned len)
{
	struct reader *r = (struct reader *)ctx;
	unsigned n;

	if (r->pos >= r->fail_at) {
		return 0;
	}
	n = r->size - r->pos;
	if (n > len) {
		n = len;
	}
	if (r->pos + n > r->fail_at) {
		n = r->fail_at - r->pos;
	}
	memcpy(buf, &r->file[r->pos], n);
	r->pos += n;
	return n;
}

static int
op_send(void *ctx, const unsigned char *buf, int len)
{
	struct reader *r = (struct reader *)ctx;

	r->sends++;
	if (r->send_fail_at && r->sends >= r->send_fail_at) {
		return -1;
	}
	memcpy(&r->got[r->sent], buf, (unsigned)len);
	r->sent += (unsigned)len;
	return 0;
}

static void
op_xlate(void *ctx, unsigned char *buf, unsigned len)
{
	unsigned i;

	(void)ctx;
	for (i = 0; i < len; i++) {
		buf[i] ^= 0xFF;
	}
}

static int
op_failed(void *ctx)
{
	struct reader *r = (struct reader *)ctx;

	r->failed_asked++;
	return (r->fail_at != ~0u) ? r->fail_rc : 0;
}

static const USS_READ_OPS plain = { op_read, op_send, NULL,     op_failed };
static const USS_READ_OPS xlat  = { op_read, op_send, op_xlate, op_failed };

static void
setup(struct reader *r, unsigned size)
{
	unsigned i;

	memset(r, 0, sizeof(*r));
	r->size = size;
	for (i = 0; i < size; i++) {
		r->file[i] = (unsigned char)(i + 1);
	}
	r->fail_at = ~0u;
	r->fail_rc = 52;           /* UFSD_RC_IO */
}

static int
run(struct reader *r, const USS_READ_OPS *ops, int *read_rc)
{
	unsigned char buf[BLK];

	return uss_stream_file(r, ops, buf, sizeof(buf), read_rc);
}

int
main(void)
{
	struct reader r;
	int rc, read_rc;
	unsigned i;
	int same;

	printf("\n--- #423: a whole file arrives whole ---\n");
	setup(&r, 20);
	rc = run(&r, &plain, &read_rc);
	CHECK_EQ(rc, 0, "a complete read returns 0");
	CHECK_EQ(read_rc, 0, "and reports no read failure");
	CHECK_EQ((int)r.sent, 20, "all 20 bytes were sent");
	CHECK(memcmp(r.got, r.file, 20) == 0, "in order, none dropped or repeated");

	printf("\n--- #423: translation is applied to what is sent ---\n");
	setup(&r, 20);
	rc = run(&r, &xlat, &read_rc);
	same = (rc == 0);
	for (i = 0; i < 20; i++) {
		if (r.got[i] != (unsigned char)(r.file[i] ^ 0xFF)) {
			same = 0;
		}
	}
	CHECK(same, "every sent byte went through xlate");

	printf("\n--- #423: the end of the file is not an error ---\n");
	setup(&r, 2 * BLK);
	rc = run(&r, &plain, &read_rc);
	CHECK_EQ(rc, 0, "a file of exactly two blocks returns 0");
	CHECK_EQ(read_rc, 0, "no read failure");
	CHECK_EQ((int)r.sent, 2 * BLK, "both blocks were sent");

	setup(&r, 0);
	rc = run(&r, &plain, &read_rc);
	CHECK_EQ(rc, 0, "an empty file returns 0");
	CHECK_EQ(read_rc, 0, "no read failure");
	CHECK_EQ((int)r.sent, 0, "nothing was sent");

	printf("\n--- #423: a read that fails part-way is reported ---\n");
	setup(&r, 4 * BLK);
	r.fail_at = 2 * BLK;
	rc = run(&r, &plain, &read_rc);
	CHECK_EQ((int)r.sent, 2 * BLK, "the two blocks read before the failure were sent");
	CHECK_EQ(read_rc, 52, "the UFSD return code of the failed read is handed back");
	CHECK_EQ(rc, -1, "the transfer is reported as not complete");

	printf("\n--- #423: a read that fails at once is reported ---\n");
	setup(&r, 3 * BLK);
	r.fail_at = 0;
	rc = run(&r, &plain, &read_rc);
	CHECK_EQ((int)r.sent, 0, "nothing was sent");
	CHECK_EQ(read_rc, 52, "the failure is reported");
	CHECK_EQ(rc, -1, "the transfer is reported as not complete");

	printf("\n--- #423: a failed send is not a read failure ---\n");
	setup(&r, 4 * BLK);
	r.send_fail_at = 2;
	rc = run(&r, &plain, &read_rc);
	CHECK_EQ(rc, -1, "a send that fails stops the transfer");
	CHECK_EQ(read_rc, 0, "and is not blamed on the read");
	CHECK_EQ(r.sends, 2, "no send is attempted after the failed one");
	CHECK_EQ(r.failed_asked, 0, "the file's error state is not consulted");

	return mbt_test_summary("TSTUSSRD");
}
