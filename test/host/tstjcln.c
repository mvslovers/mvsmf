/*
 * tstjcln.c - #220 regression: growing the JCL line table must never leave the
 * pointer array and the line buffer out of sync.
 *
 * Root: grow_lines_arrays() resized lines_buf first and the lines[] pointer
 * array second. When the second realloc failed it stored the already-grown
 * buffer back into *lines_buf_p and returned -1 without updating *capacity_p
 * or *lines_p -- so the caller was left holding a NEW buffer described by an
 * OLD pointer array, every entry of which addressed the block realloc had just
 * released. Both submit paths (jobsapi.c submit_file / submit_jcl_content)
 * bail on -1 and only free(), so the torn state was never dereferenced; but
 * since libc370#81 (fixed by libc370#82) realloc can genuinely fail, so the
 * state became reachable rather than theoretical.
 *
 * Fix: grow the pointer array first, the buffer second. A failure then leaves
 * the caller's view of the table byte-for-byte as it was.
 *
 * ====================================================================
 * This test drives the REAL function. src/jclines.c is #included below
 * with realloc macro-substituted for a fault injector, so the code under
 * test is the shipping code, not a mirror of it -- a later refactor of
 * grow_lines_arrays() stays covered. jobsapi.c itself cannot compile on
 * the host (file-scope HLASM asm labels + MVS intrinsics), which is why
 * the function lives in its own TU.
 * ====================================================================
 *
 * The assertions are deliberately written against the INVARIANT rather than
 * the call order, so they are a red->green gate: they fail on the old
 * buffer-first code and pass on the fixed pointer-array-first code.
 * Runs on host via `make test-host`.
 */
#include <stdio.h>
#include <stdlib.h>   /* LOAD-BEARING: must precede the realloc macro below, so
                       * that the macro rewrites call sites in the source under
                       * test and never the declaration itself. Do not remove or
                       * reorder when tidying these includes. */
#include <string.h>
#include <limits.h>

#include <mbtcheck.h>

/* ---- fault-injecting allocator -------------------------------------------
 * fail_at is the 0-based ordinal of the realloc call to fail (-1 = never).
 * The real headers are already included above, so the macro below rewrites
 * only the call sites inside the source under test. */
static int tst_fail_at = -1;
static int tst_calls   = 0;

static void *tst_realloc(void *p, size_t n)
{
	int seq = tst_calls++;

	if (seq == tst_fail_at) {
		return NULL;
	}
	return realloc(p, n);
}

#define realloc tst_realloc
#include "../../src/jclines.c"
#undef realloc

/* ---- table helpers (mirror how jobsapi.c builds the pair) ----------------- */

#define TST_CAP     8            /* small enough to keep the test cheap       */
#define TST_STRIDE  81

static char **g_lines;
static char  *g_buf;
static int    g_cap;

static void table_new(void)
{
	int i;

	g_cap   = TST_CAP;
	g_lines = (char **)calloc(g_cap, sizeof(char *));
	g_buf   = (char *)calloc(g_cap, TST_STRIDE);
	for (i = 0; i < g_cap; i++) {
		g_lines[i] = g_buf + (i * TST_STRIDE);
	}
	/* content the caller would still expect to read back after a failed grow */
	strcpy(g_lines[0], "//TSTJCLN JOB (ACCT),'MVSMF',CLASS=A");
	strcpy(g_lines[TST_CAP - 1], "//SYSIN DD *");
}

static void table_free(void)
{
	free(g_lines);
	free(g_buf);
	g_lines = NULL;
	g_buf   = NULL;
}

/* Every entry below the recorded capacity addresses the live buffer. */
static int table_consistent(void)
{
	int i;

	for (i = 0; i < g_cap; i++) {
		if (g_lines[i] != g_buf + (i * TST_STRIDE)) {
			return 0;
		}
	}
	return 1;
}

/* Run one grow with the Nth realloc forced to fail (-1 = let them all pass). */
static int grow_with_failure_at(int nth, int required)
{
	tst_calls   = 0;
	tst_fail_at = nth;
	return grow_lines_arrays(&g_lines, &g_buf, &g_cap, required);
}

