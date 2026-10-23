/*
 * tstjreq.c - #417: the body of PUT /zosmf/restjobs/jobs/{name}/{id}.
 *
 * The route answered 404 for every body because it was not registered. Once
 * it is, the handler dispatches on the "request" member, and what this pins is
 * the decision: cancel, the two requests that are not implemented yet (hold,
 * release: #424), anything else, and a body with no usable "request" at all.
 * Each of those has its own answer on the wire, so mixing two up is a wrong
 * status or a wrong text -- or, worst, a cancel for a body that did not ask
 * for one.
 *
 * The TU #includes src/jobreq.c so it drives the real parser jobsapi.c calls.
 *
 * Runs on host via `mbt test`.
 */
#include <stdio.h>
#include <string.h>

#include <mbtcheck.h>

#include "../../src/jobreq.c"

static char msg[240];

static void
check(const char *body, int want)
{
	int got = jobreq_parse(body);

	snprintf(msg, sizeof(msg), "%s: got %d, expected %d", body, got, want);
	CHECK(got == want, msg);
}

int
main(void)
{
	/* --- the documented bodies ---------------------------------------- */
	check("{\"request\":\"cancel\"}", JOBREQ_CANCEL);
	check("{\"request\":\"cancel\",\"version\":\"2.0\"}", JOBREQ_CANCEL);
	check("{\"version\":\"2.0\",\"request\":\"cancel\"}", JOBREQ_CANCEL);
	check("{\"request\":\"hold\"}", JOBREQ_HOLD);
	check("{\"request\":\"release\",\"version\":\"1.0\"}", JOBREQ_RELEASE);

	/* --- layout is not meaning ---------------------------------------- */
	check("  {\n\t\"request\" :  \"cancel\"\r\n}  ", JOBREQ_CANCEL);

	/* --- a request is exactly one of the three ------------------------ */
	check("{\"request\":\"CANCEL\"}", JOBREQ_UNKNOWN);
	check("{\"request\":\"cancelx\"}", JOBREQ_UNKNOWN);
	check("{\"request\":\"canc\"}", JOBREQ_UNKNOWN);
	check("{\"request\":\"\"}", JOBREQ_UNKNOWN);
	check("{\"request\":\"purge\"}", JOBREQ_UNKNOWN);
	check("{\"request\":null}", JOBREQ_UNKNOWN);
	check("{\"request\":true}", JOBREQ_UNKNOWN);
	check("{\"request\":[\"cancel\"]}", JOBREQ_UNKNOWN);
	check("{\"request\":{\"x\":\"cancel\"}}", JOBREQ_UNKNOWN);

	/* --- only a member of the object itself counts -------------------- */
	/* the word inside a value, or inside a nested object, is not the request */
	check("{\"note\":\"request cancel\",\"version\":\"2.0\"}", JOBREQ_NONE);
	check("{\"note\":\"\\\"request\\\":\\\"cancel\\\"\"}", JOBREQ_NONE);
	check("{\"x\":{\"request\":\"cancel\"}}", JOBREQ_NONE);
	check("{\"x\":[{\"request\":\"cancel\"}],\"request\":\"hold\"}", JOBREQ_HOLD);
	check("{\"x\":\"a}\",\"request\":\"cancel\"}", JOBREQ_CANCEL);

	/* --- no usable request -------------------------------------------- */
	check("{}", JOBREQ_NONE);
	check("{\"version\":\"2.0\"}", JOBREQ_NONE);
	check("", JOBREQ_NONE);
	check("   ", JOBREQ_NONE);
	check("request=cancel", JOBREQ_NONE);
	check("[\"request\",\"cancel\"]", JOBREQ_NONE);
	check("\"cancel\"", JOBREQ_NONE);

	/* --- damaged JSON never becomes a cancel --------------------------- */
	check("{\"request\":\"cancel\"", JOBREQ_NONE);
	check("{\"request\":\"cancel", JOBREQ_NONE);
	check("{\"request\"", JOBREQ_NONE);
	check("{\"request\":", JOBREQ_NONE);
	check("{\"request", JOBREQ_NONE);
	check("{", JOBREQ_NONE);
	check("{\"x\":\"unterminated,\"request\":\"cancel\"}", JOBREQ_NONE);

	/* --- the last duplicate wins, as in every JSON parser -------------- */
	check("{\"request\":\"hold\",\"request\":\"cancel\"}", JOBREQ_CANCEL);
	check("{\"request\":\"cancel\",\"request\":\"hold\"}", JOBREQ_HOLD);

	/* --- NULL is refused, not dereferenced ----------------------------- */
	CHECK(jobreq_parse(NULL) == JOBREQ_NONE, "a NULL body has no request");

	return mbt_test_summary("tstjreq");
}
