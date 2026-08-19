/*
 * tstspln.c - #314 regression: a JESJCLIN listing must not lose cards off its
 * tail, and JES2's own pointer records must not reach the client.
 *
 * Root: JES2 writes a 9-byte pointer record into the JCL data set behind every
 * in-stream DD * card, carrying the DSID of the SYSIN data set that card
 * opened. The PDDB record count does not include those records -- it equals
 * the number of JCL statements, and the JESJCL line count, exactly. The #158
 * cap counts what went out, so every pointer record spent one slot of a budget
 * that belonged to a card, and the listing was truncated by one card per
 * in-stream DD. The binary record on the wire was the visible half of that;
 * the missing cards were the silent one.
 *
 * Measured on mvsdev, JCLIN3A/JOB01597 -- 7 statements, three in-stream DDs:
 *
 *   JESJCL   (7 records)   ... //IN3 DD *  /  //LAST DD DUMMY
 *   JESJCLIN (7 records)   ... 5 cards + 2 pointer records, and BOTH
 *                              //IN3 DD * and //LAST DD DUMMY missing
 *
 * Fix: spool_line_action() skips a JESJCLIN record that is not a JCL
 * statement, and a skip counts for neither the cap nor the output.
 *
 * ====================================================================
 * This test drives the REAL function: src/spoolln.c is #included below,
 * and walk() mirrors the callback loop in jobsapi.c one-for-one. The
 * handler itself cannot compile on the host (file-scope HLASM labels +
 * MVS intrinsics), which is why the decision lives in its own TU.
 * ====================================================================
 *
 * Red->green gate: cases 1 and 2 fail on the pre-#314 code (which reached the
 * cap early and emitted the pointer records), and pass on the fixed one.
 * Runs on host via `make test-host`.
 */
#include <stdio.h>
#include <string.h>

#include <mbtcheck.h>

#include "../../src/spoolln.c"

/* One spool record. The pointer records carry NULs, so the length is explicit
 * rather than taken with strlen() -- exactly as jesprint() hands them out. */
typedef struct rec {
	const char *data;
	unsigned    len;
} REC;

#define CARD(s)     { (s), (unsigned)(sizeof(s) - 1) }
#define PTR(s)      { (s), 9 }

/* The pointer record as measured, byte for byte: 0x80, 0x50, the in-stream
 * DSID as a halfword (101 / 102 / 103), then the spool address. Only the
 * first byte matters to the decision -- the rest is here so the record under
 * test is the record on the spool. */
static const char ptr101[] = "\x80\x50\x00\x65\x00\x00\xd0\x00\x00";
static const char ptr102[] = "\x80\x50\x00\x66\x00\x00\xd1\x00\x00";
static const char ptr103[] = "\x80\x50\x00\x67\x00\x00\xd2\x00\x00";

/* ---- the walk, mirroring do_print_sysout_line() -------------------------- */

static const REC *g_out[32];
static unsigned   g_nout;

static void walk(int jclin, unsigned limit, const REC *recs, unsigned nrecs)
{
	unsigned count = 0;
	unsigned i;

	g_nout = 0;

	for (i = 0; i < nrecs; i++) {
		int action = spool_line_action(jclin, limit, count,
		                               recs[i].data, recs[i].len);

		if (action == SPOOL_LINE_STOP) {
			break;
		}
		if (action == SPOOL_LINE_SKIP) {
			continue;      /* counts for neither ctx->count nor ctx->total */
		}

		if (g_nout < (unsigned)(sizeof(g_out) / sizeof(g_out[0]))) {
			g_out[g_nout] = &recs[i];
		}
		g_nout++;
		count++;
	}
}

static int out_is(unsigned i, const char *text)
{
	if (i >= g_nout) {
		return 0;
	}
	return strlen(text) == g_out[i]->len &&
	       memcmp(g_out[i]->data, text, g_out[i]->len) == 0;
}

/* No record that begins with something other than '/' may have gone out. */
static int out_all_statements(void)
{
	unsigned i;

	for (i = 0; i < g_nout; i++) {
		if (!g_out[i]->len || g_out[i]->data[0] != '/') {
			return 0;
		}
	}
	return 1;
}

