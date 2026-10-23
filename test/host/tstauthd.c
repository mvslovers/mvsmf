/*
 * tstauthd.c - #460: the authorization check of the console and test
 * endpoints.
 *
 * Only SAF rc 0 permits.  The answers that look harmless are the ones this
 * test is about: rc 4 ("no profile covers the resource") is what an
 * unconfigured system gives, and a decision that reads it as "permitted" opens
 * the endpoints for everyone; -1 is not a "small" return code to a test written
 * as rc <= 4.  A request with no ACEE is refused without asking RACF at all.
 *
 * This test drives the REAL implementation: src/authdec.c is #included below.
 *
 * Runs on host via `mbt test`.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <mbtcheck.h>

#include "../../src/authdec.c"

static char msg[120];

static int calls;
static int answer;

static int
stub_racf(void *arg)
{
	(void)arg;
	calls++;
	return answer;
}

static void
test_decide(void)
{
	static const struct {
		int rc, want;
		const char *what;
	} t[] = {
		{ 0,   AUTHDEC_ALLOW, "rc 0: READ granted" },
		{ 4,   AUTHDEC_DENY,  "rc 4: no profile is a refusal" },
		{ 8,   AUTHDEC_DENY,  "rc 8: no READ is a refusal" },
		{ 12,  AUTHDEC_DENY,  "rc 12 is a refusal" },
		{ 16,  AUTHDEC_DENY,  "rc 16 is a refusal" },
		{ -1,  AUTHDEC_DENY,  "rc -1 is a refusal" },
		{ 1,   AUTHDEC_DENY,  "rc 1 is a refusal" },
		{ 256, AUTHDEC_DENY,  "rc 256 is a refusal" },
	};
	size_t i;

	printf("\n--- #460: the decision ---\n");

	for (i = 0; i < sizeof(t) / sizeof(t[0]); i++)
		CHECK_EQ(authdec_decide(1, t[i].rc), t[i].want, t[i].what);

	CHECK_EQ(authdec_decide(0, 0), AUTHDEC_NOACEE,
		 "no ACEE is refused even with rc 0");
	CHECK_EQ(authdec_decide(0, 4), AUTHDEC_NOACEE, "no ACEE and rc 4");
	CHECK_EQ(authdec_decide(0, 8), AUTHDEC_NOACEE, "no ACEE and rc 8");
	CHECK_EQ(authdec_decide(0, -1), AUTHDEC_NOACEE, "no ACEE and rc -1");
}

static void
test_gate(void)
{
	static const int rcs[] = { 0, 4, 8, 12, -1 };
	size_t i;

	printf("\n--- #460: the gate ---\n");

	for (i = 0; i < sizeof(rcs) / sizeof(rcs[0]); i++) {
		calls = 0;
		answer = rcs[i];
		snprintf(msg, sizeof(msg), "RACF answers %d", rcs[i]);
		CHECK_EQ(authdec_gate(1, stub_racf, NULL),
			 rcs[i] == 0 ? AUTHDEC_ALLOW : AUTHDEC_DENY, msg);
		CHECK_EQ(calls, 1, "RACF is asked once");
	}

	calls = 0;
	answer = 0;
	CHECK_EQ(authdec_gate(0, stub_racf, NULL), AUTHDEC_NOACEE,
		 "no ACEE is refused");
	CHECK_EQ(calls, 0, "RACF is not asked without an ACEE");
	CHECK_EQ(authdec_gate(1, NULL, NULL), AUTHDEC_DENY,
		 "no way to ask is a refusal");
	CHECK_EQ(authdec_gate(0, NULL, NULL), AUTHDEC_NOACEE,
		 "no ACEE and no way to ask");
}

int
main(void)
{
	test_decide();
	test_gate();

	return mbt_test_summary("TSTAUTHD");
}
