/*
 * tstjcard.c - #365 regression: clearing credentials off a submitted JOB card.
 *
 * mvsMF puts USER=/PASSWORD= on every INTRDR submit because MVS 3.8j does no
 * userid propagation. It used to do that unconditionally, so a caller who
 * wrote USER= on their own card got two of them and the job failed
 * conversion:
 *
 *   //T365A    JOB (ACCT),'USER ON CARD',CLASS=A,MSGCLASS=H,
 *   //         USER=IBMUSER,
 *   //         NOTIFY=$MVSMF,USER=IBMUSER,PASSWORD=   BY MVSMF
 *
 *   IEF452I JOBFAIL  JOB NOT RUN - JCL ERROR
 *   IEF652I MUTUALLY EXCLUSIVE KEYWORDS
 *
 * Measured on mvsdev 2026-09-14, JOB00351.
 *
 * The rule: the authenticated identity always wins, so any USER= or PASSWORD=
 * already on the card is removed first. What this test pins is not that rule
 * -- it is one line in jobsapi.c -- but the removal, which is where a job card
 * gets quietly corrupted if it is wrong. Three ways that can happen, all
 * silent until conversion fails or the wrong bytes reach JES2:
 *
 *   - cutting text out of the quoted programmer name, because "USER" occurs
 *     there too
 *   - leaving a dangling or a missing comma, so the operand field ends on a
 *     separator that leads nowhere, or two operands run together
 *   - leaving a continuation card with no operands on it, which is a JCL
 *     error in its own right
 *
 * ====================================================================
 * This test drives the REAL removal: src/jobcard.c is #included below.
 * jobsapi.c cannot compile on the host (MVS services throughout), which
 * is why the removal lives in its own TU.
 * ====================================================================
 *
 * Runs on host via `mbt test`.
 */
#include <stdio.h>
#include <string.h>

#include <mbtcheck.h>

#include "../../src/jobcard.c"

static char msg[240];

/* Strip a whole card given as up to four lines, NULL terminated, and compare
   every resulting line against what is expected. A blanked continuation is
   written "" in the expectation. */
static void
check_card(const char *what, const char **card, const char **want, int want_removed)
{
	char	buf[4][90];
	char	*lines[4];
	int	n = 0;
	int	removed;
	int	ii;

	while (card[n] && n < 4) {
		snprintf(buf[n], sizeof(buf[n]), "%s", card[n]);
		lines[n] = buf[n];
		n++;
	}

	removed = jobcard_strip_credentials(lines, 0, n - 1);

	snprintf(msg, sizeof(msg), "%s: removed %d, expected %d",
	         what, removed, want_removed);
	CHECK(removed == want_removed, msg);

	for (ii = 0; ii < n; ii++) {
		snprintf(msg, sizeof(msg), "%s: line %d is \"%s\", expected \"%s\"",
		         what, ii, lines[ii], want[ii]);
		CHECK(strcmp(lines[ii], want[ii]) == 0, msg);
	}
}

