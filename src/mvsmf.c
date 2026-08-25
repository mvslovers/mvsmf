#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <clibgrt.h>
#include <clibppa.h>
#include <clibcrt.h>
#include <clibwto.h>
#include <racf.h>

#include "common.h"
#include "logmw.h"
#include "mvsmfmsg.h"
#include "dsapi.h"
#include "httpcgi.h"
#include "infoapi.h"
#include "jobsapi.h"
#include "ussapi.h"
#include "consapi.h"
#include "authapi.h"
#include "testapi.h"
#include "router.h"

/* C stack size for this module, read by libc370's @@crt0/@@crt1 through the
 * WXTRN @@STKLEN (issue #290).  Without it the startup takes the default:
 * STACKLEN X'040088' + L'CLIBPPA+7, rounded down to a doubleword = 262328
 * bytes of CONTIGUOUS subpool 0 -- and httpd re-LINKs this module on every
 * single request, so that quarter megabyte is demanded per request.
 *
 * That demand is what the degradation in #287 runs into.  The address space
 * does not run out of storage; it runs out of a 262328-byte contiguous piece,
 * because concurrency episodes fence off holes of about one stack each
 * (mvslovers/httpd#195).  At 64 K the request fits in every hole that
 * mechanism produces -- a fenced-off ~256 K hole holds four of these instead
 * of none -- so the failure stops being terminal rather than merely rarer.
 *
 * 65536 + 55 rounds down to 65584 bytes actually GETMAINed.  httpd itself has
 * run on this value since long before mvsMF existed (httpd.c:22), but that is
 * its main task, not this call chain: the sizing is justified by the test
 * suites, not by httpd's precedent.  /zosmf/test?fn=storage reports the live
 * figure out of PPASTKLN, so the probe follows any change made here.
 *
 * Written by nobody: @@crt0 only loads it, so it stays legal in a RENT
 * module. */
unsigned __stklen = 64 * 1024;

/* httpd has already resolved the client credential (Basic/token) before
 * dispatching to this CGI; ACEE(0) means no credential resolved. Reject
 * here rather than trusting httpd's MOD= login flag, which today is a
 * coarse, uniform-across-CGIs bitmask (per-route policy is tracked
 * separately, see mvslovers/httpd#98) — this keeps mvsMF self-gating in
 * the meantime. */
__asm__("\n&FUNC	SETC 'identity_middleware'");
static
int identity_middleware(Session *session)
{
	ACEE *acee = http_get_acee(session->httpc);

	/* The authenticate endpoint is how a client logs in, so it must not be
	 * gated on an already-resolved credential: a bad-credential login has no
	 * ACEE and still needs to reach authLoginHandler to return the z/OSMF-
	 * shaped 401, and logout must run even once the token is gone. Let it
	 * through here (the handler inspects httpc->cred itself via the HTTPX
	 * auth export). */
	char *path = (char *) http_get_env(session->httpc,
	                                   (const UCHAR *) "REQUEST_PATH");
	if (path && strcmp(path, "/zosmf/services/authenticate") == 0) {
		return 0;
	}

	if (!acee) {
		sendDefaultHeaders(session, HTTP_STATUS_UNAUTHORIZED, HTTP_CONTENT_TYPE_NONE, 0);
		return -1;
	}

	session->old_acee = racf_set_acee(acee);
	session->acee = acee;

	return 0;
}

