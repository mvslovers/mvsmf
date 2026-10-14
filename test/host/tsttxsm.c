/*
 * tsttxsm.c - #425: the block sums behind /zosmf/test?fn=textsum.
 *
 * fn=textsum is how an overwritten piece of MVSMF's loaded code is to be
 * found before it is executed: a block whose sum changes between two samples
 * at the same load point has been written to. That only works if the sum is
 * the function it claims to be and reacts to every byte, so:
 *
 *   1. Known answers for 32-bit FNV-1a, given as byte values rather than
 *      string literals, so the test means the same in ASCII and EBCDIC.
 *   2. A single changed byte anywhere in a block changes its sum -- first,
 *      middle and last byte of a TEXTSUM_BLOCK.
 *   3. Order matters: two swapped bytes change the sum (an additive checksum
 *      would miss a store that moved code around).
 *   4. The linked instruction from the m38b dump, B 30(0,15) = 47F0F01E,
 *      against the value Python's reference implementation gives.
 *
 * ====================================================================
 * This test drives the REAL function: src/textsum.c is #included below.
 * ====================================================================
 */
#include <stdio.h>
#include <string.h>

#include <mbtcheck.h>

#include "../../src/textsum.c"

static unsigned char block[TEXTSUM_BLOCK];
static char msg[128];

static void
check_flip(unsigned at)
{
	unsigned before = text_sum(block, sizeof(block));
	unsigned after;

	block[at] ^= 0x01;
	after = text_sum(block, sizeof(block));
	block[at] ^= 0x01;

	sprintf(msg, "one bit flipped at offset %u changes the block sum", at);
	CHECK(before != after, msg);
}

int
main(void)
{
	static const unsigned char a[]      = { 0x61 };
	static const unsigned char foobar[] = { 0x66, 0x6F, 0x6F, 0x62, 0x61, 0x72 };
	static const unsigned char b30[]    = { 0x47, 0xF0, 0xF0, 0x1E };
	static const unsigned char ab[]     = { 0x01, 0x02 };
	static const unsigned char ba[]     = { 0x02, 0x01 };
	unsigned i;

	/* 1. known answers */
	CHECK_EQ(text_sum(a, 0), 0x811C9DC5u, "empty input is the offset basis");
	CHECK_EQ(text_sum(a, sizeof(a)), 0xE40C292Cu, "FNV-1a of 0x61");
	CHECK_EQ(text_sum(foobar, sizeof(foobar)), 0xBF9CF968u,
		 "FNV-1a of the bytes of \"foobar\" (ASCII)");

	/* a zeroed block, as a fixed point for the MVS side */
	memset(block, 0, sizeof(block));
	CHECK_EQ(text_sum(block, sizeof(block)), 0x76EFDDC5u,
		 "FNV-1a of 4096 zero bytes");

	/* 2. every position counts */
	for (i = 0; i < sizeof(block); i++) {
		block[i] = (unsigned char) (i * 7 + 3);
	}
	check_flip(0);
	check_flip(TEXTSUM_BLOCK / 2);
	check_flip(TEXTSUM_BLOCK - 1);

	/* 3. order counts */
	CHECK(text_sum(ab, 2) != text_sum(ba, 2), "swapped bytes change the sum");

	/* 4. the instruction #425 found overwritten */
	CHECK_EQ(text_sum(b30, sizeof(b30)), 0xBA6049D8u,
		 "FNV-1a of 47F0F01E (B 30(0,15))");

	return mbt_test_summary("TSTTXSM");
}
