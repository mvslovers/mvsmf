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
 *   5. S913 is classified as an authorization denial and nothing else is
 *      (#315). That one abend is a refusal OPEN made rather than a failure,
 *      so the router answers it with the reference's authorization report
 *      instead of the generic abend body. S213 is the trap: it comes out of
 *      the same IEC1xx family and means "cannot be opened sequentially", so
 *      folding it in would report an ordinary open failure as a permission
 *      problem.
 *
 * ====================================================================
 * This test drives the REAL function: src/abendmsg.c is #included below.
 * router.c itself cannot compile on the host (clibwto, clibtry, the httpd
 * callback table), which is why the message lives in its own TU.
 * ====================================================================
 *
 * Expected texts are compared against string literals the same compiler
 * produced, so the runtime encoding does not matter -- the test is portable
 * and runs under `mbt test`.
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

	/* 6. S913 is a denial; nothing else is (#315) */
	{
		const char *d = abend_denial_detail(0x913);

		CHECK(d != NULL, "S913: classified as an authorization denial");
		CHECK(d && strstr(d, "Authorization failed") != NULL,
		      "S913: the sentence names the authorization failure");

		/* The pre-check in dsapi.c refuses before any open and stops one
		 * clause earlier. This path did abend, and the reference's own text
		 * says so -- if the two ever became identical, one of them would be
		 * lying about what happened. */
		CHECK(d && strstr(d, "913 abend") != NULL,
		      "S913: the sentence names the abend, unlike a pre-check refusal");

		/* the trap: same message family, different condition */
		CHECK(abend_denial_detail(0x213) == NULL,
		      "S213: not a denial (cannot open sequentially)");
		CHECK(abend_denial_detail(0x0C4) == NULL, "S0C4: not a denial");
		CHECK(abend_denial_detail(0xD37) == NULL, "SD37: not a denial");
		CHECK(abend_denial_detail(0x0B37) == NULL, "SB37: not a denial");
		CHECK(abend_denial_detail(0) == NULL,
		      "a user abend is not a denial (sys is 0)");

		/* 913 must be matched as the hex completion code, not as decimal 913
		 * -- the router derives sys with a shift and a mask, so a decimal
		 * comparison would silently match S391 instead */
		CHECK(abend_denial_detail(913) == NULL,
		      "decimal 913 (S391) is not the denial code");
	}

	/* 7. where the abend happened (#425): the failing instruction from the
	 * PSW, and offsets from the entry point. Known answers: the two S0C7 of
	 * #425 on m38b (MVSMF loaded with entry 6113C8; the dump's SDWA has
	 * PSW FF850007 E05F6F8A, R14 605F2FBC) and libc370's own tsttryi run
	 * (S0C1 at 096030, PSW FF850001 40096032). */
	{
		const unsigned s0c7[2] = { 0xFF850007, 0xE05F6F8A };
		const unsigned s0c1[2] = { 0xFF850001, 0x40096032 };
		const unsigned ilc0[2] = { 0xFF850004, 0x00123456 };
		const unsigned seg[2]  = { 0xFF850010, 0xA0123456 };
		const unsigned page[2] = { 0xFF850011, 0xE0123456 };
		const unsigned prot[2] = { 0xFF850004, 0xA0123456 };

		CHECK(abend_instr_addr(s0c7) == 0x5F6F84,
		      "S0C7 ILC 3: the instruction starts 6 bytes before the PSW address");
		CHECK(abend_instr_addr(s0c1) == 0x096030,
		      "S0C1 ILC 1: the instruction starts 2 bytes before the PSW address");
		CHECK(abend_instr_addr(ilc0) == 0x123456,
		      "ILC 0: the PSW address is left as it is");
		/* nullifying exceptions: the PSW points AT the instruction */
		CHECK(abend_instr_addr(seg) == 0x123456,
		      "INTC 0010 (segment translation) nullifies: nothing subtracted");
		CHECK(abend_instr_addr(page) == 0x123456,
		      "INTC 0011 (page translation) nullifies: nothing subtracted");
		/* the control: same address and ILC, a protection exception */
		CHECK(abend_instr_addr(prot) == 0x123452,
		      "INTC 0004 (protection) is completed or suppressed: ILC subtracted");

		CHECK(abend_ep_offset(0x5F6F84, 0x006113C8) == -0x1A444L,
		      "an address below the entry point is a negative offset");
		CHECK(abend_ep_offset(0x605F2FBC, 0x006113C8) == -0x1E40CL,
		      "R14's high byte (ILC and CC) is ignored");
		CHECK(abend_ep_offset(0x611400, 0x806113C8) == 0x38L,
		      "an address above the entry point is a positive offset");

		/* cross-check against the release module: entry 0x32F50, so the
		 * instruction sits at module offset 0x32F50 - 0x1A444 = 0x18B0C --
		 * find_and_send_job_status, as the dump analysis in #425 found */
		CHECK(0x32F50L + abend_ep_offset(abend_instr_addr(s0c7), 0x6113C8)
		      == 0x18B0CL,
		      "entry + offset is the module offset the link map lists");
	}

	return mbt_test_summary("TSTABND");
}
