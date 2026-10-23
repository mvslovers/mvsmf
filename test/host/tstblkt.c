/*
 * tstblkt.c - #439: blocks per track from the format-4 DSCB geometry.
 *
 * The values are the ones measured from __dscbv() on MVS/CE with libc370
 * 2.24.0 and later: MVSRES (3350) devtk 19254, devov 267, devk 82, DS4DEVFG
 * X'08'; PUB000 (3380) devtk 47968, devov 0, devk 0, DS4DEVFG X'20'.
 *
 * This test drives the REAL function: src/blkptrk.c is #included below.
 */
#include <stdio.h>
#include <string.h>

#include <mbtcheck.h>

#include "../../src/blkptrk.c"

#define D3350	19254u, 267u, 82u, 0x08u
#define D3380	47968u, 0u, 0u, 0x20u

static void
check(unsigned bpt, unsigned want, unsigned blksz, const char *dev)
{
	char msg[80];

	snprintf(msg, sizeof(msg), "%s blksz %u: %u blocks per track", dev, blksz, want);
	CHECK_EQ(bpt, want, msg);
}

int
main(void)
{
	/* 3380: 1499 cells, 15 + ceil((blksz + 12) / 32) cells per block */
	check(blocks_per_track(D3380, 800u), 36u, 800u, "3380");
	check(blocks_per_track(D3380, 3120u), 13u, 3120u, "3380");
	check(blocks_per_track(D3380, 6160u), 7u, 6160u, "3380");
	check(blocks_per_track(D3380, 23476u), 2u, 23476u, "3380");
	check(blocks_per_track(D3380, 32760u), 1u, 32760u, "3380");

	/* 3350: byte overhead 267 - 82 = 185 */
	check(blocks_per_track(D3350, 800u), 19u, 800u, "3350");
	check(blocks_per_track(D3350, 6000u), 3u, 6000u, "3350");
	check(blocks_per_track(D3350, 9500u), 1u, 9500u, "3350");

	/* unknown: no block size, a block that does not fit, other geometry */
	CHECK_EQ(blocks_per_track(D3380, 0u), 0u, "blksz 0 is unknown");
	CHECK_EQ(blocks_per_track(D3350, 19070u), 0u, "3350 block larger than a track");
	CHECK_EQ(blocks_per_track(58786u, 0u, 0u, 0x20u, 800u), 0u,
		 "cell device that is not a 3380 is unknown");
	CHECK_EQ(blocks_per_track(100u, 267u, 82u, 0x08u, 800u), 0u,
		 "track shorter than the overhead does not wrap around");
	CHECK_EQ(blocks_per_track(19254u, 82u, 267u, 0x08u, 800u), 0u,
		 "devk above devov does not wrap around");

	/* #443: the device type comes from devtk, not from tracks per cylinder
	   (a 3380 and a 3390 both have 15) */
	CHECK(strcmp(device_name(19254u), "3350") == 0, "MVSRES devtk 19254 is a 3350");
	CHECK(strcmp(device_name(47968u), "3380") == 0, "PUB000 devtk 47968 is a 3380");
	CHECK(strcmp(device_name(58786u), "3390") == 0, "PUB001 devtk 58786 is a 3390");
	CHECK(strcmp(device_name(36000u), "3375") == 0, "devtk 36000 is a 3375");
	CHECK(strcmp(device_name(13165u), "3330") == 0, "devtk 13165 is a 3330");
	CHECK(strcmp(device_name(56664u), DEVICE_UNKNOWN) == 0,
	      "56664 is the usable bytes of a 3390 track, not its DS4DEVTK");
	CHECK(strcmp(device_name(0u), DEVICE_UNKNOWN) == 0, "devtk 0 (DSCB unreadable) is unknown");
	CHECK(strcmp(device_name(13030u), DEVICE_UNKNOWN) == 0, "an unlisted capacity is unknown, not a 3390");

	return mbt_test_summary("TSTBLKT");
}
