/*
 * tstrqpth.c - #507: the request path is decoded once, by httpd.
 *
 * httpd's http_decode() has already turned %xx into the character by the time
 * the router sees REQUEST_PATH. The router used to decode it again, so
 *
 *   - a path that was encoded twice ("%2541") came out as a different name
 *     ("A") than the client sent, and
 *   - a name with a literal percent sign followed by two hex digits
 *     ("a%25b1", which httpd delivers as "a%b1") was read as an escape and
 *     came out as "a" plus one byte.
 *
 * What this pins down: request_path_copy() hands the path over unchanged.
 * The inputs below are what httpd delivers, i.e. already decoded once.
 *
 * ====================================================================
 * This test drives the REAL function: src/reqpath.c is #included below.
 * router.c itself cannot compile on the host (it pulls in the httpd
 * session headers), which is why the copy lives in its own TU.
 * ====================================================================
 *
 * Runs on host via `mbt test`.
 */
#include <stdio.h>
#include <string.h>

#include <mbtcheck.h>

#include "../../src/reqpath.c"

#define PATHBUF 64

static char msg[160];

static void
check_path(const char *delivered, const char *want)
{
	char buf[PATHBUF];
	int rc;

	memset(buf, '@', sizeof(buf));
	buf[sizeof(buf) - 1] = '\0';

	rc = request_path_copy(delivered, buf, sizeof(buf));
	snprintf(msg, sizeof(msg), "request_path_copy(\"%s\") returns 0", delivered);
	CHECK_EQ(rc, 0, msg);

	snprintf(msg, sizeof(msg), "request_path_copy(\"%s\") yields \"%s\", not \"%s\"",
		delivered, buf, want);
	CHECK(strcmp(buf, want) == 0, msg);
}

int
main(void)
{
	char small[4];

	printf("\n--- #507: a path httpd has decoded is not decoded again ---\n");

	/* httpd turned "%2541" into "%41"; that is the name. */
	check_path("/zosmf/restfiles/fs/tmp/%41", "/zosmf/restfiles/fs/tmp/%41");
	check_path("/%2f",                        "/%2f");
	check_path("/%25",                        "/%25");

	/* a name with a literal percent sign, delivered as httpd decoded it */
	check_path("/u/a%b1",                     "/u/a%b1");
	check_path("/u/a%41b",                    "/u/a%41b");
	check_path("/u/100%",                     "/u/100%");
	check_path("/u/%zz",                      "/u/%zz");

	printf("\n--- ordinary paths ---\n");

	check_path("/zosmf/info",                 "/zosmf/info");
	check_path("/zosmf/restfiles/ds/A.B(C)",  "/zosmf/restfiles/ds/A.B(C)");
	check_path("",                            "");

	printf("\n--- bad arguments and short buffers ---\n");

	CHECK_EQ(request_path_copy(NULL, small, sizeof(small)), -1,
		"request_path_copy with a null path");
	CHECK_EQ(request_path_copy("/a", NULL, sizeof(small)), -1,
		"request_path_copy with a null buffer");
	CHECK_EQ(request_path_copy("/a", small, 0), -1,
		"request_path_copy with outSize 0");

	CHECK_EQ(request_path_copy("/abcdef", small, sizeof(small)), 0,
		"request_path_copy cuts a path that does not fit");
	CHECK(strcmp(small, "/ab") == 0,
		"a cut path is terminated at outSize - 1");

	return mbt_test_summary("TSTRQPTH");
}