int main(void)
{
	/* 1. JCLIN3A: three in-stream DDs, no trailing null statement.
	 *    Pre-#314 this emitted 5 cards + 2 pointer records and dropped
	 *    //IN3 DD * and //LAST DD DUMMY entirely. */
	{
		static const REC recs[] = {
			CARD("//JCLIN3A  JOB (ACCT),'INSTREAM A',CLASS=A,MSGCLASS=H,"),
			CARD("//         NOTIFY=$MVSMF,USER=IBMUSER,PASSWORD=   BY MVSMF"),
			CARD("//STEP1    EXEC PGM=IEFBR14"),
			CARD("//IN1      DD *"),
			PTR(ptr101),
			CARD("//IN2      DD *"),
			PTR(ptr102),
			CARD("//IN3      DD *"),
			PTR(ptr103),
			CARD("//LAST     DD DUMMY"),
		};

		walk(1, 7, recs, sizeof(recs) / sizeof(recs[0]));

		CHECK_EQ((int)g_nout, 7, "JCLIN3A: every statement is listed");
		CHECK(out_all_statements(), "JCLIN3A: no pointer record on the wire");
		CHECK(out_is(3, "//IN1      DD *"), "JCLIN3A: card after the 1st DD * kept");
		CHECK(out_is(5, "//IN3      DD *"), "JCLIN3A: card after the 2nd DD * kept");
		CHECK(out_is(6, "//LAST     DD DUMMY"), "JCLIN3A: last card is the last card");
	}

	/* 2. JCLIN3B: the same deck plus the trailing null statement, which the
	 *    PDDB counts as an eighth statement. `//` is a statement and stays. */
	{
		static const REC recs[] = {
			CARD("//JCLIN3B  JOB (ACCT),'INSTREAM B',CLASS=A,MSGCLASS=H,"),
			CARD("//         NOTIFY=$MVSMF,USER=IBMUSER,PASSWORD=   BY MVSMF"),
			CARD("//STEP1    EXEC PGM=IEFBR14"),
			CARD("//IN1      DD *"),
			PTR(ptr101),
			CARD("//IN2      DD *"),
			PTR(ptr102),
			CARD("//IN3      DD *"),
			PTR(ptr103),
			CARD("//LAST     DD DUMMY"),
			CARD("//"),
		};

		walk(1, 8, recs, sizeof(recs) / sizeof(recs[0]));

		CHECK_EQ((int)g_nout, 8, "JCLIN3B: every statement is listed");
		CHECK(out_all_statements(), "JCLIN3B: no pointer record on the wire");
		CHECK(out_is(7, "//"), "JCLIN3B: the null statement is a statement");
	}

	/* 3. The #158 line stays hidden, and now by content rather than by the
	 *    cap -- it is behind the records, and it does not start with '/'. */
	{
		static const REC recs[] = {
			CARD("//ONECARD  JOB (ACCT),'X'"),
			CARD("//S1       EXEC PGM=IEFBR14"),
			CARD("JOB DELETED BY JES2 OR CANCELLED BY OPERATOR BEFORE EXECUTION"),
		};

		walk(1, 2, recs, sizeof(recs) / sizeof(recs[0]));

		CHECK_EQ((int)g_nout, 2, "JCLIN: deletion line does not reach the client");
		CHECK(out_all_statements(), "JCLIN: only statements went out");
	}

	/* 4. Every other spool dataset keeps arbitrary content. An in-stream
	 *    SYSIN holds whatever the submitter wrote, and SYSOUT holds program
	 *    output -- neither may be filtered, only capped. */
	{
		static const REC recs[] = {
			CARD(" RECEIVE INDSN('IBMUSER.MBT.XMIT.IN') -"),
			CARD("  DATASET('IBMUSER.MVSMF.V1R0M0D.LINKLIB')"),
			CARD("IEB1135I IEBCOPY FMID HDZ11SP"),
		};

		walk(0, 0, recs, sizeof(recs) / sizeof(recs[0]));

		CHECK_EQ((int)g_nout, 3, "SYSIN/SYSOUT: content is not filtered");
		CHECK(out_is(0, " RECEIVE INDSN('IBMUSER.MBT.XMIT.IN') -"),
		      "SYSIN/SYSOUT: first record verbatim");

		walk(0, 2, recs, sizeof(recs) / sizeof(recs[0]));
		CHECK_EQ((int)g_nout, 2, "SYSIN: the #158 cap still stops the walk");
	}

	/* 5. The cap is tested before the content: a record beyond the logical
	 *    end of the dataset is not ours to look at, whatever it looks like. */
	CHECK_EQ(spool_line_action(1, 4, 4, "//NEXT     DD DUMMY", 19),
	         SPOOL_LINE_STOP, "cap wins over content");
	CHECK_EQ(spool_line_action(1, 0, 9999, ptr101, 9),
	         SPOOL_LINE_SKIP, "no cap: the walk never stops on the count");

	/* 6. Shapes the predicate has to accept and reject. */
	CHECK_EQ(spool_line_action(1, 0, 0, "//* a comment", 13),
	         SPOOL_LINE_EMIT, "JCLIN: comment card is a statement");
	CHECK_EQ(spool_line_action(1, 0, 0, "/*JOBPARM LINES=9", 17),
	         SPOOL_LINE_EMIT, "JCLIN: JES2 control statement is a statement");
	CHECK_EQ(spool_line_action(1, 0, 0, "", 0),
	         SPOOL_LINE_SKIP, "JCLIN: an empty record is not a statement");

	return mbt_test_summary("TSTSPLN");
}
