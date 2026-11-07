/*
 * tstispf.c - #573: the member list carries the ISPF statistics.
 *
 * Zowe asks for `X-IBM-Attributes: base` and prints whatever comes back, so a
 * list of bare names is exactly what the client shows -- no version, no dates,
 * no user. The directory entry held all of it in its user data; the walk in
 * dsapi.c read the entry and threw the user data away.
 *
 * ispf_stats_parse() turns the 30 bytes into the z/OSMF fields. The cases that
 * matter:
 *   - a real entry, with the century, leap-year and packed-field arithmetic
 *   - an entry without user data: no statistics, no invented fields
 *   - a load module's user data, which has a TTR list and no ISPF layout
 *   - a 30-byte field that is not ISPF's (bad packed digits, no date)
 *   - a short or oversized field, and a size smaller than the indicator says
 *
 * This test drives the REAL functions: src/ispfstat.c is #included below. The
 * walk in dsapi.c cannot compile on the host.
 * Runs on host via `mbt test`.
 */
#include <stdio.h>
#include <string.h>

#include <mbtcheck.h>

#include "../../src/ispfstat.c"

/* "IBMUSER " in EBCDIC. The test data is spelled out in bytes on purpose: the
 * userid is raw directory content and must come out untouched. */
#define IBMUSER	0xC9, 0xC2, 0xD4, 0xE4, 0xE2, 0xC5, 0xD9, 0x40

#define HDR	'A', ' ', ' ', ' ', ' ', ' ', ' ', ' ', 0x00, 0x01, 0x02, 0x0F

/* version 1.05, 2015-08-12 (day 224) created and changed, 05:48:43, 22 lines
 * now and at the start, 3 modified */
static const unsigned char ispf[] = {
	HDR,
	0x01, 0x05, 0x00, 0x43,
	0x01, 0x15, 0x22, 0x4F,
	0x01, 0x15, 0x22, 0x4F,
	0x05, 0x48,
	0x00, 0x16, 0x00, 0x16, 0x00, 0x03,
	IBMUSER,
	0x00, 0x00
};

static unsigned char g_e[12 + 64];

/* a copy of `ispf` for the cases that change one byte */
static void fresh(void)
{
	memset(g_e, 0, sizeof(g_e));
	memcpy(g_e, ispf, sizeof(ispf));
}

#define SIZE	((unsigned) sizeof(ispf))

