/*
 * tstmtsn.c - #407 regression: a failed Master Trace Table snapshot must not
 * read as "no matches".
 *
 * Root: cmtt_new() returns NULL when it cannot allocate the copy of the table.
 * consapi.c folded that into a count of 0 -- `cmtt ? cmtt_get_array(cmtt) :
 * NULL`, then `arr ? array_count(&arr) : 0` -- in both snapshot sites left
 * after #251 fixed the hardcopy log:
 *
 *   detect_count()   returned 0. At issue time that 0 became the detection
 *                    baseline, so every later healthy poll counted the matches
 *                    that were in the table before the command and reported
 *                    "detected" with an old message. At detect time it was
 *                    never above the baseline: "waiting", then "expired".
 *   correlate_once() reported 0 lines and an echo second of -1, which stores a
 *                    cursor that makes collect anchor on the NEWEST echo of
 *                    the command -- #214's mis-anchor, reopened.
 *
 * The convention under test: a snapshot that could not be taken is
 * MTT_SNAP_FAILED, which no count can be; an EMPTY table is a snapshot with no
 * entries and still counts 0.
 *
 * ====================================================================
 * This test drives the REAL functions: src/mttsnap.c is #included below, with
 * MTENTRY, CMTT, Session and the cmtt_* calls replaced by fakes that can be
 * told to fail. consapi.c itself cannot compile on the host (file-scope HLASM
 * labels + MVS intrinsics), which is why mtt_snap_open() and
 * mtt_detect_count() live in their own TU. correlate_once() takes its
 * snapshot through mtt_snap_open(), so the failure it must report is the one
 * tested here; what it and the handlers do with that result is review.
 * ====================================================================
 *
 * Red->green gate: the failure cases fail on the pre-#407 code (which answers
 * 0 / success) and pass on the fixed one. Runs on host via `mbt test`.
 */
#include <stdio.h>
#include <string.h>

#include <mbtcheck.h>

/* ---- fakes for what <mvs/mtt.h> and router.h provide on MVS ---------- */

/* keep the real headers out also when cc370 builds this test (__MVS__) */
#define MTTSNAP_FAKES

typedef struct {
	short mtentlen;
	char  mtentdat[96];
} MTENTRY;

typedef struct { int dummy; } CMTT;
typedef struct { int dummy; } Session;

static CMTT      fake_cmtt;
static MTENTRY   fake_pool[16];
static MTENTRY  *fake_arr[16];
static unsigned  fake_n;
static int       fake_new_fails;     /* cmtt_new() -> NULL                    */
static int       fake_array_fails;   /* cmtt_get_array() -> NULL              */
static int       fake_free_calls;

static CMTT *cmtt_new(void)
{
	return fake_new_fails ? (CMTT *)0 : &fake_cmtt;
}

static MTENTRY **cmtt_get_array(CMTT *c)
{
	return (c && !fake_array_fails) ? fake_arr : (MTENTRY **)0;
}

static void cmtt_free(CMTT **pc)
{
	fake_free_calls++;
	*pc = (CMTT *)0;
}

static unsigned fake_array_count(Session *session, void *varray)
{
	(void)session;
	(void)varray;
	return fake_n;
}

/* the httpd vector macro, which on MVS reads `session` */
#define array_count(varray) fake_array_count(session, (void *)(varray))

#include "../../src/mttsnap.c"

/* ---- table fixture ---------------------------------------------------- */

static void table_reset(void)
{
	memset(fake_pool, 0, sizeof(fake_pool));
	memset(fake_arr, 0, sizeof(fake_arr));
	fake_n = 0;
	fake_new_fails = 0;
	fake_array_fails = 0;
	fake_free_calls = 0;
}

/* One line in the layout of a formatted MTT entry: 24 columns of flags, time
 * and source, then the message text (MTT_MSG_OFF). */
static void table_add(const char *msg)
{
	MTENTRY *e = &fake_pool[fake_n];
	char line[96];

	memset(line, ' ', sizeof(line));
	memcpy(line, "0000  9.24.38 STC  320  ", MTT_MSG_OFF);
	memcpy(line + MTT_MSG_OFF, msg, strlen(msg));
	memcpy(e->mtentdat, line, MTT_MSG_OFF + strlen(msg));
	e->mtentlen = (short)(MTT_MSG_OFF + strlen(msg));
	fake_arr[fake_n] = e;
	fake_n++;
}

