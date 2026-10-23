/*
 * tstsubds.c - #477: the data set name of a job submit "file" member.
 *
 * submit_file() copied the text between //' and ' into dsname[45] with a length
 * taken from the request, so //'<45 characters>' wrote past the buffer on the
 * stack. The caller's buffer here is followed by a canary, and an over-long
 * name must be refused without touching a byte of it.
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
	char	dsname[DSNAME_MAX + 1];
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

/* //' + n characters + ' */
static void
quoted(char *out, size_t n)
{
	out[0] = '/';
	out[1] = '/';
	out[2] = '\'';
	memset(out + 3, 'A', n);
	out[3 + n] = '\'';
	out[4 + n] = '\0';
}

static void
check_name(const char *what, const char *file, int want_rc, const char *want_name)
{
	struct slot s;
	char msg[120];
	int rc;

	memset(s.dsname, '#', sizeof(s.dsname));
	memset(s.canary, CANARY, sizeof(s.canary));

	rc = submit_dsname(file, s.dsname, sizeof(s.dsname));

	snprintf(msg, sizeof(msg), "%s: rc", what);
	CHECK_EQ(rc, want_rc, msg);
	snprintf(msg, sizeof(msg), "%s: nothing written past the buffer", what);
	CHECK(canary_intact(&s), msg);
	if (want_name) {
		snprintf(msg, sizeof(msg), "%s: name", what);
		CHECK(strcmp(s.dsname, want_name) == 0, msg);
	}
}

int
main(void)
{
	char file[160];
	char name[DSNAME_MAX + 2];

	check_name("plain name", "//'SYS1.PROCLIB(X)'", 0, "SYS1.PROCLIB(X)");
	check_name("one character", "//'A'", 0, "A");

	memset(name, 'A', DSNAME_MAX);
	name[DSNAME_MAX] = '\0';
	quoted(file, DSNAME_MAX);
	check_name("44 characters fill the buffer", file, 0, name);

	quoted(file, DSNAME_MAX + 1);
	check_name("45 characters", file, -1, NULL);
	quoted(file, 100);
	check_name("100 characters", file, -1, NULL);

	check_name("no quotes", "MY.JCL", -1, NULL);
	check_name("no leading slashes", "'MY.JCL'", -1, NULL);
	check_name("no closing quote", "//'MY.JCL", -1, NULL);
	check_name("empty name", "//''", -1, NULL);
	check_name("empty text", "", -1, NULL);

	return mbt_test_summary("TSTSUBDS");
}
