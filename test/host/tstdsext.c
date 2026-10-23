/*
 * tstdsext.c - #370 regression: the allocated size of a data set with more
 * than three extents.
 *
 * The listing summed the three extents of the format-1 DSCB and stopped.
 * Extents 4-16 are in the format-3 DSCB behind DS1PTRDS, so sizex came out
 * short and used (tracks used * 100 / sizex) too high -- over 100 on a full
 * data set. Measured on SYS2.LINKLIB (3350, 30 tracks per cylinder), IEHLIST
 * LISTVTOC: six extents, cylinders 58-77 (600 tracks) and 186, 187, 188, 189,
 * 190 (30 tracks each) = 750 tracks; mvsMF reported 660 = 600 + 30 + 30.
 *
 * This test drives the REAL function: src/dsextent.c is #included below. The
 * DSCBs are built byte for byte; the reader stands in for OBTAIN.
 *
 * Runs on host via `mbt test`.
 */
#include <stdio.h>
#include <string.h>

#include <mbtcheck.h>

#include "../../src/dsextent.c"

#define TPC3350	30u
#define TPC3380	15u

/* One extent, lower and upper CCHH. */
static void
put_ext(unsigned char *p, unsigned lc, unsigned lh, unsigned hc, unsigned hh)
{
	p[0] = 0x01;
	p[1] = 0;
	p[2] = (unsigned char)(lc >> 8); p[3] = (unsigned char)lc;
	p[4] = (unsigned char)(lh >> 8); p[5] = (unsigned char)lh;
	p[6] = (unsigned char)(hc >> 8); p[7] = (unsigned char)hc;
	p[8] = (unsigned char)(hh >> 8); p[9] = (unsigned char)hh;
}

/* A whole cylinder range, on a volume of tpc tracks per cylinder. */
static void
put_cyls(unsigned char *p, unsigned lc, unsigned hc, unsigned tpc)
{
	put_ext(p, lc, 0, hc, tpc - 1);
}

/* The chain the reader serves. Pointers are one byte of identity, 0 = end. */
#define MAXF3	6

typedef struct chain {
	unsigned char	area[MAXF3][DSX_F3_LEN];
	unsigned char	at[MAXF3];	/* the CCHHR byte that names area[i] */
	unsigned	n;
	unsigned	reads;
	int		fail;		/* reader return code, 0 = serve */
	unsigned char	last;		/* last pointer asked for */
} CHAIN;

static void
f3_init(unsigned char *a, unsigned char next)
{
	memset(a, 0, DSX_F3_LEN);
	memset(a, 0x03, 4);
	a[DSX_F3_FMTID_OFF] = DSX_F3_FMTID;
	a[DSX_F3_PTR_OFF + 4] = next;
}

static int
reader(const unsigned char cchhr[DSX_PTR_LEN], unsigned char area[DSX_F3_LEN],
       void *ctx)
{
	CHAIN *c = ctx;
	unsigned i;

	c->reads++;
	c->last = cchhr[4];
	if (c->fail) return c->fail;
	for (i = 0; i < c->n; i++) {
		if (c->at[i] == cchhr[4]) {
			memcpy(area, c->area[i], DSX_F3_LEN);
			return 0;
		}
	}
	return 12;
}

static const unsigned char noptr[DSX_PTR_LEN] = {0, 0, 0, 0, 0};
static const unsigned char ptr_a[DSX_PTR_LEN] = {0, 0, 0, 1, 0x0A};

static char msg[120];

static void
expect(int rc, int want_rc, unsigned got, unsigned want_trks, const char *what)
{
	snprintf(msg, sizeof(msg), "%s: rc %d", what, want_rc);
	CHECK_EQ(rc, want_rc, msg);
	if (want_rc == DSX_OK) {
		snprintf(msg, sizeof(msg), "%s: %u tracks", what, want_trks);
		CHECK_EQ(got, want_trks, msg);
	}
}