int main(void)
{
	ISPFSTATS s;

	/* 1. a plain entry, field by field */
	memset(&s, 0xAA, sizeof(s));
	CHECK_EQ(ispf_stats_parse(ispf, SIZE, &s), 1, "ISPF entry has statistics");
	CHECK_EQ((int) s.vers, 1, "version");
	CHECK_EQ((int) s.mod, 5, "modification level");
	CHECK(strcmp(s.c4date, "2015/08/12") == 0, "creation date from julian");
	CHECK(strcmp(s.m4date, "2015/08/12") == 0, "change date from julian");
	CHECK(strcmp(s.mtime, "05:48") == 0, "time hh:mm");
	CHECK(strcmp(s.msec, "43") == 0, "seconds");
	CHECK_EQ((int) s.cnorc, 22, "current records");
	CHECK_EQ((int) s.inorc, 22, "initial records");
	CHECK_EQ((int) s.mnorc, 3, "modified records");
	CHECK_EQ((int) s.userlen, 7, "userid length without the blank");
	CHECK(memcmp(s.user, "\xC9\xC2\xD4\xE4\xE2\xC5\xD9", 7) == 0,
	      "userid is the raw EBCDIC bytes");
	CHECK_EQ(s.sclm, 0, "not an SCLM edit");

	/* 2. julian arithmetic: century, leap years, month ends */
	fresh();
	g_e[12 + 4] = 0x01; g_e[12 + 5] = 0x20; g_e[12 + 6] = 0x00; g_e[12 + 7] = 0x6F;
	g_e[12 + 8] = 0x01; g_e[12 + 9] = 0x20; g_e[12 + 10] = 0x36; g_e[12 + 11] = 0x6F;
	CHECK_EQ(ispf_stats_parse(g_e, SIZE, &s), 1, "2020 entry");
	CHECK(strcmp(s.c4date, "2020/01/06") == 0, "day 006 is Jan 6th");
	CHECK(strcmp(s.m4date, "2020/12/31") == 0, "day 366 of a leap year is Dec 31st");

	fresh();
	g_e[12 + 4] = 0x00; g_e[12 + 5] = 0x99; g_e[12 + 6] = 0x36; g_e[12 + 7] = 0x5F;
	CHECK_EQ(ispf_stats_parse(g_e, SIZE, &s), 1, "1999 entry");
	CHECK(strcmp(s.c4date, "1999/12/31") == 0, "day 365 of 1999 is Dec 31st");

	fresh();
	g_e[12 + 4] = 0x01; g_e[12 + 5] = 0x24; g_e[12 + 6] = 0x05; g_e[12 + 7] = 0x9F;
	CHECK_EQ(ispf_stats_parse(g_e, SIZE, &s), 1, "2024 entry");
	CHECK(strcmp(s.c4date, "2024/02/28") == 0, "day 059 of a leap year is Feb 28th");
	g_e[12 + 7] = 0x0F; g_e[12 + 6] = 0x06;
	CHECK_EQ(ispf_stats_parse(g_e, SIZE, &s), 1, "2024 entry, day 060");
	CHECK(strcmp(s.c4date, "2024/02/29") == 0, "day 060 of a leap year is Feb 29th");
	g_e[12 + 6] = 0x06; g_e[12 + 7] = 0x1F;
	CHECK_EQ(ispf_stats_parse(g_e, SIZE, &s), 1, "2024 entry, day 061");
	CHECK(strcmp(s.c4date, "2024/03/01") == 0, "day 061 of a leap year is Mar 1st");

	fresh();
	g_e[12 + 4] = 0x01; g_e[12 + 5] = 0x23; g_e[12 + 6] = 0x06; g_e[12 + 7] = 0x0F;
	CHECK_EQ(ispf_stats_parse(g_e, SIZE, &s), 1, "2023 entry");
	CHECK(strcmp(s.c4date, "2023/03/01") == 0, "day 060 of a common year is Mar 1st");

	/* 3. SCLM flag, counts above 255, a blank userid */
	fresh();
	g_e[12 + 2] = 0x80;
	g_e[12 + 14] = 0x12; g_e[12 + 15] = 0x34;
	g_e[12 + 16] = 0xFF; g_e[12 + 17] = 0xFF;
	memset(&g_e[12 + 20], 0x40, 8);
	CHECK_EQ(ispf_stats_parse(g_e, SIZE, &s), 1, "SCLM entry");
	CHECK_EQ(s.sclm, 1, "SCLM flag");
	CHECK_EQ((int) s.cnorc, 0x1234, "a count over 255");
	CHECK_EQ((int) s.inorc, 65535, "the largest count");
	CHECK_EQ((int) s.userlen, 0, "an all-blank userid is empty");

	/* 4. no statistics: no user data at all */
	fresh();
	g_e[11] = 0x00;
	CHECK_EQ(ispf_stats_parse(g_e, 12, &s), 0, "no user data: no statistics");

	/* 5. user data of another length */
	fresh();
	g_e[11] = 0x0A;		/* 20 bytes */
	CHECK_EQ(ispf_stats_parse(g_e, 12 + 20, &s), 0, "20 bytes: not ISPF");
	g_e[11] = 0x14;		/* 40 bytes, the extended form */
	CHECK_EQ(ispf_stats_parse(g_e, 12 + 40, &s), 0,
	         "40 bytes: extended statistics are not reported");

	/* 6. a load module: 30 bytes of user data behind a TTR list */
	fresh();
	g_e[11] = 0x2F;		/* two TTRs, 15 halfwords */
	CHECK_EQ(ispf_stats_parse(g_e, SIZE, &s), 0, "a TTR list: not ISPF");
	g_e[11] = 0x8F;		/* the alias bit alone is fine */
	CHECK_EQ(ispf_stats_parse(g_e, SIZE, &s), 1, "an alias keeps its statistics");

	/* 7. the entry is shorter than its indicator says */
	fresh();
	CHECK_EQ(ispf_stats_parse(ispf, SIZE - 1, &s), 0, "truncated entry");
	CHECK_EQ(ispf_stats_parse(ispf, 0, &s), 0, "empty entry");
	CHECK_EQ(ispf_stats_parse(NULL, SIZE, &s), 0, "NULL entry");
	CHECK_EQ(ispf_stats_parse(ispf, SIZE, NULL), 0, "NULL result");

	/* 8. 30 bytes that are not ISPF's */
	fresh(); g_e[12 + 0] = 100;
	CHECK_EQ(ispf_stats_parse(g_e, SIZE, &s), 0, "version above 99");
	fresh(); g_e[12 + 1] = 100;
	CHECK_EQ(ispf_stats_parse(g_e, SIZE, &s), 0, "modification level above 99");
	fresh(); g_e[12 + 3] = 0x4A;
	CHECK_EQ(ispf_stats_parse(g_e, SIZE, &s), 0, "seconds not packed");
	fresh(); g_e[12 + 3] = 0x60;
	CHECK_EQ(ispf_stats_parse(g_e, SIZE, &s), 0, "seconds above 59");
	fresh(); g_e[12 + 12] = 0x24;
	CHECK_EQ(ispf_stats_parse(g_e, SIZE, &s), 0, "hour 24");
	fresh(); g_e[12 + 13] = 0x60;
	CHECK_EQ(ispf_stats_parse(g_e, SIZE, &s), 0, "minute 60");
	fresh(); g_e[12 + 4] = 0x02;
	CHECK_EQ(ispf_stats_parse(g_e, SIZE, &s), 0, "century 2");
	fresh(); g_e[12 + 5] = 0x1A;
	CHECK_EQ(ispf_stats_parse(g_e, SIZE, &s), 0, "year not packed");
	fresh(); g_e[12 + 7] = 0x05;
	CHECK_EQ(ispf_stats_parse(g_e, SIZE, &s), 0, "date without a sign nibble");
	fresh(); g_e[12 + 6] = 0x00; g_e[12 + 7] = 0x0F;
	CHECK_EQ(ispf_stats_parse(g_e, SIZE, &s), 0, "day 000");
	fresh(); g_e[12 + 4] = 0x00; g_e[12 + 5] = 0x15; g_e[12 + 6] = 0x36; g_e[12 + 7] = 0x6F;
	CHECK_EQ(ispf_stats_parse(g_e, SIZE, &s), 0, "day 366 of a common year");
	fresh(); g_e[12 + 8] = 0x00; g_e[12 + 9] = 0x15; g_e[12 + 10] = 0x40; g_e[12 + 11] = 0x0F;
	CHECK_EQ(ispf_stats_parse(g_e, SIZE, &s), 0, "change date day 400");

	/* an all-zero field, which is what a directory holds where nobody wrote
	   statistics but the length says there is room */
	fresh(); memset(&g_e[12], 0, 30);
	CHECK_EQ(ispf_stats_parse(g_e, SIZE, &s), 0, "zeros are no statistics");

	/* nothing is written to the result when there are none */
	fresh(); g_e[12 + 0] = 100;
	memset(&s, 0x55, sizeof(s));
	ispf_stats_parse(g_e, SIZE, &s);
	CHECK(s.vers == 0x55555555u && s.c4date[0] == 0x55,
	      "result untouched on failure");

	/* X-IBM-Attributes */
	CHECK_EQ(ispf_wants_base("base"), 1, "base");
	CHECK_EQ(ispf_wants_base("BASE"), 1, "BASE");
	CHECK_EQ(ispf_wants_base("Base"), 1, "Base");
	CHECK_EQ(ispf_wants_base("base,total"), 1, "base,total");
	CHECK_EQ(ispf_wants_base("member"), 0, "member");
	CHECK_EQ(ispf_wants_base("member,total"), 0, "member,total");
	CHECK_EQ(ispf_wants_base("basement"), 0, "another word that begins with base");
	CHECK_EQ(ispf_wants_base("bas"), 0, "a prefix of base");
	CHECK_EQ(ispf_wants_base(""), 0, "empty");
	CHECK_EQ(ispf_wants_base(NULL), 0, "header not sent");

	return mbt_test_summary("TSTISPF");
}
