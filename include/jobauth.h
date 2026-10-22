#ifndef JOBAUTH_H
#define JOBAUTH_H

/**
 * @file jobauth.h
 * @brief RACF glue for the JES spool policy (#440)
 *
 * jwn.h decides; this file asks.  One JOBAUTH lives on the stack of a request
 * handler and carries the caller's ACEE, userid and the answers RACF has
 * already given for that request.  See internals/authorization.md.
 */

#include <mvs/jes2.h>

#include "jwn.h"
#include "router.h"

typedef struct jobauth {
	JWN_CTX		ctx;
	JWN_CACHE	cache;
	char		user[JWN_PRTSZ + 8];	/* the caller, upper case */
} JOBAUTH;

/* Takes the ACEE and the userid httpd resolved for this request.  Without
 * either the policy hides every job. */
void jobauth_init(Session *session, JOBAUTH *ja)	asm("JOBAINIT");

/* The decision (JWN_HIDE, JWN_ALLOW, JWN_NOPURGE) for op on job, judged on the
 * job's own owner, name and id and never on what the request said. */
int jobauth_job(JOBAUTH *ja, int op, const JESJOB *job)	asm("JOBAJOB");

/* 1 if the caller has at least READ on the owner probe "<userid>.." (".." for
 * all owners), 0 otherwise.  userid "" asks for all owners. */
int jobauth_probe(JOBAUTH *ja, const char *userid)	asm("JOBAPROB");

#endif /* JOBAUTH_H */