int
main(void)
{
	unsigned char f1[DSX_F1_EXTENTS * DSX_EXTENT_LEN];
	CHAIN c;
	unsigned trks;
	int rc;

	/* up to three extents the format-1 DSCB is all there is, and the reader
	   is never asked */
	memset(f1, 0, sizeof(f1));
	memset(&c, 0, sizeof(c));
	put_cyls(f1, 58, 77, TPC3350);
	put_cyls(f1 + 10, 186, 186, TPC3350);
	trks = 7777;
	rc = dscb_alloc_tracks(f1, noptr, 2, TPC3350, reader, &c, &trks);
	expect(rc, DSX_OK, trks, 630, "2 extents");
	CHECK_EQ(c.reads, 0u, "2 extents: no DSCB read");

	put_cyls(f1 + 20, 187, 187, TPC3350);
	rc = dscb_alloc_tracks(f1, noptr, 3, TPC3350, reader, &c, &trks);
	expect(rc, DSX_OK, trks, 660, "3 extents");
	CHECK_EQ(c.reads, 0u, "3 extents: no DSCB read");

	/* SYS2.LINKLIB: six extents; the format-1 DSCB has 600 + 30 + 30, the
	   other three are in the format-3 DSCB */
	memset(&c, 0, sizeof(c));
	f3_init(c.area[0], 0);
	c.at[0] = 0x0A;
	c.n = 1;
	put_cyls(c.area[0] + DSX_F3_EXT4_OFF, 188, 188, TPC3350);
	put_cyls(c.area[0] + DSX_F3_EXT4_OFF + 10, 189, 189, TPC3350);
	put_cyls(c.area[0] + DSX_F3_EXT4_OFF + 20, 190, 190, TPC3350);
	trks = 0;
	rc = dscb_alloc_tracks(f1, ptr_a, 6, TPC3350, reader, &c, &trks);
	expect(rc, DSX_OK, trks, 750, "SYS2.LINKLIB, 6 extents");
	CHECK_EQ(c.reads, 1u, "6 extents: one format-3 DSCB read");
	CHECK_EQ(c.last, 0x0Au, "6 extents: the reader got DS1PTRDS");

	/* the fourth extent only: the first four-extent group of the format-3 */
	memset(&c, 0, sizeof(c));
	f3_init(c.area[0], 0);
	c.at[0] = 0x0A;
	c.n = 1;
	put_cyls(c.area[0] + DSX_F3_EXT4_OFF, 188, 188, TPC3350);
	put_cyls(c.area[0] + DSX_F3_EXT4_OFF + 10, 189, 189, TPC3350);
	rc = dscb_alloc_tracks(f1, ptr_a, 4, TPC3350, reader, &c, &trks);
	expect(rc, DSX_OK, trks, 690, "4 extents");

	/* extents beyond the thirteenth hold what the 8th to 16th are: past the
	   four-extent group the nine-extent group is read */
	memset(&c, 0, sizeof(c));
	f3_init(c.area[0], 0);
	c.at[0] = 0x0A;
	c.n = 1;
	{
		unsigned i;
		for (i = 0; i < DSX_F3_EXT4_CNT; i++)
			put_cyls(c.area[0] + DSX_F3_EXT4_OFF + i * 10,
				 200 + i, 200 + i, TPC3350);
		for (i = 0; i < DSX_F3_EXT9_CNT; i++)
			put_cyls(c.area[0] + DSX_F3_EXT9_OFF + i * 10,
				 300 + i, 300 + i, TPC3350);
	}
	rc = dscb_alloc_tracks(f1, ptr_a, 16, TPC3350, reader, &c, &trks);
	expect(rc, DSX_OK, trks, 660 + 13 * 30, "16 extents (the most there are)");
	rc = dscb_alloc_tracks(f1, ptr_a, 8, TPC3350, reader, &c, &trks);
	expect(rc, DSX_OK, trks, 660 + 5 * 30, "8 extents stops inside the nine-extent group");

	/* the extent arithmetic is per volume: a 3380 has 15 tracks a cylinder,
	   and an extent need not start or end on a cylinder boundary */
	memset(f1, 0, sizeof(f1));
	put_cyls(f1, 10, 19, TPC3380);
	put_ext(f1 + 10, 40, 3, 41, 2);
	trks = 0;
	rc = dscb_alloc_tracks(f1, noptr, 2, TPC3380, reader, &c, &trks);
	expect(rc, DSX_OK, trks, 150 + 15, "3380 extents, one off a cylinder boundary");

	/* a chain that cannot be read is an error and not a smaller number */
	memset(f1, 0, sizeof(f1));
	put_cyls(f1, 58, 77, TPC3350);
	put_cyls(f1 + 10, 186, 186, TPC3350);
	put_cyls(f1 + 20, 187, 187, TPC3350);
	memset(&c, 0, sizeof(c));
	c.fail = 12;
	trks = 4242;
	rc = dscb_alloc_tracks(f1, ptr_a, 6, TPC3350, reader, &c, &trks);
	expect(rc, DSX_ERR_READ, trks, 0, "format-3 DSCB cannot be read");
	CHECK_EQ(trks, 4242u, "read error: result untouched");

	memset(&c, 0, sizeof(c));
	rc = dscb_alloc_tracks(f1, noptr, 6, TPC3350, reader, &c, &trks);
	expect(rc, DSX_ERR_CHAIN, trks, 0, "NOEPV 6 and no pointer");
	CHECK_EQ(c.reads, 0u, "no pointer: the reader is not asked");
	CHECK_EQ(trks, 4242u, "no pointer: result untouched");

	/* the chain ends before NOEPV is met */
	memset(&c, 0, sizeof(c));
	f3_init(c.area[0], 0);
	c.at[0] = 0x0A;
	c.n = 1;
	put_cyls(c.area[0] + DSX_F3_EXT4_OFF, 188, 188, TPC3350);
	rc = dscb_alloc_tracks(f1, ptr_a, 20, TPC3350, reader, &c, &trks);
	expect(rc, DSX_ERR_CHAIN, trks, 0, "NOEPV 20 and the chain ends");

	/* DS1PTRDS pointing at something that is not a format-3 DSCB */
	memset(&c, 0, sizeof(c));
	f3_init(c.area[0], 0);
	c.area[0][DSX_F3_FMTID_OFF] = 0xF2;
	c.at[0] = 0x0A;
	c.n = 1;
	rc = dscb_alloc_tracks(f1, ptr_a, 6, TPC3350, reader, &c, &trks);
	expect(rc, DSX_ERR_FORMAT, trks, 0, "a format-2 DSCB behind DS1PTRDS");
	CHECK_EQ(trks, 4242u, "format error: result untouched");

	/* a chain that points back at itself ends */
	memset(&c, 0, sizeof(c));
	f3_init(c.area[0], 0x0A);
	c.at[0] = 0x0A;
	c.n = 1;
	rc = dscb_alloc_tracks(f1, ptr_a, 200, TPC3350, reader, &c, &trks);
	expect(rc, DSX_ERR_CHAIN, trks, 0, "a loop in the chain ends");
	CHECK_EQ(c.reads <= DSX_MAX_F3, 1, "a loop in the chain: bounded reads");

	return mbt_test_summary("TSTDSEXT");
}