int main(void)
{
	int   rc;
	char *saved_buf;
	int   saved_cap;

	printf("=== TSTJCLN: #220 atomic JCL line table growth ===\n");

	/* 1. baseline -- an uninterrupted grow commits all three out-params */
	table_new();
	rc = grow_with_failure_at(-1, TST_CAP + 1);
	CHECK_EQ(rc, 0, "success: grow returns 0");
	CHECK_EQ(g_cap, TST_CAP * 2, "success: capacity doubled");
	CHECK(table_consistent(), "success: every entry addresses the live buffer");
	CHECK(strcmp(g_lines[0], "//TSTJCLN JOB (ACCT),'MVSMF',CLASS=A") == 0,
		  "success: existing line content preserved");
	CHECK(g_lines[TST_CAP * 2 - 1][0] == '\0', "success: new tail slots zeroed");
	table_free();

	/* 2. required already fits -- no-op, no allocation at all */
	table_new();
	rc = grow_with_failure_at(-1, TST_CAP);
	CHECK_EQ(rc, 0, "no-op: grow returns 0 when capacity suffices");
	CHECK_EQ(tst_calls, 0, "no-op: no realloc issued");
	CHECK_EQ(g_cap, TST_CAP, "no-op: capacity unchanged");
	CHECK(table_consistent(), "no-op: table still consistent");
	table_free();

	/* 3. FIRST realloc fails -- caller's table must be completely untouched */
	table_new();
	saved_buf = g_buf;
	saved_cap = g_cap;
	rc = grow_with_failure_at(0, TST_CAP + 1);
	CHECK_EQ(rc, -1, "fail#1: grow reports failure");
	CHECK_EQ(g_cap, saved_cap, "fail#1: capacity unchanged");
	CHECK(g_buf == saved_buf, "fail#1: buffer pointer unchanged");
	CHECK(table_consistent(), "fail#1: table still consistent");
	table_free();

	/* 4. SECOND realloc fails -- the #220 case. One of the two allocations has
	 *    already succeeded, so this is where the pair could tear apart. The
	 *    contract is the same as above: capacity and buffer unchanged, and
	 *    every entry still addressing that buffer.
	 *
	 *    The buffer identity is checked BEFORE any content read: on the old
	 *    code g_buf has been swapped for the grown block while g_lines[] still
	 *    points into the released one, and reading through it is undefined.
	 *    Checking the pointer first turns that into a clean FAIL. */
	table_new();
	saved_buf = g_buf;
	saved_cap = g_cap;
	rc = grow_with_failure_at(1, TST_CAP + 1);
	CHECK_EQ(rc, -1, "fail#2: grow reports failure");
	CHECK_EQ(g_cap, saved_cap, "fail#2: capacity unchanged");
	CHECK(g_buf == saved_buf, "fail#2: buffer pointer unchanged");

	if (g_buf == saved_buf && table_consistent()) {
		CHECK(1, "fail#2: table still consistent");
		CHECK(strcmp(g_lines[0], "//TSTJCLN JOB (ACCT),'MVSMF',CLASS=A") == 0,
			  "fail#2: line content still readable through lines[]");
		CHECK(strcmp(g_lines[TST_CAP - 1], "//SYSIN DD *") == 0,
			  "fail#2: last line still readable through lines[]");
	} else {
		CHECK(0, "fail#2: table still consistent");
		CHECK(0, "fail#2: line content still readable through lines[] (skipped)");
		CHECK(0, "fail#2: last line still readable through lines[] (skipped)");
	}
	table_free();

	/* 5. capacity doubling must not overflow int before any allocation runs */
	table_new();
	saved_buf = g_buf;
	saved_cap = g_cap;
	rc = grow_with_failure_at(-1, INT_MAX);
	CHECK_EQ(rc, -1, "overflow: grow refuses an unrepresentable capacity");
	CHECK_EQ(tst_calls, 0, "overflow: refused before allocating anything");
	CHECK_EQ(g_cap, saved_cap, "overflow: capacity unchanged");
	CHECK(g_buf == saved_buf, "overflow: buffer pointer unchanged");
	CHECK(table_consistent(), "overflow: table still consistent");
	table_free();

	return mbt_test_summary("TSTJCLN");
}