int
main(void)
{
	/* --- nothing to remove: the card must come back untouched --------- */
	{
		const char *card[] = { "//T1       JOB (ACCT),'PLAIN',CLASS=A", NULL };
		const char *want[] = { "//T1       JOB (ACCT),'PLAIN',CLASS=A" };
		check_card("no credentials on the card", card, want, 0);
	}

	/* --- #365 itself: USER= alone on a continuation ------------------- */
	/* The continuation is left empty and must be blanked; the line before it
	   keeps the comma that made it a continuation, which is what the injected
	   card will hang off. */
	{
		const char *card[] = {
			"//T365A    JOB (ACCT),'USER ON CARD',CLASS=A,MSGCLASS=H,",
			"//         USER=IBMUSER",
			NULL
		};
		const char *want[] = {
			"//T365A    JOB (ACCT),'USER ON CARD',CLASS=A,MSGCLASS=H,",
			""
		};
		check_card("USER= alone on a continuation", card, want, 1);
	}

	/* --- operand in the middle: the following comma goes with it ------ */
	{
		const char *card[] = {
			"//T2       JOB (ACCT),'X',USER=BOB,CLASS=A", NULL
		};
		const char *want[] = { "//T2       JOB (ACCT),'X',CLASS=A" };
		check_card("USER= between two operands", card, want, 1);
	}

	/* --- operand last: the PRECEDING comma goes with it --------------- */
	/* Taking the following one instead would leave the field ending on a
	   comma, which announces a continuation that is not there yet. */
	{
		const char *card[] = {
			"//T3       JOB (ACCT),'X',CLASS=A,USER=BOB", NULL
		};
		const char *want[] = { "//T3       JOB (ACCT),'X',CLASS=A" };
		check_card("USER= last in the operand field", card, want, 1);
	}

	/* --- both operands, adjacent -------------------------------------- */
	{
		const char *card[] = {
			"//T4       JOB (ACCT),'X',USER=BOB,PASSWORD=SECRET,CLASS=A", NULL
		};
		const char *want[] = { "//T4       JOB (ACCT),'X',CLASS=A" };
		check_card("USER= and PASSWORD= together", card, want, 2);
	}

	/* --- both operands, last in the field ----------------------------- */
	{
		const char *card[] = {
			"//T5       JOB (ACCT),'X',CLASS=A,USER=BOB,PASSWORD=SECRET", NULL
		};
		const char *want[] = { "//T5       JOB (ACCT),'X',CLASS=A" };
		check_card("USER= and PASSWORD= at the end", card, want, 2);
	}

	/* --- spread across continuation lines ----------------------------- */
	{
		const char *card[] = {
			"//T6       JOB (ACCT),'X',CLASS=A,",
			"//         USER=BOB,",
			"//         PASSWORD=SECRET",
			NULL
		};
		const char *want[] = {
			"//T6       JOB (ACCT),'X',CLASS=A,",
			"",
			""
		};
		check_card("credentials on their own continuations", card, want, 2);
	}

	/* --- a continuation that keeps something is NOT blanked ----------- */
	{
		const char *card[] = {
			"//T7       JOB (ACCT),'X',",
			"//         USER=BOB,NOTIFY=SAM",
			NULL
		};
		const char *want[] = {
			"//T7       JOB (ACCT),'X',",
			"//         NOTIFY=SAM"
		};
		check_card("continuation keeps its other operands", card, want, 1);
	}

	/* --- the quoted programmer name must survive intact --------------- */
	/* This is the damage a bare strstr() does, and nothing downstream can
	   notice it: the card still converts, it just says something else. */
	{
		const char *card[] = {
			"//T8       JOB (ACCT),'USER=BOB AND FRIENDS',CLASS=A", NULL
		};
		const char *want[] = {
			"//T8       JOB (ACCT),'USER=BOB AND FRIENDS',CLASS=A"
		};
		check_card("USER= inside the programmer name", card, want, 0);
	}
	{
		const char *card[] = {
			"//T9       JOB (ACCT),'PASSWORD= IS UNSET',CLASS=A", NULL
		};
		const char *want[] = {
			"//T9       JOB (ACCT),'PASSWORD= IS UNSET',CLASS=A"
		};
		check_card("PASSWORD= inside the programmer name", card, want, 0);
	}

	/* --- doubled apostrophes leave the quote state where it was ------- */
	{
		const char *card[] = {
			"//TA       JOB (ACCT),'IT''S MINE',USER=BOB,CLASS=A", NULL
		};
		const char *want[] = {
			"//TA       JOB (ACCT),'IT''S MINE',CLASS=A"
		};
		check_card("a real operand after a doubled apostrophe", card, want, 1);
	}

	/* --- a keyword that merely ends in USER is not USER= -------------- */
	{
		const char *card[] = {
			"//TB       JOB (ACCT),'X',MYUSER=BOB,CLASS=A", NULL
		};
		const char *want[] = {
			"//TB       JOB (ACCT),'X',MYUSER=BOB,CLASS=A"
		};
		check_card("MYUSER= is not USER=", card, want, 0);
	}

	/* --- the JOB statement line is never blanked ---------------------- */
	/* Even when stripping takes everything a caller wrote, the name and verb
	   have to stay: blanking this line loses the job entirely. */
	{
		const char *card[] = { "//TC       JOB USER=BOB", NULL };
		const char *want[] = { "//TC       JOB " };
		check_card("the JOB statement survives losing its only operand",
		           card, want, 1);
	}

	/* --- two occurrences on one line are both removed ----------------- */
	/* A malformed card can carry the same operand twice; removing one and
	   leaving the other would hand JES2 exactly the IEF652I this fixes. */
	{
		const char *card[] = {
			"//TD       JOB (ACCT),'X',USER=BOB,CLASS=A,USER=SAM", NULL
		};
		const char *want[] = { "//TD       JOB (ACCT),'X',CLASS=A" };
		check_card("both occurrences of USER= go", card, want, 2);
	}

	/* --- operands_empty is about operands, not about blanks ----------- */
	CHECK(jobcard_operands_empty("//         ") == 1,
	      "a continuation with only blanks carries no operands");
	CHECK(jobcard_operands_empty("//") == 1,
	      "a bare // carries no operands");
	CHECK(jobcard_operands_empty("//         CLASS=A") == 0,
	      "a continuation with an operand is not empty");
	CHECK(jobcard_operands_empty(NULL) == 1,
	      "a NULL line carries no operands");

	/* --- bad arguments are refused, not guessed at -------------------- */
	CHECK(jobcard_strip_credentials(NULL, 0, 0) == -1,
	      "a NULL line table is refused");
	{
		char *lines[1] = { NULL };
		CHECK(jobcard_strip_credentials(lines, 1, 0) == -1,
		      "an inverted range is refused");
	}

	return mbt_test_summary("tstjcard");
}