int main(void)
{
	Session session = { 0 };
	CMTT *cmtt = (CMTT *)0;
	MTENTRY **arr = (MTENTRY **)0;
	unsigned n = 99;
	char latest[64];
	int r;

	printf("=== TSTMTSN: #407 failed MTT snapshot is not 'no matches' ===\n");

	/* 1. an EMPTY table is a snapshot with no entries: count 0, handle freed.
	 *    This is the line the fix must not move -- 0 and "failed" differ. */
	table_reset();
	strcpy(latest, "stale");
	r = mtt_detect_count(&session, "FTPD", latest, sizeof(latest));
	CHECK_EQ(r, 0, "empty table: count is 0, not FAILED");
	CHECK(latest[0] == '\0', "empty table: latest is empty");
	CHECK_EQ(fake_free_calls, 1, "empty table: handle released once");

	/* 2. a healthy table counts case-insensitively and reports the newest */
	table_reset();
	table_add("S FTPD");
	table_add("ftpd054i Listening on port 2121");
	table_add("IEE136I LOCAL: TIME=09.24.38");
	table_add("FTPD055I Connection accepted   ");
	r = mtt_detect_count(&session, "FTPD", latest, sizeof(latest));
	CHECK_EQ(r, 3, "healthy: three matching entries");
	CHECK(strcmp(latest, "FTPD055I Connection accepted") == 0,
	      "healthy: latest is the newest match, right-stripped");
	CHECK_EQ(fake_free_calls, 1, "healthy: handle released once");

	/* 3. cmtt_new() fails: FAILED, never 0. Before the fix this answered 0,
	 *    which the issue path stored as the detection baseline. */
	table_reset();
	table_add("FTPD054I Listening on port 2121");
	fake_new_fails = 1;
	strcpy(latest, "stale");
	r = mtt_detect_count(&session, "FTPD", latest, sizeof(latest));
	CHECK_EQ(r, MTT_SNAP_FAILED, "cmtt_new fails: FAILED, not a count of 0");
	CHECK(r < 0, "cmtt_new fails: result cannot be taken for a baseline");
	CHECK(latest[0] == '\0', "cmtt_new fails: latest is empty");
	CHECK_EQ(fake_free_calls, 0, "cmtt_new fails: nothing to release");

	/* 4. the copy exists but has no array: FAILED, and the handle is freed
	 *    (a leak here costs storage on exactly the path that is short of it) */
	table_reset();
	table_add("FTPD054I Listening on port 2121");
	fake_array_fails = 1;
	r = mtt_detect_count(&session, "FTPD", latest, sizeof(latest));
	CHECK_EQ(r, MTT_SNAP_FAILED, "no array: FAILED, not a count of 0");
	CHECK_EQ(fake_free_calls, 1, "no array: handle released once");

	/* 5. the snapshot call itself: the one correlate_once() makes */
	table_reset();
	r = mtt_snap_open(&session, &cmtt, &arr, &n);
	CHECK_EQ(r, 0, "snap_open, empty table: success");
	CHECK(arr != (MTENTRY **)0, "snap_open, empty table: has an array");
	CHECK_EQ(n, 0u, "snap_open, empty table: no entries");
	CHECK(cmtt != (CMTT *)0, "snap_open, empty table: handle to release");

	table_reset();
	table_add("S FTPD");
	table_add("FTPD054I Listening on port 2121");
	r = mtt_snap_open(&session, &cmtt, &arr, &n);
	CHECK_EQ(r, 0, "snap_open, healthy: success");
	CHECK_EQ(n, 2u, "snap_open, healthy: both entries");

	table_reset();
	fake_new_fails = 1;
	cmtt = &fake_cmtt;
	arr = fake_arr;
	n = 99;
	r = mtt_snap_open(&session, &cmtt, &arr, &n);
	CHECK_EQ(r, MTT_SNAP_FAILED, "snap_open, cmtt_new fails: FAILED");
	CHECK(arr == (MTENTRY **)0, "snap_open, cmtt_new fails: no array handed out");
	CHECK_EQ(n, 0u, "snap_open, cmtt_new fails: no entries handed out");
	CHECK(cmtt == (CMTT *)0, "snap_open, cmtt_new fails: nothing to release");

	table_reset();
	fake_array_fails = 1;
	r = mtt_snap_open(&session, &cmtt, &arr, &n);
	CHECK_EQ(r, MTT_SNAP_FAILED, "snap_open, no array: FAILED");
	CHECK(arr == (MTENTRY **)0, "snap_open, no array: no array handed out");
	CHECK_EQ(n, 0u, "snap_open, no array: no entries handed out");
	CHECK(cmtt == (CMTT *)0, "snap_open, no array: handle already released");
	CHECK_EQ(fake_free_calls, 1, "snap_open, no array: handle released once");

	/* 6. mtt_len is the real clamp now (#176): a negative or absurd length
	 *    never reaches a copy */
	{
		MTENTRY e;
		memset(&e, 0, sizeof(e));
		e.mtentlen = (short)0xC1C1;
		CHECK_EQ(mtt_len(&e), 0, "mtt_len: negative length reads as 0");
		e.mtentlen = 5000;
		CHECK_EQ(mtt_len(&e), MTT_ENTRY_MAX, "mtt_len: absurd length is capped");
		e.mtentlen = 42;
		CHECK_EQ(mtt_len(&e), 42, "mtt_len: sane length passes through");
		CHECK_EQ(mtt_len((const MTENTRY *)0), 0, "mtt_len: NULL entry is 0");
	}

	return mbt_test_summary("TSTMTSN");
}
