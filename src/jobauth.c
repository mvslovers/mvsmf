/* JOBAUTH.C
** RACF glue for the JES spool policy (#440), see include/jobauth.h.
**
** jwn.c holds the policy and builds on the host; this file is the part that
** needs MVS: the ACEE httpd resolved for the request and racf_auth().
*/
#include <ctype.h>
#include <stdio.h>
#include <string.h>

#include <mvs/racf.h>

#include "httpcgi.h"
#include "jobauth.h"

/* racf_auth() returns SAF's own code: 0 permitted, 4 no profile, 8 denied.
 * http_check_auth() folds 4 into 0 and would make an unprotected spool look
 * open, which is the one answer this policy must not give. */
#ifdef __MVS__
__asm__("\n&FUNC	SETC 'jobauth_racf'");
#endif
static int
jobauth_racf(void *arg, const char *entity, int want_update)
{
	return racf_auth((ACEE *)arg, "JESSPOOL", entity,
			want_update ? RACF_ATTR_UPDATE : RACF_ATTR_READ);
}

void
jobauth_init(Session *session, JOBAUTH *ja)
{
	ACEE *acee = NULL;
	UCHAR *user = NULL;
	size_t i;

	memset(ja, 0, sizeof(*ja));

	if (session && session->httpc) {
		acee = http_get_acee(session->httpc);
		user = http_get_userid(session->httpc, (UCHAR *)ja->user,
				JWN_PRTSZ);
	}
	if (user) {
		for (i = 0; ja->user[i]; i++)
			ja->user[i] = (char)toupper((unsigned char)ja->user[i]);
	} else {
		ja->user[0] = '\0';
	}

	jwn_cache_init(&ja->cache);
	ja->ctx.acee_present = (acee != NULL);
	ja->ctx.user = ja->user;
	ja->ctx.auth_fn = jobauth_racf;
	ja->ctx.auth_arg = acee;
	ja->ctx.cache = &ja->cache;
}

int
jobauth_job(JOBAUTH *ja, int op, const JESJOB *job)
{
	JWN_RES res;

	if (!ja || !job)
		return JWN_HIDE;

	return jwn_check(&ja->ctx, op, (const char *)job->owner,
			(const char *)job->jobname, (const char *)job->jobid,
			&res);
}

int
jobauth_probe(JOBAUTH *ja, const char *userid)
{
	char probe[JWN_ENTSZ];
	JWN_RES res;
	int level;

	if (!ja || !ja->ctx.acee_present)
		return 0;
	if (jwn_probe(probe, sizeof(probe), userid) < 0)
		return 0;

	level = jwn_level(&ja->ctx, probe, 0, &res);
	return level >= JWN_LV_READ;
}