int main(int argc, char **argv)
{
	int irc = 0;

	CLIBPPA *ppa = __ppaget();
	CLIBGRT *grt = __grtget();
	CLIBCRT *crt = __crtget();

	void *crtapp1 = NULL;
	void *crtapp2 = NULL;

	HTTPD *httpd = grt->grtapp1;
	HTTPC *httpc = grt->grtapp2;

	Router router = {.routes = 0, .middlewares = 0};
	Session session = {.router = &router, .httpd = httpd, .httpc = httpc};

	if (!httpd) {
		wtof(MSG_NOT_UNDER_HTTPD, argv[0]);

		/* TSO callers might not see a WTO message, so we send a STDOUT message too */
		printf("This program %s must be called by the HTTPD web server\n", argv[0]);

		return 12;
	}

	/* save for our exit/external programs */
	if (crt) {
		crtapp1 = crt->crtapp1;
		crtapp2 = crt->crtapp2;
		crt->crtapp1 = httpd;
		crt->crtapp2 = httpc;
	}

	/* TODO (mig): factor this wiring out of main() into a local init helper.
	 * The original target, a local cgxstart.c, no longer exists -- the CGI
	 * launcher comes from libhttpd now and is shared by every CGI, so mvsMF's
	 * own router setup cannot move there. */
	init_router(&router);
	init_session(&session, &router, httpd, httpc);

	add_middleware(&router, "Authentication", identity_middleware);

#if 0
	add_middleware(&router, "Logging", logging_middleware);
#endif

	/* add the URL mappings */
	add_route(&router, GET, "/zosmf/info", infoHandler);

	/* /zosmf/test is the diagnostic endpoint, and the boundary that decides
	   whether a deployment has one is HERE, not inside its functions (#343).
	   It carries fn=cmd (operator commands via SVC 34 in supervisor state),
	   fn=abend and fn=denyopen; a runtime flag on some of those guarded the
	   weakest of them while the strongest never had one. Building with
	   -DMVSMF_NO_TEST_ENDPOINT leaves the routes unregistered, so the whole
	   surface answers 404 and the code behind it is unreachable.

	   The default is ON deliberately: fn=version is the documented way to
	   confirm which build a deploy actually activated, and fn=storage is the
	   storage instrument -- a hardened build gives both up knowingly. */
#ifndef MVSMF_NO_TEST_ENDPOINT
	add_route(&router, GET, "/zosmf/test", testHandler);
	add_route(&router, GET, "/zosmf/test/wildcard/{*filepath}", testWildcardHandler);
#endif

	add_route(&router, POST, "/zosmf/services/authenticate", authLoginHandler);
	add_route(&router, DELETE, "/zosmf/services/authenticate", authLogoutHandler);

	add_route(&router, GET, "/zosmf/restjobs/jobs", jobListHandler);
	add_route(&router, GET, "/zosmf/restjobs/jobs/{job-name}/{jobid}/files", jobFilesHandler);
	add_route(&router, GET, "/zosmf/restjobs/jobs/{job-name}/{jobid}/files/{ddid}/records", jobRecordsHandler);
	add_route(&router, PUT, "/zosmf/restjobs/jobs", jobSubmitHandler);
	add_route(&router, GET, "/zosmf/restjobs/jobs/{job-name}/{jobid}", jobStatusHandler);
	add_route(&router, DELETE, "/zosmf/restjobs/jobs/{job-name}/{jobid}", jobPurgeHandler);

	add_route(&router, GET, "/zosmf/restfiles/ds", datasetListHandler);
	add_route(&router, GET, "/zosmf/restfiles/ds/{dataset-name}", datasetGetHandler);
	add_route(&router, PUT, "/zosmf/restfiles/ds/{dataset-name}", datasetPutHandler);
	add_route(&router, POST, "/zosmf/restfiles/ds/{dataset-name}", datasetCreateHandler);
	add_route(&router, DELETE, "/zosmf/restfiles/ds/{dataset-name}", datasetDeleteHandler);
	add_route(&router, GET, "/zosmf/restfiles/ds/{dataset-name}/member", memberListHandler);
	add_route(&router, GET, "/zosmf/restfiles/ds/{dataset-name}({member-name})", memberGetHandler);
	add_route(&router, PUT, "/zosmf/restfiles/ds/{dataset-name}({member-name})", memberPutHandler);
	add_route(&router, DELETE, "/zosmf/restfiles/ds/{dataset-name}({member-name})", memberDeleteHandler);

	/* The seven -({volume-serial}) routes are withdrawn, not implemented
	   (#336).  They used to be registered here pointing at the same handlers
	   as the cataloged forms, and no handler ever read HTTP_volume-serial:
	   the operand was captured and discarded, so a request naming the wrong
	   volume was answered as if it had named the right one.  Accepting the
	   syntax and ignoring it is worse than not offering it, because the
	   answer looks correct.

	   Withdrawing them is safe to do by deletion alone: {dataset-name} stops
	   at '/', '(' and ')' (is_pattern_match(), router.c), so "-(VOL)/X.Y"
	   matches none of the cataloged patterns above and falls through to the
	   router's 404.  It cannot be silently served as a data set literally
	   named "-(VOL)".

	   Restoring them needs more than uncommenting.  The read and write half
	   is ours: allocate naming the volume (__dsalcf with VOLSER=) and open
	   the DD (fopen("DD:ddname")), with __listvl() resolving the volser to a
	   device if UNIT turns out to be required.  DELETE and rename are not:
	   remove() and rename() reach a data set through the catalog only, and
	   there is no volume-addressed SCRATCH/RENAME in libc370 to call instead
	   -- mvslovers/libc370#143.  Routing those through IDCAMS would
	   reintroduce the SYSDSN ENQ escalation of #342.

	   The catalog-based diagnosis in dsapi.c (why_open_failed(),
	   dataset_cataloged()) has to move to OBTAIN-by-volume on these routes
	   as well, or an uncataloged data set comes back with the wrong reason
	   for its 404. */

	add_route(&router, GET, "/zosmf/restfiles/fs", ussListHandler);
	add_route(&router, PUT, "/zosmf/restconsoles/consoles/{console-name}", consoleIssueHandler);
	add_route(&router, GET, "/zosmf/restconsoles/consoles/{console-name}/solmsgs/{cmd-response-key}", consoleCollectHandler);
	add_route(&router, GET, "/zosmf/restconsoles/consoles/{console-name}/detections/{detection-key}", consoleDetectHandler);
	add_route(&router, GET, "/zosmf/restconsoles/v1/log", consoleLogHandler);

	add_route(&router, GET, "/zosmf/restfiles/fs/{*filepath}", ussGetHandler);
	add_route(&router, PUT, "/zosmf/restfiles/fs/{*filepath}", ussPutHandler);
	add_route(&router, POST, "/zosmf/restfiles/fs/{*filepath}", ussCreateHandler);
	add_route(&router, DELETE, "/zosmf/restfiles/fs/{*filepath}", ussDeleteHandler);

	/* dispatch the request */
	irc = handle_request(&router, &session);

quit:

	/* The ACEE belongs to httpd's credential store now (reused across
	 * requests by token) — restore the prior task ACEE, don't log it out. */
	if (session.acee) {
		racf_set_acee(session.old_acee);
		session.acee = NULL;
		session.old_acee = NULL;
	}

	/* restore crt values */
	if (crt) {
		crt->crtapp1 = crtapp1;
		crt->crtapp2 = crtapp2;
	}

	return 0;
}

