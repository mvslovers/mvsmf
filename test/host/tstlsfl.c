/*
 * tstlsfl.c - #360 regression: a NULL from __listds()/__listpd() is an empty
 * result or a failure, and errno says which.
 *
 * Root: dsapi.c took every NULL for "nothing there" - an empty `items` array
 * for the data set list, 404 "member not found" for a failed directory read -
 * so a storage shortage (ENOMEM) or an unreadable directory was answered as a
 * fact about the catalog. The decision now lives in list_outcome(), which the
 * three call sites share (datasetListHandler(), diagnose_open_failure(),
 * fn=listds).
 *
 * ====================================================================
 * This test drives the REAL function: src/listfail.c is #included below.
 * dsapi.c itself cannot compile on the host (file-scope HLASM labels + MVS
 * headers); the HTTP mapping of each outcome is by review.
 * ====================================================================
 *
 * Red->green gate: the ENOMEM and read-failure cases have no function to call
 * before #360, and the pre-#360 handlers answered all three NULL cases alike.
 * Runs on host via `mbt test`.
 */
#include <errno.h>
#include <stdio.h>

#include <mbtcheck.h>

#include "../../src/listfail.c"

static char msg[120];

static void
check(const void *list, int err, int want, const char *what)
{
	sprintf(msg, "%s: outcome %d", what, want);
	CHECK_EQ(list_outcome(list, err), want, msg);
}

int main(void)
{
	int item = 0;

	check(NULL, 0, LIST_EMPTY, "NULL, errno 0 is an empty result");
	check(NULL, ENOMEM, LIST_NOSTOR, "NULL, ENOMEM is a storage shortage");
	check(NULL, EIO, LIST_FAILED, "NULL, EIO is a failed directory read");
	check(NULL, ENOENT, LIST_FAILED, "NULL, fopen()'s errno is a failure");

	/* errno is only meaningful on NULL: an earlier call may have left it */
	check(&item, 0, LIST_FOUND, "a list with errno 0");
	check(&item, ENOMEM, LIST_FOUND, "a list is not a shortage, whatever errno holds");
	check(&item, EIO, LIST_FOUND, "a list is not a failure, whatever errno holds");

	return mbt_test_summary("TSTLSFL");
}
