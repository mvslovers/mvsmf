/*
 * tstcolpl.c - #475 regression: a collect poll that cannot allocate its
 * response buffer must fail, not answer an empty block.
 *
 * Root: consoleCollectHandler answered send_collect(session, "") when
 * malloc(RESP_CAP) returned NULL, before it looked at the Master Trace Table.
 * A client that polls collect stops on an empty answer and takes the block for
 * finished, so a storage shortage lost the lines still to come -- the failure
 * class of #251 (hardcopy log) and #407 (failed table copy), left open on the
 * one path that runs before the table is read.
 *
 * The convention under test: collect_poll() returns COLLECT_POLL_FAILED for an
 * allocation that failed and for a snapshot that failed, leaves the delivered
 * count as it was, and leaves nothing for the caller to free. The handler
 * answers 500 8/1 on it (by review: it does not compile on the host).
 *
 * ====================================================================
 * This test drives the REAL function: src/collpoll.c is #included below with
 * a malloc that can be told to fail and a correlator that can be told to
 * report a failed snapshot. consapi.c itself cannot compile on the host
 * (file-scope HLASM labels + MVS intrinsics).
 * ====================================================================
 *
 * Red->green gate: the allocation cases fail on the pre-#475 code, which
 * carried on with no buffer or answered an empty block. Runs on host via
 * `mbt test`.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <mbtcheck.h>

/* keep the real headers out also when cc370 builds this test (__MVS__) */
#define MTTSNAP_FAKES

typedef struct {
	short mtentlen;
	char  mtentdat[96];
} MTENTRY;

typedef struct { int dummy; } CMTT;
typedef struct { int dummy; } Session;

static int fake_malloc_fails;
static int fake_malloc_calls;
static int fake_free_calls;

static void *fake_malloc(size_t n)
{
	fake_malloc_calls++;
	return fake_malloc_fails ? (void *)0 : malloc(n);
}

static void fake_free(void *p)
{
	if (p) fake_free_calls++;
	free(p);
}

#define malloc fake_malloc
#define free   fake_free

#include "../../src/collpoll.c"

#undef malloc
#undef free

/* ---- a correlator that answers what it is told ------------------------ */

static int      corr_fails;      /* report MTT_SNAP_FAILED                    */
static int      corr_calls;
static unsigned corr_total;      /* lines in the block                        */
static unsigned corr_skip_seen;
static int      corr_secs_seen;

static int fake_corr(Session *session, const char *cmd_upper, char *out,
                     size_t outsz, unsigned skip, unsigned *total,
                     int want_secs, int *echo_secs_out)
{
	(void)session; (void)cmd_upper; (void)echo_secs_out;
	corr_calls++;
	corr_skip_seen = skip;
	corr_secs_seen = want_secs;
	if (corr_fails) return MTT_SNAP_FAILED;
	*total = corr_total;
	strncpy(out, "IEE136I LOCAL: TIME=09.24.38\n", outsz - 1);
	out[outsz - 1] = '\0';
	return 0;
}

static void reset(void)
{
	fake_malloc_fails = 0;
	fake_malloc_calls = 0;
	fake_free_calls = 0;
	corr_fails = 0;
	corr_calls = 0;
	corr_total = 0;
	corr_skip_seen = 99999;
	corr_secs_seen = -99;
}

int main(void)
{
	Session session = { 0 };
	unsigned delivered;
	char *resp;
	int r;

	printf("=== TSTCOLPL: #475 collect poll without a response buffer ===\n");

	/* 1. healthy: the lines come back, the count moves forward, and the
	 *    cursor's fields reach the correlator */
	reset();
	corr_total = 5;
	delivered = 3;
	resp = (char *)0;
	r = collect_poll(&session, fake_corr, "D T", 42, 4096, &delivered, &resp);
	CHECK_EQ(r, 0, "healthy: poll succeeds");
	CHECK(resp != (char *)0, "healthy: a buffer is handed out");
	CHECK(resp && strstr(resp, "IEE136I") != (char *)0, "healthy: the lines are in it");
	CHECK_EQ(delivered, 5u, "healthy: delivered moves forward to the block size");
	CHECK_EQ(corr_skip_seen, 3u, "healthy: the correlator skips what was delivered");
	CHECK_EQ(corr_secs_seen, 42, "healthy: the correlator gets the echo second");
	CHECK_EQ(fake_free_calls, 0, "healthy: the buffer is the caller's to free");
	fake_free(resp);

	/* 2. the count only moves forward: a shorter block does not count it down */
	reset();
	corr_total = 2;
	delivered = 7;
	r = collect_poll(&session, fake_corr, "D T", 42, 4096, &delivered, &resp);
	CHECK_EQ(r, 0, "shorter block: poll succeeds");
	CHECK_EQ(delivered, 7u, "shorter block: delivered is not counted down");
	fake_free(resp);

	/* 3. no storage for the buffer (#475): a failure, nothing handed out,
	 *    the correlator never asked, the count untouched. Before the fix
	 *    this was an empty block, i.e. "finished". */
	reset();
	fake_malloc_fails = 1;
	corr_total = 9;
	delivered = 3;
	resp = (char *)0;
	r = collect_poll(&session, fake_corr, "D T", 42, 4096, &delivered, &resp);
	CHECK_EQ(r, COLLECT_POLL_FAILED, "malloc fails: FAILED, not an empty block");
	CHECK(resp == (char *)0, "malloc fails: no buffer handed out");
	CHECK_EQ(delivered, 3u, "malloc fails: delivered unchanged");
	CHECK_EQ(corr_calls, 0, "malloc fails: the table is not read");

	/* 4. the table copy fails (#407): the same answer, and the buffer that
	 *    was allocated is released */
	reset();
	corr_fails = 1;
	corr_total = 9;
	delivered = 3;
	resp = (char *)0;
	r = collect_poll(&session, fake_corr, "D T", 42, 4096, &delivered, &resp);
	CHECK_EQ(r, COLLECT_POLL_FAILED, "snapshot fails: FAILED, not an empty block");
	CHECK(resp == (char *)0, "snapshot fails: no buffer handed out");
	CHECK_EQ(delivered, 3u, "snapshot fails: delivered unchanged");
	CHECK_EQ(fake_malloc_calls, 1, "snapshot fails: one buffer was allocated");
	CHECK_EQ(fake_free_calls, 1, "snapshot fails: and released");

	/* 5. an empty block is an answer, not a failure */
	reset();
	corr_total = 0;
	delivered = 0;
	r = collect_poll(&session, fake_corr, "D T", -1, 4096, &delivered, &resp);
	CHECK_EQ(r, 0, "empty block: poll succeeds");
	CHECK_EQ(delivered, 0u, "empty block: delivered stays 0");
	fake_free(resp);

	return mbt_test_summary("TSTCOLPL");
}
