/*
 * tstabnd.c - #256: the abend code has to reach the client.
 *
 * A space abend during a dataset PUT used to arrive as a bare "Internal server
 * error (abend recovery)". The router's ESTAE recovery had the code in hand
 * when it built the response -- it printed it to the console and then dropped
 * it -- so a full data set and a protection exception read identically and
 * telling them apart cost a console round trip.
 *
 * What this pins down:
 *
 *   1. The code is in the message, for every abend.
 *   2. The x37 family is named, since that is what a write into a full data
 *      set produces (the measured case was SD37 on SPACE=TRK(1,0,0)).
 *   3. Nothing is truncated: SD37 is the longest text at 80 characters, and
 *      ABEND_MSG_SIZE has to keep holding it. snprintf() truncates silently,
 *      so a buffer that shrinks below the text would ship a cut-off sentence
 *      and nothing would surface it.
 *   4. A user abend renders as U0100, not as S000.
 *
 * ====================================================================
 * This test drives the REAL function: src/abendmsg.c is #included below.
 * router.c itself cannot compile on the host (clibwto, clibtry, the httpd
 * callback table), which is why the message lives in its own TU.
 * ====================================================================
 *
 * Expected texts are compared against string literals the same compiler
 * produced, so the runtime encoding does not matter -- the test is portable
 * and runs under `make test-host`.
 */
#include <stdio.h>
#include <string.h>

#include <mbtcheck.h>

#include "../../src/abendmsg.c"

#define CANARY	0x7E	/* guards the bytes past the formatted text */

static char	g_buf[ABEND_MSG_SIZE + 8];

/* Format into a canary-filled buffer, as the recovery path does with its
 * stack buffer. Returns the text. */
static const char *fmt(unsigned sys, unsigned usr)
{
	memset(g_buf, CANARY, sizeof(g_buf));
	abend_message(g_buf, ABEND_MSG_SIZE, sys, usr);
	return g_buf;
}

/* Nothing was written past the buffer the caller declared. */
static int canary_intact(void)
{
	size_t i;

	for (i = ABEND_MSG_SIZE; i < sizeof(g_buf); i++) {
		if (g_buf[i] != (char) CANARY) {
			return 0;
		}
	}
	return 1;
}

int main(void)
{
	/* 1. the x37 family is named, not just numbered */
	CHECK(strcmp(fmt(0xB37, 0),
		     "Internal server error (abend SB37: out of space on the volume)") == 0,
	      "SB37: names the volume being full");
	CHECK(canary_intact(), "SB37: nothing written past the buffer");

	CHECK(strcmp(fmt(0xD37, 0),
		     "Internal server error (abend SD37: primary extent full, "
		     "no secondary allocation)") == 0,
	      "SD37: names the missing secondary allocation");
	CHECK(canary_intact(), "SD37: nothing written past the buffer");

	/* the longest text there is -- it must survive whole, since snprintf
	 * would truncate it without a word */
	CHECK_EQ((int) strlen(fmt(0xD37, 0)), 80, "SD37: the longest text is not truncated");

	CHECK(strcmp(fmt(0xE37, 0),
		     "Internal server error (abend SE37: extent limit reached)") == 0,
	      "SE37: names the extent limit");

	/* 2. every other system abend still carries its code */
	CHECK(strcmp(fmt(0x0C4, 0), "Internal server error (abend S0C4)") == 0,
	      "S0C4: the code reaches the client");
	CHECK(strcmp(fmt(0x001, 0), "Internal server error (abend S001)") == 0,
	      "S001: three digits, not one");
	CHECK(strcmp(fmt(0x322, 0), "Internal server error (abend S322)") == 0,
	      "S322: the code reaches the client");

	/* 3. a user abend has no system code -- U0100, never S000 */
	CHECK(strcmp(fmt(0, 100), "Internal server error (abend U0100)") == 0,
	      "U0100: rendered as a user abend");
	CHECK(strcmp(fmt(0, 0), "Internal server error (abend U0000)") == 0,
	      "U0000: rendered as a user abend");

	/* 4. the prefix is what the router promised the client all along */
	CHECK(strncmp(fmt(0x0C4, 0), "Internal server error", 21) == 0,
	      "the message still starts with Internal server error");

	/* 5. a caller passing a short buffer gets a NUL-terminated truncation,
	 *    not an overrun */
	{
		char small[16];

		memset(small, CANARY, sizeof(small));
		abend_message(small, 10, 0xD37, 0);
		CHECK_EQ((int) strlen(small), 9, "short buffer: truncated to fit");
		CHECK(small[10] == (char) CANARY, "short buffer: nothing written past it");
	}

	return mbt_test_summary("TSTABND");
}
