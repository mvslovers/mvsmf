/*
 * tstsubds.c - #477: the data set name of a job submit "file" member.
 *
 * submit_file() copied the quoted text into dsname[45] with a length taken
 * from the request, so a 45-character name wrote past the buffer on the
 * stack. The caller's buffer here is followed by a canary, and an over-long
 * name must be refused without touching a byte of it. The limits are those of
 * the parts: 44 for the data set name, 8 for the member, so DSN(MEMBER) is
 * accepted up to 54 characters and refused when either part is too long.
 *
 * This test drives the REAL function: src/subdsn.c is #included below.
 */
#include <stdio.h>
#include <string.h>

#include <mbtcheck.h>

#include "../../src/subdsn.c"

#define CANARY	0x5A
#define NCANARY	24

struct slot {
	char	dsname[SUBDSN_SIZE];
	char	canary[NCANARY];
};

static int
canary_intact(const struct slot *s)
{
	int ii;

	for (ii = 0; ii < NCANARY; ii++) {
		if ((unsigned char)s->canary[ii] != CANARY) return 0;
	}
	return 1;
}

/* two slashes, a quote, the text, a quote */
static void
quoted(char *out, const char *text)
{
	strcpy(out, "//'");
	strcat(out, text);
	strcat(out, "'");
}

/* n times 'A' */
static void
fill(char *out, size_t n)
{
	memset(out, 'A', n);
	out[n] = '\0';
}

static void
check_name(const char *what, const char *text, int want_rc)
{
	struct slot s;
	char file[160];
	char msg[120];
	int rc;

	quoted(file, text);
	memset(s.dsname, '#', sizeof(s.dsname));
	memset(s.canary, CANARY, sizeof(s.canary));

	rc = submit_dsname(file, s.dsname, sizeof(s.dsname));

	snprintf(msg, sizeof(msg), "%s: rc", what);
	CHECK_EQ(rc, want_rc, msg);
	snprintf(msg, sizeof(msg), "%s: nothing written past the buffer", what);
	CHECK(canary_intact(&s), msg);
	if (want_rc == 0) {
		snprintf(msg, sizeof(msg), "%s: name", what);
		CHECK(strcmp(s.dsname, text) == 0, msg);
	} else {
		snprintf(msg, sizeof(msg), "%s: buffer untouched", what);
		CHECK(s.dsname[0] == '#', msg);
	}
}

int
main(void)
{
	char dsn[DSNAME_MAX + 8];
	char text[160];

	CHECK_EQ((int)SUBDSN_SIZE, 55, "buffer holds 44 + ( + 8 + ) + NUL");

	check_name("plain name", "SYS1.PROCLIB(X)", 0);
	check_name("one character", "A", 0);

	fill(dsn, DSNAME_MAX);
	check_name("44 characters", dsn, 0);

	strcpy(text, dsn);
	strcat(text, "(MEMBER01)");
	check_name("44-character name with an 8-character member", text, 0);

	check_name("36-character name with a member",
		   "PROD.PAYROLL.MONTHLY.RUN.JCL.LIBRARY(MONTHEND)", 0);

	fill(dsn, DSNAME_MAX + 1);
	check_name("45 characters", dsn, -1);
	fill(dsn, 100);
	check_name("100 characters", dsn, -1);

	fill(dsn, DSNAME_MAX + 1);
	strcpy(text, dsn);
	strcat(text, "(MEMBER)");
	check_name("45-character name with a member", text, -1);

	fill(dsn, DSNAME_MAX);
	strcpy(text, dsn);
	strcat(text, "(MEMBER012)");
	check_name("9-character member", text, -1);

	check_name("member without closing parenthesis", "MY.PDS(MEMBER", -1);
	check_name("empty member", "MY.PDS()", -1);
	check_name("empty name before the member", "(MEMBER)", -1);
	check_name("text after the closing parenthesis", "MY.PDS(MEM)X", -1);

	/* shapes of the whole request value */
	{
		struct slot s;

		memset(s.canary, CANARY, sizeof(s.canary));
		CHECK_EQ(submit_dsname("MY.JCL", s.dsname, sizeof(s.dsname)), -1,
			 "no quotes");
		CHECK_EQ(submit_dsname("'MY.JCL'", s.dsname, sizeof(s.dsname)), -1,
			 "no leading slashes");
		CHECK_EQ(submit_dsname("//'MY.JCL", s.dsname, sizeof(s.dsname)), -1,
			 "no closing quote");
		CHECK_EQ(submit_dsname("//''", s.dsname, sizeof(s.dsname)), -1,
			 "empty name");
		CHECK_EQ(submit_dsname("", s.dsname, sizeof(s.dsname)), -1,
			 "empty text");
		CHECK_EQ(submit_dsname("//'ABCDEF'", s.dsname, 6), -1,
			 "caller buffer too small for the name");
		CHECK(canary_intact(&s), "shapes: canary intact");
	}

	return mbt_test_summary("TSTSUBDS");
}
