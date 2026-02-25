#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <clibwto.h>
#include <cliblist.h>
#include <clibdscb.h>
#include <clibary.h>

#include "testapi.h"
#include "common.h"
#include "httpd.h"

int testHandler(Session *session)
{
	int rc = 0;
	char *fn = NULL;

	fn = (char *) http_get_env(session->httpc, (const UCHAR *) "QUERY_FN");
	if (!fn) fn = "help";

	if ((rc = http_resp(session->httpc, 200)) < 0) goto quit;
	if ((rc = http_printf(session->httpc,
		"Content-Type: application/json\r\n\r\n")) < 0) goto quit;

	/* --- fn=listds ------------------------------------------------ */
	if (strcmp(fn, "listds") == 0) {
		char *level  = (char *) http_get_env(session->httpc,
			(const UCHAR *) "QUERY_LEVEL");
		char *filter = (char *) http_get_env(session->httpc,
			(const UCHAR *) "QUERY_FILTER");
		DSLIST **dslist = NULL;
		unsigned i, count;

		if (!level) level = "SYS1";

		dslist = __listds(level, "NONVSAM VOLUME", filter);

		rc = http_printf(session->httpc,
			"{ \"fn\": \"listds\", \"level\": \"%s\", \"filter\": \"%s\",\n",
			level, filter ? filter : "(null)");
		if (rc < 0) goto quit;

		rc = http_printf(session->httpc, "  \"items\": [\n");
		if (rc < 0) goto quit;

		count = dslist ? array_count(&dslist) : 0;
		for (i = 0; i < count; i++) {
			DSLIST *ds = dslist[i];
			if (!ds) continue;
			rc = http_printf(session->httpc,
				"    %s{ \"dsn\": \"%s\", \"vol\": \"%.6s\","
				" \"dsorg\": \"%.4s\", \"recfm\": \"%.4s\","
				" \"lrecl\": %d, \"blksize\": %d }\n",
				i > 0 ? "," : " ",
				ds->dsn, ds->volser, ds->dsorg, ds->recfm,
				ds->lrecl, ds->blksize);
			if (rc < 0) goto quit;
		}

		rc = http_printf(session->httpc,
			"  ], \"count\": %u }\n", count);

		if (dslist) __freeds(&dslist);

	/* --- fn=locate ------------------------------------------------ */
	} else if (strcmp(fn, "locate") == 0) {
		char *dsn = (char *) http_get_env(session->httpc,
			(const UCHAR *) "QUERY_DSN");
		LOCWORK locwork = {0};
		int loc_rc;

		if (!dsn) dsn = "SYS1.MACLIB";

		loc_rc = __locate(dsn, &locwork);

		rc = http_printf(session->httpc,
			"{ \"fn\": \"locate\", \"dsn\": \"%s\","
			" \"rc\": %d, \"volser\": \"%.6s\" }\n",
			dsn, loc_rc, locwork.volser);

	/* --- fn=help (default) ---------------------------------------- */
	} else {
		rc = http_printf(session->httpc,
			"{ \"fn\": \"help\", \"usage\": ["
			" \"?fn=listds&level=HLQ&filter=HLQ.X*\","
			" \"?fn=locate&dsn=SYS1.MACLIB\""
			" ] }\n");
	}

quit:
	return rc;
}
