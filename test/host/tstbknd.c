/*
 * tstbknd.c - #508: /zosmf/test is registered only in a development build.
 *
 * mbt 3 cannot build a module differently for a release, so mvsmf.c decides at
 * start-up from the version mbt stamps into <buildstamp.h>. The decision must
 * fail closed: anything that is not clearly a "-dev" version leaves the
 * endpoint off.
 *
 * This test drives the REAL function: src/buildkind.c is #included below.
 *
 * Runs on host via `mbt test`.
 */
#include <stdio.h>
#include <string.h>

#include <mbtcheck.h>

#include "../../src/buildkind.c"

static char msg[160];

static void
check_kind(const char *version, int want)
{
	sprintf(msg, "build_is_dev(\"%s\") is %d", version ? version : "NULL", want);
	CHECK_EQ(build_is_dev(version), want, msg);
}

int
main(void)
{
	printf("--- development versions ---\n");
	check_kind("1.4.0-dev", 1);
	check_kind("1.10.12-dev", 1);
	check_kind("-dev", 1);

	printf("\n--- release versions: the endpoint stays off ---\n");
	check_kind("1.4.0", 0);
	check_kind("1.4.1", 0);
	check_kind("2.0.0", 0);

	printf("\n--- anything else fails closed ---\n");
	check_kind(NULL, 0);
	check_kind("", 0);
	check_kind("dev", 0);
	check_kind("1.4.0-dev1", 0);
	check_kind("1.4.0-dev.2", 0);
	check_kind("1.4.0-rc1", 0);
	check_kind("1.4.0-DEV", 0);
	check_kind("1.4.0-dev ", 0);

	return mbt_test_summary("TSTBKND");
}
