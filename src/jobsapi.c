#include <clibary.h>
#include <clibb64.h>
#include <clibio.h>
#include <clibstr.h>
#include <ctype.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <clibjes2.h>
#include <clibthrd.h>
#include <clibtry.h>
#include <clibvsam.h>
#include <clibwto.h>
#include <time64.h>

#include "common.h"
#include "httpcgi.h"
#include "jclines.h"
#include "jobsapi.h"
#include "jobsapi_msg.h"
#include "mvsmfmsg.h"
#include "json.h"
#include "router.h"

#define INITIAL_BUFFER_SIZE 4096
#define MAX_JOBS_LIMIT 1000
#define MAX_URL_LENGTH 256
#define MAX_ERR_MSG_LENGTH 256
#define INITIAL_JCL_CAPACITY 256

#define JES_INFO_SIZE   20 + 1
#define TYPE_STR_SIZE    3 + 1
#define CLASS_STR_SIZE   3 + 1
/* room for the longest status job_status_str() reports ("RECEIVE") plus slack:
   a requested value long enough to be truncated here is 15 characters and can
   never equal one of them, so truncation can only mean "matches nothing". */
#define STATUS_STR_SIZE 16
#define RECFM_STR_SIZE   4 + 1
#define JOBNAME_STR_SIZE 8      // the +1 for null termination will be added on initialization
#define JOBID_STR_SIZE   8      // the +1 for null termination will be added on initialization
#define DSNAME_STR_SIZE  44     // the +1 for null termination will be added on initialization

/* process_jobcard() failure codes. Both are reported as 400, but with
   different messages: the two conditions were indistinguishable to the client
   before, and a card that is merely too long read as one with no JOB statement
   at all (#130). Success returns the new line count, which is always > 0. */
#define JOBCARD_ERR_NO_CARD		(-1)	/* no JOB statement in the input */
#define JOBCARD_ERR_TOO_LONG	(-2)	/* rewritten card exceeds 72 columns */

#define MIN(a,b) ((a) < (b) ? (a) : (b))

#define MIN_JES_SYSOUT_DSID 	  2
#define MAX_JES_SYSOUT_DSID 	  4
#define MIN_USER_SYSOUT_DSID 	100
#define MAX_USER_SYSOUT_DSID 	199

/* an ISO 8601 instant with a millisecond fraction: 2018-11-03T09:05:18.010Z */
#define EXEC_TIME_STR_SIZE	(24 + 1)

/* libc370 ships __tzget() (src/clib/@@tzget.c) but declares it in no header;
   httpd carries the same local declaration in src/httpjes2.c. */
extern int __tzget(void);

//
// private functions prototypes
//

/* TODO (MIG) refactor sysout stuff*/
static int  do_print_sysout(Session *session, JESJOB *job, unsigned dsid);

// needed by jobListHandler
static void process_job_list_filters(Session *session, const char **filter, JESFILT *jesfilt,
                                     char *status, size_t status_size);
static unsigned get_max_jobs(Session *session);
static int  want_exec_data(Session *session);
static const char* format_exec_time(const time64_t *t, int tzadjust, char *out, size_t outlen);
static const char* job_status_str(const JESJOB *job);
static int  process_job(JsonBuilder *builder, JESJOB *job, const char *owner, const char *status,
                        const char *host, const char *scheme, int exec_data);
static JESJOB* find_job_by_name_and_id(Session *session, const char *jobname, const char *jobid, JESJOB ***out_joblist);
static int process_job_files(Session *session, JESJOB *job, const char *host, JsonBuilder *builder);
static int validate_intrdr_headers(Session *session);
static int open_intrdr(Session *session, VSFILE **intrdr);
static int submit_jcl_content(Session *session, VSFILE *intrdr, const char *content, size_t content_length, 
                              char *jobname, char *jobid, char *jobclass);
static const char *extract_file_value(char *json, size_t len);
static int submit_file(Session *session, VSFILE *intrdr, const char *filename,
                       char *jobname, char *jobid, char *jobclass);
static char* tokenize(char *str, const char *delim, char **saveptr);
static int process_jobcard(char **lines, int num_lines, char *jobname, char *jobclass,
                          const char *user, const char *password);
static char *find_notify_operand(char *line);
static int get_caller_credentials(Session *session, char *user, size_t user_len,
                                  char *password, size_t password_len);

static const unsigned char ASCII_CRLF[] = {CR, LF};

//
// private function prototypes
//

static int send_job_status_response(Session *session, JESJOB *job, const char *host);
static int find_and_send_job_status(Session *session, const char *jobname, const char *jobid, const char *host);

//
// public functions
//

int 
jobListHandler(Session *session) 
{
	int rc = 0;
	
	JES *jes = NULL;
	JESJOB **joblist = NULL;
	HASPCP *cp = NULL;
	JESFILT jesfilt = FILTER_NONE;
	const char *filter = NULL;

	JsonBuilder *builder = createJsonBuilder();

	if (!builder) {
		sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
						CATEGORY_UNEXPECTED, RC_SEVERE, REASON_SERVER_ERROR,
						ERR_MSG_SERVER_ERROR, NULL, 0);
		goto quit;
	}

	const char *host = getHeaderParam(session, "HOST");
	const char *owner = getQueryParam(session, "owner");
	const unsigned max_jobs = get_max_jobs(session);
	UCHAR ownerid[64];
	/* MVSMF is link-edited RENT, so the normalized status stays on the stack */
	char status[STATUS_STR_SIZE];

	if (owner == NULL) {
		/* z/OSMF default: jobs owned by the caller, from the identity
		 * httpd already resolved (mvslovers/httpd#99), not env vars. */
		owner = (const char *)http_get_userid(session->httpc, ownerid, sizeof(ownerid));
	}

	if (owner && owner[0] == '*') {
		owner = NULL;
	}

	process_job_list_filters(session, &filter, &jesfilt, status, sizeof(status));

	jes = jesopen();
	session_register_jes(session, jes);
	if (!jes) {
		wtof(MSG_JES_UNAVAILABLE);
		sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR, CATEGORY_VSAM,
						RC_SEVERE, REASON_INCORRECT_JES_VSAM_HANDLE,
						ERR_MSG_INCORRECT_JES_VSAM_HANDLE, NULL, 0);
		goto quit;
	}

	joblist = jesjob(jes, filter, jesfilt, 0);

	startArray(builder);

	const int exec_data = want_exec_data(session);
	/* hoisted out of the loop: one env lookup for the whole job list */
	const char *scheme = getRequestScheme(session);

	/* max-jobs caps the jobs *returned*, not the queue entries looked at: with
	   a status or owner filter in play the first max_jobs entries of the spool
	   are mostly rows this request does not want, and capping the scan would
	   answer "no ACTIVE jobs" for a system that has them (issue #157). */
	unsigned emitted = 0;
	unsigned ii = 0;
	for (ii = 0; ii < array_count(&joblist) && emitted < max_jobs; ii++) {
		rc = process_job(builder, joblist[ii], owner,
						status[0] ? status : NULL, host, scheme, exec_data);
		if (rc < 0) {
			goto quit;
		}
		emitted += (unsigned)rc;
	}

	endArray(builder);

	sendJSONResponse(session, HTTP_STATUS_OK, builder);

quit:
	if (joblist) {
		jesjobfr(&joblist);
	}

	if (builder) {
		freeJsonBuilder(builder);
	}

	session_jesclose(session, &jes);

	return 0;
}

int
jobFilesHandler(Session *session)
{
	int rc = 0;

	JESJOB *job = NULL;
	JESJOB **joblist = NULL;

	JsonBuilder *builder = createJsonBuilder();
	
	if (!builder) {
		sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
						CATEGORY_UNEXPECTED, RC_SEVERE, REASON_SERVER_ERROR,
						ERR_MSG_SERVER_ERROR, NULL, 0);
		goto quit;
	}

	const char *host = getHeaderParam(session, "HOST");

	const char *jobname = getPathParam(session, "job-name");
	const char *jobid   = getPathParam(session, "jobid");

	if (!jobname || !jobid) {
		sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
						CATEGORY_UNEXPECTED, RC_SEVERE, REASON_SERVER_ERROR,
						ERR_MSG_SERVER_ERROR, NULL, 0);
		goto quit;
	}

	job = find_job_by_name_and_id(session, jobname, jobid, &joblist);
	if (!job) {
		char msg[MAX_ERR_MSG_LENGTH] = {0};
		rc = snprintf(msg, sizeof(msg), ERR_MSG_JOB_NOT_FOUND, jobname, jobid);
		if (rc >= 0) {
			sendErrorResponse(session, HTTP_STATUS_NOT_FOUND, CATEGORY_SERVICE,
							RC_WARNING, REASON_JOB_NOT_FOUND,
							msg, NULL, 0);
		}
		goto quit;
	}

	startArray(builder);

	rc = process_job_files(session, job, host, builder);
	if (rc < 0) {
		goto quit;
	}

	endArray(builder);

	sendJSONResponse(session, HTTP_STATUS_OK, builder);

quit:
	if (joblist) {
		jesjobfr(&joblist);
	}

	if (builder) {
		freeJsonBuilder(builder);
	}

	return 0;
}

int 
jobRecordsHandler(Session *session)
{
	int rc = 0;

	JESJOB *job = NULL;
	JESJOB **joblist = NULL;

	const char *jobname = getPathParam(session, "job-name");
	const char *jobid = getPathParam(session, "jobid");
	const char *ddid = getPathParam(session, "ddid");

	if (!jobname || !jobid || !ddid) {
		sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR, CATEGORY_UNEXPECTED,
						RC_SEVERE, REASON_SERVER_ERROR, ERR_MSG_SERVER_ERROR, 
						NULL, 0);
		return rc;
	}

	job = find_job_by_name_and_id(session, jobname, jobid, &joblist);
	if (!job) {
		char msg[MAX_ERR_MSG_LENGTH] = {0};
		rc = snprintf(msg, sizeof(msg), ERR_MSG_JOB_NOT_FOUND, jobname, jobid);
		sendErrorResponse(session, HTTP_STATUS_NOT_FOUND, CATEGORY_SERVICE,
						RC_WARNING, REASON_JOB_NOT_FOUND,
						msg, NULL, 0);
		goto quit;
	}

	{
		char *endptr = NULL;
		long ddid_val = strtol(ddid, &endptr, DECIMAL_BASE);

		if (*endptr != '\0' || ddid_val < 0) {
			sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST, CATEGORY_SERVICE,
							RC_ERROR, REASON_INVALID_QUERY,
							"Invalid DDID parameter", NULL, 0);
			goto quit;
		}

		/* verify DDID exists in job's spool files */
		{
			unsigned ii = 0;
			int found = 0;
			for (ii = 0; ii < array_count(&job->jesdd); ii++) {
				JESDD *dd = job->jesdd[ii];
				if (dd && dd->dsid == (unsigned)ddid_val) {
					found = 1;
					break;
				}
			}
			if (!found) {
				sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST, CATEGORY_SERVICE,
								RC_ERROR, REASON_INVALID_QUERY,
								"DDID not found for job", NULL, 0);
				goto quit;
			}
		}

		/* do_print_sysout() owns the response from here on: it holds the
		   headers back until the first spool line is ready, so an outcome
		   with no output at all can still answer 404 or 500 (issue #187,
		   status revised in #250) */
		rc = do_print_sysout(session, job, (unsigned)ddid_val);
		if (rc < 0) {
			goto quit;
		}
	}

quit:
	if (joblist) {
		jesjobfr(&joblist);
	}

	return 0;
}

int 
jobStatusHandler(Session *session) 
{
	const char *host = getHeaderParam(session, "HOST");
	const char *jobname = getPathParam(session, "job-name");
	const char *jobid = getPathParam(session, "jobid");

	find_and_send_job_status(session, jobname, jobid, host);	

	return 0;
}

int
jobPurgeHandler(Session *session)
{
	int rc = 0;

	const char *jobname = getPathParam(session, "job-name");
	const char *jobid = getPathParam(session, "jobid");

	JESJOB *job = NULL;
	JESJOB **joblist = NULL;
	JsonBuilder *builder = createJsonBuilder();
	char owner[JOBNAME_STR_SIZE + 1] = {0};

	if (!jobname || !jobid) {
		sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST, CATEGORY_UNEXPECTED,
						  RC_SEVERE, REASON_SERVER_ERROR, ERR_MSG_SERVER_ERROR,
						  NULL, 0);
		goto quit;
	}

	/* Resolve the job before purging it. Two reasons (issue #190):
	   - it is the only chance to read the owner, which the purge feedback
	     document carries and which is gone once the job is;
	   - it answers "no such job" the way the status and files handlers do.
	     jescanj() alone cannot: a jobid JES2 rejects as malformed - anything
	     outside JOB00001-JOB09999 on 3.8j, e.g. JOB99999 - comes back as
	     CANJ_SYNTX, which used to fall through to a 500. */
	job = find_job_by_name_and_id(session, jobname, jobid, &joblist);
	if (!job) {
		char msg[MAX_ERR_MSG_LENGTH] = {0};
		snprintf(msg, sizeof(msg), ERR_MSG_JOB_NOT_FOUND, jobname, jobid);
		sendErrorResponse(session, HTTP_STATUS_NOT_FOUND, CATEGORY_SERVICE,
						RC_WARNING, REASON_JOB_NOT_FOUND,
						msg, NULL, 0);
		goto quit;
	}

	/* copy it out now - the job the pointer describes is about to be purged */
	snprintf(owner, sizeof(owner), "%.8s", (char *) job->owner);

	rc = jescanj(jobname, jobid, 1);

	switch (rc) {
	case CANJ_OK:
		rc = startJsonObject(builder);

		rc = addJsonString(builder, "jobid", jobid);
		rc = addJsonString(builder, "message", "Request was successful.");
		rc = addJsonString(builder, "original-jobid", jobid);
		rc = addJsonString(builder, "jobname", jobname);
		rc = addJsonString(builder, "owner", owner);
		rc = addJsonNumber(builder, "status", 0);

		rc = endJsonObject(builder);
		if (rc < 0) {
			goto quit;
		}

		sendJSONResponse(session, HTTP_STATUS_OK, builder);

		break;
	case CANJ_NOJB:
	case CANJ_BADI:
	case CANJ_SYNTX:
		/* the lookup above found it, so this is a job that went away between
		   the two calls - still "not found" from the client's side */
		{
			char msg[MAX_ERR_MSG_LENGTH] = {0};
			snprintf(msg, sizeof(msg), ERR_MSG_JOB_NOT_FOUND, jobname, jobid);
			sendErrorResponse(session, HTTP_STATUS_NOT_FOUND, CATEGORY_SERVICE,
							RC_WARNING, REASON_JOB_NOT_FOUND,
							msg, NULL, 0);
		}
		break;
	case CANJ_ICAN:
		/* Refusing to purge a started task. This answered 403 until #250; that
		   is not a z/OSMF status, and the refusal is about what was asked for
		   rather than about who asked, so 400 is the honest code. REASON_STC_PURGE
		   is what tells the client which refusal this is. */
		sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST, CATEGORY_SERVICE,
							RC_WARNING, REASON_STC_PURGE, ERR_MSG_STC_PURGE,
							NULL, 0);
		break;
	default:
		wtof(MSG_JESCANJ_RC, rc);
		sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR, CATEGORY_UNEXPECTED,
							RC_SEVERE, REASON_SERVER_ERROR, ERR_MSG_SERVER_ERROR,
							NULL, 0);
		break;
	}

quit:
	if (joblist) {
		jesjobfr(&joblist);
	}

	if (builder) {
		freeJsonBuilder(builder);
	}

	return 0;
}

int jobSubmitHandler(Session *session)
{
	int rc = 0;

	VSFILE *intrdr = NULL;

	char *data = NULL;
	size_t data_size = 0;
	char jobname[JOBNAME_STR_SIZE + 1];
	char jobid[JOBID_STR_SIZE + 1];
	char jobclass = 'A';

	/* validate internal reader headers */
	rc = validate_intrdr_headers(session);
	if (rc < 0) {
		sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST, CATEGORY_SERVICE,
						RC_ERROR, REASON_INVALID_QUERY,
						"Invalid internal reader parameters", NULL, 0);
		goto quit;
	}

	/* read request content */
	rc = read_request_content(session, &data, &data_size);
	if (rc < 0) {
		sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST, CATEGORY_SERVICE,
						RC_ERROR, REASON_INVALID_REQUEST,
						"Failed to read request content", NULL, 0);
		goto quit;
	}

	/* dispatch based on Content-Type */
	{
		const char *content_type = getHeaderParam(session, "Content-Type");
		int is_json = (content_type && strstr(content_type, "application/json") != NULL);
		int is_text = (!content_type || strstr(content_type, "text/plain") != NULL);

		if (!is_json && !is_text) {
			sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST, CATEGORY_SERVICE,
							RC_ERROR, REASON_INVALID_REQUEST,
							"Unsupported Content-Type for job submission. "
							"Use application/json or text/plain", NULL, 0);
			rc = -1;
			goto quit;
		}

		if (is_json) {
			/* convert ASCII request body to EBCDIC (CP037) so strstr/strchr work */
			http_xlate((unsigned char *)data, data_size, httpx->xlate_cp037->atoe);

			/* JSON body: extract file reference and submit from dataset */
			{
				const char *file_value = extract_file_value(data, data_size);
				if (!file_value || file_value[0] == '\0') {
					sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST, CATEGORY_SERVICE,
									RC_ERROR, REASON_MISSING_FILE_FIELD,
									ERR_MSG_MISSING_FILE_FIELD, NULL, 0);
					rc = -1;
					goto quit;
				}

				if (open_intrdr(session, &intrdr) < 0) {
					rc = -1;
					goto quit;
				}

				/* file_value is already EBCDIC after atoe conversion */
				rc = submit_file(session, intrdr, file_value,
								jobname, jobid, &jobclass);
			}
			intrdr = NULL; /* submit_file handles intrdr lifecycle */

			if (rc < 0) {
				goto quit;
			}
		} else {
			/* text/plain or absent: inline JCL submission */
			if (open_intrdr(session, &intrdr) < 0) {
				rc = -1;
				goto quit;
			}

			rc = submit_jcl_content(session, intrdr, data, data_size,
									jobname, jobid, &jobclass);
			intrdr = NULL; /* submit_jcl_content handles intrdr lifecycle */
			if (rc < 0) {
				goto quit;
			}
		}
	}

	{
		const char *host = getHeaderParam(session, "HOST");
		rc = find_and_send_job_status(session, jobname, jobid, host);
	}

quit:
	if (intrdr) {
		jesircls(intrdr);
	}
	if (data) {
		free(data);
	}
	return rc;
}

//
// private functions
//

/*
 * Line cap for SYSIN spool datasets (issue #158): JES2 pre-formats the
 * "JOB DELETED BY JES2 OR CANCELLED BY OPERATOR BEFORE EXECUTION" line
 * into the JCLIN spool chain behind the real records - it is only meant
 * to be printed when a job dies before execution. jesprint() walks the
 * block chain to the EOB marker, so without a cap that line leaks into
 * every response. SYSIN record counts are final after input processing,
 * so capping at the PDDB count is exact; SYSOUT datasets stay uncapped
 * (their counts may lag while a job is active).
 *
 * The cap and the response target travel to the per-line callback in this
 * context struct, handed straight through jesprint()'s arg (libc370 #21/#22,
 * issue #187). Before that signature existed the cap had to ride the per-task
 * GRT, because the callback took no argument of its own.
 */
typedef struct spool_ctx {
	Session		*session;	/* response target, and the httpx anchor   */
	unsigned	limit;		/* cap for the current dd (0 = no cap)     */
	unsigned	count;		/* lines printed from the current dd       */
	unsigned	total;		/* lines printed from all dds so far       */
} SPOOL_CTX;

#define RC_SPOOL_CAP	(-77)	/* sentinel: cap reached, normal end */

/*
 * Why jesprint() stopped walking the block chain, in the terms this endpoint
 * has to answer in. An ordinary end returns NULL; everything else names a
 * condition the caller either reports as an error or logs as truncation.
 *
 * END and EMPTY are ordinary ends, and so is OPENEND: a data set that is
 * still being written ends on a block whose chain points at a track that is
 * allocated but not yet written, so that track carries a foreign key. Every
 * running job reads that way - answering "gone" there would throw away output
 * that was just read correctly (measured in libc370 #31: 350 and 3170 lines
 * before the foreign block).
 *
 * FOREIGN needs the PDDB record count to be read correctly. It means the very
 * first block was already foreign, so nothing was read at all - but that alone
 * does not prove a loss: a data set nobody ever wrote to points at an
 * allocated-but-unwritten track just the same, and with no accepted block in
 * front of it libc370 cannot call that OPENEND. Only a non-zero record count
 * makes it a loss: the checkpoint promises records the spool no longer holds,
 * because JES2 printed and purged the data set and reallocated its tracks.
 */
__asm__("\n&FUNC	SETC 'do_print_sysout_why'");
static const char *
do_print_sysout_why(int prc, const JESPRST *st, unsigned records)
{
	/* jesprint() rejected the request before the walk started: since libc370
	   #26 its rc is a status and nothing else - 0 when the walk ran, 404 for
	   an unknown dsid, 503 when JES2 is unusable.  Why a walk that DID run
	   ended is st->reason, below.                                          */
	if (prc > 0) {
		return "JES2 checkpoint or spool data set not available";
	}

	switch (st->reason) {
	case JESPR_IOERR:	return "spool read failed";
	case JESPR_FOREIGN:	return records ? "no longer on the spool" : NULL;
	case JESPR_DSID:	return "first spool block belongs to another data set";
	case JESPR_LOOP:	return "spool block chain loops, output truncated";
	case JESPR_CAP:		return "spool block limit reached, output truncated";
	case JESPR_NOBUF:	return "incomplete spanned record, output truncated";
	case JESPR_NOMEM:	return "out of storage, output truncated";
	}

	return NULL;
}

/* HTTP status for an outcome that produced no output at all.
 *
 * The purged case answers 404, not the 410 Gone it used to (#187, reversed in
 * #250). 410 said more -- the checkpoint promised records the spool no longer
 * holds, which is a loss rather than a wrong DD name -- but it is not one of
 * the status codes z/OSMF uses, and a measurement of the reference settled
 * that the list is kept even where a nicer code exists: real z/OSMF answers a
 * missing job 400, never 404, rather than reaching outside its own set.
 *
 * Nothing is lost by the client that reads the body: REASON_SPOOL_GONE and
 * ERR_MSG_SPOOL_GONE still separate this from an ordinary miss, and they were
 * always where the detail lived. See do_print_sysout_why(). */
__asm__("\n&FUNC	SETC 'do_print_sysout_status'");
static int
do_print_sysout_status(int prc, const JESPRST *st, unsigned records)
{
	if (prc > 0) {
		return HTTP_STATUS_INTERNAL_SERVER_ERROR;
	}

	if (st->reason == JESPR_FOREIGN && records) {
		return HTTP_STATUS_NOT_FOUND;
	}

	return do_print_sysout_why(prc, st, records)
		? HTTP_STATUS_INTERNAL_SERVER_ERROR : HTTP_STATUS_OK;
}

__asm__("\n&FUNC	SETC 'do_print_sysout_line'");
static int
do_print_sysout_line(const char *line, unsigned linelen, void *arg)
{
	SPOOL_CTX *ctx = (SPOOL_CTX *) arg;
	Session *session = ctx->session;	/* the httpx macro reads session->httpd */
	int rc = 0;

	/* logical end of the dataset reached - stop jesprint */
	if (ctx->limit && ctx->count >= ctx->limit) {
		return RC_SPOOL_CAP;
	}

	/* headers are held back until there is something to send, so that an
	   outcome with no output at all can still pick its own status */
	if (!session->headers_sent) {
		rc = sendDefaultHeaders(session, HTTP_STATUS_OK, "text/plain", 0);
		if (rc < 0) {
			return rc;
		}
	}

	rc = http_printf(session->httpc, "%-*.*s\r\n", linelen, linelen, line);

	if (rc >= 0) {
		ctx->count++;
		ctx->total++;
	}

	return rc;
}

/*
 * Streams one spool dataset (dsid) and owns the whole response for it: the
 * 200 headers are emitted by the callback on the first line, so an outcome
 * that never produces a line can still answer 404 or 500 instead of an empty
 * 200 (issue #187). Once a line has gone out the status is committed - a walk
 * that then goes wrong is logged for the operator, not turned into an error
 * body, because the records already sent are valid.
 */
__asm__("\n&FUNC	SETC 'do_print_sysout'");
static int
do_print_sysout(Session *session, JESJOB *job, unsigned dsid)
{
	int rc = 0;
	int prc = 0;
	int status = HTTP_STATUS_OK;
	unsigned bad_dsid = 0;
	const char *bad_why = NULL;
	char msg[MAX_ERR_MSG_LENGTH] = {0};
	SPOOL_CTX ctx;
	JESPRST st;

	JES *jes = jesopen();
	session_register_jes(session, jes);
	if (!jes) {
		wtof(MSG_JES_UNAVAILABLE);
		sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
						CATEGORY_SERVICE, RC_SEVERE, REASON_INCORRECT_JES_VSAM_HANDLE,
						ERR_MSG_INCORRECT_JES_VSAM_HANDLE, NULL, 0);
		rc = -1;
		goto quit;
	}

	ctx.session = session;
	ctx.limit = 0;
	ctx.count = 0;
	ctx.total = 0;

	unsigned ii = 0;
	for (ii = 0; ii < array_count(&job->jesdd); ii++) {
		JESDD *dd = job->jesdd[ii];
		const char *why = NULL;

		if (!dd) {
			continue;
		}

		if (dd->dsid != dsid) {
			continue;
		}

		/* no spool data for this dd */
		if (!dd->mttr) {
			continue;
		}

		if ((dd->flag & FLAG_SYSIN) && !dsid) {
			continue;
		}

		/* dashed separator between dds that produced output - never leading,
		   never trailing */
		if (ctx.total) {
			rc = http_printf(session->httpc, "- - - - - - - - - - - - - - - - - - - - "
											"- - - - - - - - - - - - - - - - - - - - "
											"- - - - - - - - - - - - - - - - - - - - "
											"- - - - - -\r\n");
			if (rc < 0) {
				goto quit;
			}
		}

		/* cap SYSIN datasets at their (final) PDDB record count so the
		   pre-built JES2 deletion line behind the records stays hidden */
		ctx.limit = ((dd->flag & FLAG_SYSIN) && dd->records) ? dd->records : 0;
		ctx.count = 0;

		prc = jesprint(jes, job, dd->dsid, do_print_sysout_line, &ctx, &st);

		/* Since libc370 #26 prc is a status (0/404/503) and no longer carries
		   the print callback's rc: a callback that stopped the walk arrives as
		   JESPR_STOPPED with its own rc in st.prtrc.  RC_SPOOL_CAP is our
		   sentinel for "capped at the PDDB record count", which is a normal
		   end of the data set - anything else means the callback gave up.
		   Reading st also works against a pre-#26 libc370, which additionally
		   returned that rc in prc.                                          */
		if (st.reason == JESPR_STOPPED && st.prtrc != RC_SPOOL_CAP) {
			/* the callback gave up: the socket is gone, nothing to answer */
			rc = st.prtrc;
			goto quit;
		}
		if (prc < 0) {
			prc = 0;	/* pre-#26 libc370: the callback's rc, handled above */
		}

		/* remember the first abnormal outcome; it decides the status only if
		   no dd ends up producing any output */
		why = do_print_sysout_why(prc, &st, dd->records);
		if (why && !bad_why) {
			bad_why  = why;
			bad_dsid = dd->dsid;
			status   = do_print_sysout_status(prc, &st, dd->records);
		}
	}

	/* output went out - the response is committed to 200, so an outcome that
	   truncated it can only be reported to the operator. The no-output cases
	   need no console message: the error body below says the same thing, and
	   a purged dataset that a client polls would flood the log. */
	if (ctx.total) {
		if (bad_why) {
			wtof(MSG_SPOOL_WALK, (char *) job->jobname,
				(char *) job->jobid, bad_dsid, bad_why);
		}
		rc = 0;
		goto quit;
	}

	/* The purged case. do_print_sysout_status() returns only OK, NOT_FOUND and
	   INTERNAL_SERVER_ERROR, so NOT_FOUND identifies it unambiguously -- and
	   REASON_SPOOL_GONE is what tells a client this was a loss rather than a
	   name it got wrong, now that the status no longer does (#250). */
	if (status == HTTP_STATUS_NOT_FOUND) {
		snprintf(msg, sizeof(msg), ERR_MSG_SPOOL_GONE,
				(char *) job->jobname, (char *) job->jobid, bad_dsid);
		rc = sendErrorResponse(session, HTTP_STATUS_NOT_FOUND, CATEGORY_SERVICE,
						RC_WARNING, REASON_SPOOL_GONE, msg, NULL, 0);
		goto quit;
	}

	if (status != HTTP_STATUS_OK) {
		snprintf(msg, sizeof(msg), ERR_MSG_SPOOL_READ,
				(char *) job->jobname, (char *) job->jobid, bad_dsid, bad_why);
		rc = sendErrorResponse(session, status, CATEGORY_SERVICE,
						RC_ERROR, REASON_SPOOL_READ, msg, NULL, 0);
		goto quit;
	}

	/* nothing was written and nothing went wrong: an empty spool dataset */
	rc = sendDefaultHeaders(session, HTTP_STATUS_OK, "text/plain", 0);

quit:
	session_jesclose(session, &jes);

	return rc;
}

/* Reads the list filters off the query string.  prefix/jobid become the JES
   filter the checkpoint scan itself understands; status has no JES2 equivalent
   and is returned normalized (upper case, "" when absent or "*") for
   should_skip_job() to compare against each job's reported status. */
__asm__("\n&FUNC	SETC 'process_job_list_filters'");
static void
process_job_list_filters(Session *session, const char **filter, JESFILT *jesfilt,
						char *status, size_t status_size)
{
	const char *prefix     = getQueryParam(session, "prefix");
	const char *req_status = getQueryParam(session, "status");
	const char *jobid      = getQueryParam(session, "jobid");

	if (prefix && prefix[0] == '*') {
		prefix = NULL;
	}

	if (req_status && req_status[0] == '*') {
		req_status = NULL;
	}

	if (status && status_size > 0) {
		size_t ii = 0;

		if (req_status) {
			while (ii < status_size - 1 && req_status[ii] != '\0') {
				status[ii] = (char)toupper((unsigned char)req_status[ii]);
				ii++;
			}
		}
		status[ii] = '\0';
	}

	if (prefix && !jobid) {
		*filter = prefix;
		*jesfilt = FILTER_JOBNAME;
	} else if (jobid) {
		*filter = jobid;
		*jesfilt = FILTER_JOBID;
	} else {
		*filter = "";
		*jesfilt = FILTER_NONE;
	}
}

__asm__("\n&FUNC	SETC 'should_skip_job'");
static int
should_skip_job(const JESJOB *job, const char *owner, const char *status)
{
	if (!job) {
		return 1;
	}

 	// skip job if owner is empty or does not match given owner
	if (owner) {
		if (job->owner[0] == '\0') {
			return 1;  
		}
		if (strncmp((const char *)job->owner, owner,
					MIN(strlen((const char *)job->owner), strlen(owner))) != 0) {
			return 1;
		}
	}

	/* skip system log and batch initiator */
	if (job->q_flag2 & QUEINIT) {
		return 1;
	}

	/* although the QUEINIT flag should cover SYSLOG and INIT jobs,
		it sometimes doesn't */
	if (strcmp((const char *)job->jobname, "SYSLOG") == 0) {
		return 1;
	}
	if (strcmp((const char *)job->jobname, "INIT") == 0) {
		return 1;
	}

	/* compare against the very string this job reports as its status, so the
	   filter can never disagree with the "status" field in the response */
	if (status && strcmp(job_status_str(job), status) != 0) {
		return 1;
	}

	return 0;
}

/* The job's status as z/OSMF names it.  The queue flags are not exclusive -- a
   job can sit on the execution and the output queue at once -- so the order of
   the tests is what decides, and it must stay the single source of the value:
   both the reported "status" field and the status filter go through here. */
__asm__("\n&FUNC	SETC 'job_status_str'");
static const char *
job_status_str(const JESJOB *job)
{
	if (!job || !job->q_type) {
		return "UNKNOWN";
	}

	if (job->q_type & _XEQ) {
		return "ACTIVE";
	}
	if (job->q_type & _INPUT) {
		return "INPUT";
	}
	if (job->q_type & _XMIT) {
		return "XMIT";
	}
	if (job->q_type & _SETUP) {
		return "SETUP";
	}
	if (job->q_type & _RECEIVE) {
		return "RECEIVE";
	}
	if (job->q_type & (_OUTPUT | _HARDCPY)) {
		return "OUTPUT";
	}

	return "UNKNOWN";
}

/* z/OSMF gates the exec-* fields on exec-data=Y; the Zowe CLI sends exactly
   that (GET /zosmf/restjobs/jobs?prefix=...&exec-data=Y).  Without it the job
   object keeps the shape it had before. */
__asm__("\n&FUNC	SETC 'want_exec_data'");
static int
want_exec_data(Session *session)
{
	const char *exec_data = getQueryParam(session, "exec-data");

	return (exec_data && (exec_data[0] == 'Y' || exec_data[0] == 'y'));
}

/* Render a JES2 job timestamp as an ISO 8601 instant in UTC -- the shape real
   z/OSMF emits, "2018-11-03T09:05:18.010Z".  Returns NULL when the job has no
   such time yet, so the caller emits JSON null rather than a bogus 1970 date.

   Two things this must not do.  It must not use ctime64()/localtime64(): those
   convert through crt->crttzoff, the calling task's timezone, which would apply
   an offset a second time on top of tzadjust and report an instant that is
   neither UTC nor anyone's local time (mvslovers/httpd#145).  And it must not
   render local time at all -- the server cannot know the caller's zone, so a
   local string would be unlabelled and the client could not tell what it got.
   gmtime64_r() touches no timezone state, which is why the USS mtime timestamps
   never had this class of bug.

   JES2 keeps its checkpoint times in system local time, so tzadjust carries
   them to UTC.  Resolution is seconds (time64_t), hence the fixed ".000" --
   which is what z/OSMF itself reports for exec-submitted. */
__asm__("\n&FUNC	SETC 'format_exec_time'");
static const char *
format_exec_time(const time64_t *t, int tzadjust, char *out, size_t outlen)
{
	struct tm	tm;
	time64_t	utc;
	int			written;

	if (!t || !out || outlen == 0) {
		return NULL;
	}

	/* a job that has not started (or has not ended) carries a zero time */
	if (__64_cmp_u32((time64_t *)t, 0) == __64_EQUAL) {
		return NULL;
	}

	__64_init(&utc);
	__64_add_i32((time64_t *)t, tzadjust, &utc);

	if (!gmtime64_r(&utc, &tm)) {
		return NULL;
	}

	/* snprintf reports truncation with the would-be length, not a negative rc,
	   so a short buffer would otherwise yield a silently clipped instant that
	   still looks like a valid string to the caller. */
	written = snprintf(out, outlen, "%04d-%02d-%02dT%02d:%02d:%02d.000Z",
			tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
			tm.tm_hour, tm.tm_min, tm.tm_sec);

	if (written < 0 || written >= (int)outlen) {
		return NULL;
	}

	return out;
}

/* Appends one job object to the array.  Returns 1 when the job was emitted, 0
   when a filter skipped it (so the caller can count what it returns against
   max-jobs) and a negative value on error. */
__asm__("\n&FUNC	SETC 'process_job'");
static int
process_job(JsonBuilder *builder, JESJOB *job, const char *owner, const char *status,
			const char *host, const char *scheme, int exec_data)
{
	int rc = 0;

	const char *host_str = host ? host : "127.0.0.1:8080";

	char type_str[TYPE_STR_SIZE];
	char class_str[CLASS_STR_SIZE];
	char url_str[MAX_URL_LENGTH];
	char files_url_str[MAX_URL_LENGTH];
	const char *stat_str = job_status_str(job);

	if (should_skip_job(job, owner, status)) {
		return 0;
	}

	// type is the first 3 characters of the jobid
	rc = snprintf(type_str, sizeof(type_str), "%.3s", job->jobid);
	
	// for STCs and TSO users, class is the first 3 characters of the jobid
	rc = snprintf(class_str, sizeof(class_str), "%.3s", job->jobid);
	
	// for standard jobs, class is the job class
	if (isalnum(job->eclass)) {
		rc = snprintf(class_str, sizeof(class_str), "%c", job->eclass);
	} 

	// url is the full url to the job
	rc = snprintf(url_str, sizeof(url_str),
					"%s://%s/zosmf/restjobs/jobs/%s/%s", scheme, host_str,
					job->jobname, job->jobid);
	
	// files_url is the full url to the job sysout files
	rc = snprintf(files_url_str, sizeof(files_url_str), "%s/files", url_str);

	if (rc < 0) {
		return -1;
	}

	rc = startJsonObject(builder);

	rc = addJsonString(builder, "subsystem", "JES2");
	rc = addJsonString(builder, "jobname", (const char *)job->jobname);
	rc = addJsonString(builder, "jobid", (const char *)job->jobid);
	rc = addJsonString(builder, "owner", (const char *)job->owner);
	rc = addJsonString(builder, "type", type_str);
	rc = addJsonString(builder, "class", class_str);
	rc = addJsonString(builder, "url", url_str);
	rc = addJsonString(builder, "files-url", files_url_str);
	rc = addJsonString(builder, "status", stat_str);
	/* build retcode from JCTCNVRC completion info:
	   after execution  (high byte 0x77): bits 12-23 = system ABEND, bits 0-11 = max CC
	   before execution (converter RC):   4 = JCL error, 8 = I/O error, 36 = abend

	   The 0x77 form is not architected. It is written by usermod SYZJ2001
	   (SYZYGY1A, COPYed into HASPSSSM at sequence T2269950), which walks the
	   SCT chain and stores the highest SCTSEXEC, stamping the high byte "as
	   ours". Both that store and JES2's own JCTJTFLG/JCTJTCC writes sit
	   behind HASPSSSM's `CLI JCTTSUAF,0 / BE HJE005` -- so a job submitted
	   without NOTIFY leaves every one of these fields at zero and gets a
	   null retcode. See docs/endpoints/jobs/status.md. */
	const char *retcode = NULL;
	char retcode_buf[16];
	if (job->q_type & (_OUTPUT | _HARDCPY)) {
		unsigned int comp = job->completion;
		if ((comp >> 24) == 0x77) {
			/* job executed — decode completion info */
			unsigned int abend = (comp >> 12) & 0xFFF;
			unsigned int maxcc =  comp        & 0xFFF;
			if (abend) {
				snprintf(retcode_buf, sizeof(retcode_buf), "ABEND S%03X", abend);
				retcode = retcode_buf;
			} else if ((job->jtflg & JESJOB_ABD) && maxcc) {
				snprintf(retcode_buf, sizeof(retcode_buf), "ABEND U%04d", maxcc);
				retcode = retcode_buf;
			} else if (job->jtflg == JESJOB_JF) {
				/* JCTJTFLG carrying nothing but "JOB FAILED" means the job
				   died before any step produced a code: HASPSSSM sets that
				   bit at T2269500 with the comment SET JCL ERROR FLAG, on
				   the SSOBJBSL (job select) path -- an allocation failure,
				   IEF453I JOB FAILED - JCL ERROR. The completion word is a
				   truthful 0x77000000 there, because the highest condition
				   code over the steps that ran really is zero: no step ran.
				   Reporting that as CC 0000 makes a failed job look clean.

				   The test is equality, not a mask, and it is the usermod's
				   own: SYZYGY1B (HASPPRPU) guards its "- MAX COND CODE nnnn"
				   line with `CLI JCTJTFLG,JCTJTJF / BE` and prints nothing
				   when the byte is exactly the JF bit. A COND failure has
				   JF|CF (measured: 0xC0) and keeps its condition code. */
				retcode = "JCL ERROR";
			} else {
				snprintf(retcode_buf, sizeof(retcode_buf), "CC %04d", maxcc);
				retcode = retcode_buf;
			}
		} else if (comp == 4 || comp == 8 || comp == 36) {
			/* JCL converter error: the job never reached an initiator, so
			   the converter's own return code is still in the field
			   (IEF452I JOB NOT RUN - JCL ERROR). */
			retcode = "JCL ERROR";
		}
	}
	rc = addJsonString(builder, "retcode", retcode);

	if (exec_data) {
		/* crttzoff is seconds east of UTC (negative west) and UTC = local -
		   offset, so the addend is the negated offset.  __tzget() reports the
		   value tzset() resolved for this task from TZ or the system's CVTTZ --
		   a fact about the machine, not a configured preference.  Kept on the
		   stack: MVSMF is link-edited RENT, so caching it in a static would
		   ABEND S0C4 on the write. */
		int  tzadjust = __tzget() * -1;
		char exec_time[EXEC_TIME_STR_SIZE];

		/* exec-submitted is deliberately absent: JES2 records it as
		   JCTRDRON/JCTRDTON (time/date on the input processor), which libc370's
		   JESJOB does not carry -- see mvslovers/libc370#79. */
		rc = addJsonString(builder, "exec-started",
			format_exec_time(&job->start_time64, tzadjust,
				exec_time, sizeof(exec_time)));
		rc = addJsonString(builder, "exec-ended",
			format_exec_time(&job->end_time64, tzadjust,
				exec_time, sizeof(exec_time)));
	}

	rc = endJsonObject(builder);
	if (rc < 0) {
		return rc;
	}

	return 1;
}

__asm__("\n&FUNC    SETC 'find_job_by_name_and_id'");
static 
JESJOB* find_job_by_name_and_id(Session *session, const char *jobname, const char *jobid, JESJOB ***out_joblist)
{
	int job_found = 0;

	JESJOB *found_job = NULL;
	JESJOB **joblist = NULL;
	JESFILT jesfilt = FILTER_JOBID;
	const char *filter = jobid;
	/* declared here, not at the jesopen() below: the early exit for a missing
	   path variable jumps over that line, and quit: reads this pointer */
	JES *jes = NULL;

	if (out_joblist) {
		*out_joblist = NULL;
	}

	if (!jobname || !jobid) {
		goto quit;
	}

	jes = jesopen();
	session_register_jes(session, jes);
	if (!jes) {
		wtof(MSG_JES_UNAVAILABLE);
		goto quit;
	}

	/* the abend of #282 lands in here, which is why the handle is registered
	   above rather than merely closed at quit: -- that label is not reached */
	joblist = jesjob(jes, filter, jesfilt, 1);
	if (!joblist) {
		goto quit;
	}

	int ii = 0;
	for (ii = 0; ii < array_count(&joblist); ii++) {
		JESJOB *job = joblist[ii];

		if (!job) {
			continue;
		}

		if (http_cmp((const UCHAR *)job->jobname, (const UCHAR *)jobname) != 0) {
			continue;
		}

		job_found++;
		if (job_found > 1) {
			// TODO (mig): create a new error message in jobsapi_msg.h
			goto quit;
		}

		found_job = job;
	}

quit:
	session_jesclose(session, &jes);

	if (out_joblist) {
		*out_joblist = joblist;
	}

	return found_job;
}

__asm__("\n&FUNC    SETC 'get_recfm_string'");
static 
void get_recfm_string(unsigned recfm, char *recfm_str) 
{
    int pos = 0;
    
    if ((recfm & RECFM_U) == RECFM_U) {
        recfm_str[pos++] = 'U';
    } else if ((recfm & RECFM_F) == RECFM_F) {
        recfm_str[pos++] = 'F';
    } else if ((recfm & RECFM_V) == RECFM_V) {
        recfm_str[pos++] = 'V';
    }

    if (recfm & RECFM_BR) {
        recfm_str[pos++] = 'B';
    }

    if (recfm & RECFM_CA) {
        recfm_str[pos++] = 'A';
    } else if (recfm & RECFM_CM) {
        recfm_str[pos++] = 'M';
    }

    if (recfm_str[0] == 'V' && (recfm & RECFM_SB)) {
        recfm_str[pos++] = 'S';
    }
    recfm_str[pos] = 0;
}

__asm__("\n&FUNC    SETC 'process_job_files'");
static 
int process_job_files(Session *session, JESJOB *job, const char *host, JsonBuilder *builder) 
{
    int rc = 0;
    
	const char *host_str = host ? host : "127.0.0.1:8080";
	const char *scheme = getRequestScheme(session);

	char url_str[MAX_URL_LENGTH] = {0};
    char recfm_str[RECFM_STR_SIZE] = {0};

    if (!job) {
		return -1;
	}

	int ii = 0;
    for (ii = 0; ii < array_count(&job->jesdd); ii++) {
        JESDD *dd = job->jesdd[ii];
        if (http_cmp((const UCHAR *)dd->ddname, (const UCHAR *)"JESINTXT") == 0) {
            continue;
        }

        rc = snprintf(url_str, sizeof(url_str),
                    "%s://%s/zosmf/restjobs/jobs/%s/%s/files/%d/records",
                    scheme, host_str, job->jobname, job->jobid, dd->dsid);

        get_recfm_string(dd->recfm, recfm_str);

        rc = startJsonObject(builder);
        
		rc = addJsonString(builder, "recfm", recfm_str);
        rc = addJsonString(builder, "records-url", url_str);
        rc = addJsonString(builder, "subsystem", "JES2");
        rc = addJsonString(builder, "byte-count", 0);
        rc = addJsonNumber(builder, "lrecl", dd->lrecl);
        rc = addJsonString(builder, "jobid", (char *) job->jobid);
        rc = addJsonString(builder, "ddname", (char *) dd->ddname);
        rc = addJsonNumber(builder, "id", dd->dsid);
        rc = addJsonNumber(builder, "record-count", (int) dd->records);
        rc = addJsonString(builder, "class", (char[]){(char)dd->oclass, '\0'});
        rc = addJsonString(builder, "jobname", (char *) job->jobname);
        rc = addJsonString(builder, "stepname", dd->stepname[0] ? (char *)dd->stepname : "JES2");
        rc = addJsonString(builder, "procstep", dd->procstep[0] ? (char *)dd->procstep : NULL);
        
		rc = endJsonObject(builder);

        if (rc < 0) {
			return rc;
		}
    }

    return 0;
}

__asm__("\n&FUNC    SETC 'get_max_jobs'");
static 
unsigned get_max_jobs(Session *session) 
{
    const char *max_jobs_str = getQueryParam(session, "max-jobs");
    unsigned max_jobs = MAX_JOBS_LIMIT;

    if (max_jobs_str) {
        char *endptr = NULL;
        long val = strtol(max_jobs_str, &endptr, DECIMAL_BASE);
        if (*endptr == '\0' && val > 0 && val <= UINT_MAX) {
            max_jobs = (unsigned)val;
        }
    }

    // validate max_jobs boundaries
    if (max_jobs <= 0) {
        max_jobs = 1;
    } else if (max_jobs > MAX_JOBS_LIMIT) {
        max_jobs = MAX_JOBS_LIMIT;
    }

    return max_jobs;
}

__asm__("\n&FUNC    SETC 'validate_intrdr_headers'");
static 
int validate_intrdr_headers(Session *session) 
{
    const char *intrdr_mode = getHeaderParam(session, "X-IBM-Intrdr-Mode");
    if (intrdr_mode != NULL && strcmp(intrdr_mode, "TEXT") != 0) {
        return -1;
    }

    const char *intrdr_lrecl = getHeaderParam(session, "X-IBM-Intrdr-Lrecl");
    if (intrdr_lrecl != NULL && strcmp(intrdr_lrecl, "80") != 0) {
        return -1;
    }

    const char *intrdr_recfm = getHeaderParam(session, "X-IBM-Intrdr-Recfm");
    if (intrdr_recfm != NULL && strcmp(intrdr_recfm, "F") != 0) {
        return -1;
    }

    return 0;
}

/* Open the internal reader, as late on the path as the request allows.
 *
 * jesiropn() dynallocs an INTRDR SYSOUT DD and opens the JES2 ACB, and
 * nothing in mvsMF reclaims either one if the request abends before the
 * close: the session tracker knows FILE and JES handles, not VSFILE. So the
 * open belongs after everything that can still reject the request. It used
 * to sit before read_request_content(), which held both resources across a
 * byte-at-a-time read of a body that can be megabytes, and paid a full
 * open/close cycle for every request that turned out to submit nothing --
 * an unsupported Content-Type, a body that would not read, a JSON document
 * with no "file" member (issue #300).
 *
 * Returns 0 with *intrdr usable, -1 with the 500 already sent.
 */
__asm__("\n&FUNC    SETC 'open_intrdr'");
static
int open_intrdr(Session *session, VSFILE **intrdr)
{
	if (jesiropn(intrdr) < 0) {
		wtof(MSG_INTRDR_OPEN);
		sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR, CATEGORY_SERVICE,
						RC_SEVERE, REASON_SERVER_ERROR,
						"Failed to open internal reader", NULL, 0);
		return -1;
	}

	return 0;
}

__asm__("\n&FUNC	SETC 'extract_file_value'");
static const char *
extract_file_value(char *json, size_t len)
{
	char *pos = NULL;
	char *val_start = NULL;
	char *val_end = NULL;

	if (!json || len == 0) {
		return NULL;
	}

	/* find "file" key in ASCII JSON */
	pos = strstr(json, "\"file\"");
	if (!pos) {
		return NULL;
	}

	/* skip past "file" */
	pos += 6;

	/* skip whitespace */
	while (pos < json + len && (*pos == ' ' || *pos == '\t')) {
		pos++;
	}

	/* expect colon */
	if (pos >= json + len || *pos != ':') {
		return NULL;
	}
	pos++;

	/* skip whitespace */
	while (pos < json + len && (*pos == ' ' || *pos == '\t')) {
		pos++;
	}

	/* expect opening quote */
	if (pos >= json + len || *pos != '"') {
		return NULL;
	}
	pos++;
	val_start = pos;

	/* find closing quote */
	val_end = strchr(val_start, '"');
	if (!val_end) {
		return NULL;
	}

	/* null-terminate the value in place */
	*val_end = '\0';

	return val_start;
}

__asm__("\n&FUNC	SETC 'submit_file'");
static int
submit_file(Session *session, VSFILE *intrdr, const char *filename,
            char *jobname, char *jobid, char *jobclass)
{
	int rc = 0;

	FILE *fp = NULL;
	char *buffer = NULL;
	size_t buffer_size = 0;
	char **lines = NULL;
	char *lines_buf = NULL;
	int num_lines = 0;
	int capacity = INITIAL_JCL_CAPACITY;
	int modified_lines_count = 0;

	char dsname[DSNAME_STR_SIZE + 1];

	*jobclass = 'A';
	memset(jobname, 0, JOBNAME_STR_SIZE + 1);
	memset(jobid, 0, JOBID_STR_SIZE + 1);

	/* strip //'DSN' → DSN */
	size_t len = strlen(filename);
	if (len > 4 && filename[0] == '/' && filename[1] == '/' &&
		filename[2] == '\'' && filename[len - 1] == '\'') {
		strncpy(dsname, &filename[3], len - 4);
		dsname[len - 4] = '\0';
	} else {
		char msg[MAX_ERR_MSG_LENGTH] = {0};
		snprintf(msg, sizeof(msg), ERR_MSG_SUBMIT_FILE_OPEN, filename);
		sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST, CATEGORY_SERVICE,
						RC_ERROR, REASON_SUBMIT_FILE_OPEN, msg, NULL, 0);
		rc = -1;
		goto quit;
	}

	fp = fopen(dsname, "re");
	if (!fp) {
		char msg[MAX_ERR_MSG_LENGTH] = {0};
		snprintf(msg, sizeof(msg), ERR_MSG_SUBMIT_FILE_OPEN, dsname);
		sendErrorResponse(session, HTTP_STATUS_NOT_FOUND, CATEGORY_SERVICE,
						RC_ERROR, REASON_SUBMIT_FILE_OPEN, msg, NULL, 0);
		rc = -1;
		goto quit;
	}
	session_register_file(session, fp);

	buffer_size = fp->lrecl + 2;
	buffer = calloc(1, buffer_size);
	if (!buffer) {
		sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
						CATEGORY_UNEXPECTED, RC_SEVERE, REASON_SERVER_ERROR,
						ERR_MSG_SERVER_ERROR, NULL, 0);
		rc = -1;
		goto quit;
	}

	/* allocate lines array with initial capacity */
	lines = (char **)calloc(capacity, sizeof(char *));
	lines_buf = (char *)calloc(capacity, 81);
	if (!lines || !lines_buf) {
		sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
						CATEGORY_UNEXPECTED, RC_SEVERE, REASON_SERVER_ERROR,
						ERR_MSG_SERVER_ERROR, NULL, 0);
		rc = -1;
		goto quit;
	}
	{
		int alloc_idx = 0;
		for (alloc_idx = 0; alloc_idx < capacity; alloc_idx++) {
			lines[alloc_idx] = lines_buf + (alloc_idx * 81);
		}
	}

	/* read dataset into lines array */
	while (fgets(buffer, (int)buffer_size, fp) > 0) {
		size_t line_len;

		if (num_lines >= capacity) {
			if (grow_lines_arrays(&lines, &lines_buf, &capacity,
								  num_lines + 1) < 0) {
				sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
								CATEGORY_UNEXPECTED, RC_SEVERE, REASON_SERVER_ERROR,
								ERR_MSG_SERVER_ERROR, NULL, 0);
				rc = -1;
				goto quit;
			}
		}

		line_len = strlen(buffer);

		/* remove trailing newline/CR */
		while (line_len > 0 && (buffer[line_len - 1] == '\n' ||
				buffer[line_len - 1] == '\r' ||
				buffer[line_len - 1] == EBCDIC_LF)) {
			buffer[line_len - 1] = '\0';
			line_len--;
		}

		strncpy(lines[num_lines], buffer, 80);
		lines[num_lines][80] = '\0';
		num_lines++;
	}

	session_fclose(session, fp);
	fp = NULL;

	/* ensure room for the extra line added by process_jobcard */
	if (grow_lines_arrays(&lines, &lines_buf, &capacity, num_lines + 1) < 0) {
		sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
						CATEGORY_UNEXPECTED, RC_SEVERE, REASON_SERVER_ERROR,
						ERR_MSG_SERVER_ERROR, NULL, 0);
		rc = -1;
		goto quit;
	}

	/* process jobcard: inject USER/PASSWORD */
	{
		char user[64] = {0};
		char password[256] = {0};

		if (get_caller_credentials(session, user, sizeof(user),
									   password, sizeof(password)) < 0) {
			sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST, CATEGORY_SERVICE,
							RC_ERROR, REASON_INVALID_REQUEST,
							"Job submission requires an authenticated session with a password", NULL, 0);
			rc = -1;
			goto quit;
		}

		rc = process_jobcard(lines, num_lines, jobname, jobclass, user, password);
		memset(password, 0, sizeof(password));   /* scrub; it now lives on the card */
		if (rc == JOBCARD_ERR_TOO_LONG) {
			sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST, CATEGORY_SERVICE,
							RC_ERROR, REASON_JOBCARD_TOO_LONG,
							ERR_MSG_JOBCARD_TOO_LONG, NULL, 0);
			goto quit;
		}
		if (rc < 0) {
			sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST, CATEGORY_SERVICE,
							RC_ERROR, REASON_INVALID_REQUEST,
							"No valid JOB card found in dataset", NULL, 0);
			goto quit;
		}
		modified_lines_count = rc;
	}

	/* submit all lines to internal reader */
	{
		int ii = 0;
		for (ii = 0; ii < modified_lines_count; ii++) {
			if (lines[ii][0] != '\0') {
				rc = jesirput(intrdr, lines[ii]);
				if (rc < 0) {
					wtof(MSG_INTRDR_WRITE);
					sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
									CATEGORY_UNEXPECTED, RC_SEVERE, REASON_SERVER_ERROR,
									ERR_MSG_SERVER_ERROR, NULL, 0);
					goto quit;
				}
			}
		}
	}

	/* Close internal reader and retrieve jobid.  jesircl2() copies the
	   feedback out between the ENDREQ and the close -- the old read of
	   intrdr->rpl.rplrbar after jesircls() fetched from the freed VSFILE
	   (#296).  The handle is gone even when the close reports an error,
	   so drop the pointer right away; the old error path handed the dead
	   handle to jesircls() a second time at quit:. */
	{
		unsigned char jobid_raw[8];

		rc = jesircl2(intrdr, jobid_raw);
		intrdr = NULL;
		if (rc < 0) {
			wtof(MSG_INTRDR_CLOSE);
			sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
							CATEGORY_UNEXPECTED, RC_SEVERE, REASON_SERVER_ERROR,
							ERR_MSG_SERVER_ERROR, NULL, 0);
			goto quit;
		}

		memcpy(jobid, jobid_raw, JOBID_STR_SIZE);
		jobid[JOBID_STR_SIZE] = '\0';
	}

	wtof(MSG_JOB_SUBMITTED, jobname, jobid);
	rc = 0;

quit:
	if (intrdr) {
		jesircls(intrdr);
	}

	if (fp) {
		session_fclose(session, fp);
	}

	if (buffer) {
		free(buffer);
	}

	if (lines) {
		free((void *)lines);
	}
	if (lines_buf) {
		free(lines_buf);
	}

	return rc;
}

__asm__("\n&FUNC    SETC 'tokenize'");
static 
char* tokenize(char *str, const char *delim, char **saveptr) 
{
    char *token = NULL;

    if (str == NULL) {
        str = *saveptr;
    }

    if (str == NULL) {
        return NULL;
    }

    // Skip leading delimiters
    str += strspn(str, delim);
    if (*str == '\0') {
        *saveptr = str;
        return NULL;
    }

    // Find end of token
    token = str;
    str = strpbrk(token, delim);
    if (str == NULL) {
        *saveptr = token + strlen(token);
    } else {
        *str = '\0';
        *saveptr = str + 1;
    }
    return token;
}

__asm__("\n&FUNC    SETC 'send_job_status_response'");
static int
send_job_status_response(Session *session, JESJOB *job, const char *host)
{
    int rc = 0;
    
	JsonBuilder *builder = createJsonBuilder();

    if (!builder) {
        sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR, CATEGORY_UNEXPECTED,
                      RC_SEVERE, REASON_SERVER_ERROR, ERR_MSG_SERVER_ERROR, NULL, 0);
        return -1;
    }

    rc = process_job(builder, job, NULL, NULL, host, getRequestScheme(session),
                     want_exec_data(session));
    if (rc < 0) {
        freeJsonBuilder(builder);
        return rc;
    }

    rc = sendJSONResponse(session, HTTP_STATUS_OK, builder);
    
	freeJsonBuilder(builder);
    
	return rc;
}

__asm__("\n&FUNC    SETC 'find_and_send_job_status'");
static int
find_and_send_job_status(Session *session, const char *jobname, const char *jobid, const char *host)
{
    int rc = 0;

    JESJOB *job = NULL;
    JESJOB **joblist = NULL;

    if (!jobname || !jobid) {
        sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST, CATEGORY_UNEXPECTED,
                      RC_SEVERE, REASON_SERVER_ERROR, ERR_MSG_SERVER_ERROR,
                      NULL, 0);
        rc = -1;
	   	goto quit;
    }

    job = find_job_by_name_and_id(session, jobname, jobid, &joblist);
    if (!job) {
        char msg[MAX_ERR_MSG_LENGTH] = {0};
        rc = snprintf(msg, sizeof(msg), ERR_MSG_JOB_NOT_FOUND, jobname, jobid);
        sendErrorResponse(session, HTTP_STATUS_NOT_FOUND, CATEGORY_SERVICE,
                      RC_WARNING, REASON_JOB_NOT_FOUND,
                      msg, NULL, 0);
        rc = -1;
		goto quit;
    }

    rc = send_job_status_response(session, job, host);

quit:
    if (joblist) {
        jesjobfr(&joblist);
    }

	return rc;
}

__asm__("\n&FUNC    SETC 'get_operation'");
static void 
get_operation(const char *line, char *op, size_t op_size) 
{
    if (!line || !op || op_size < 5) {
        if (op && op_size > 0) {
            op[0] = '\0';
        }
        return;
    }

    size_t line_len = strlen(line);
    if (line_len < 3) {  // Mindestens // + 1 Zeichen
        op[0] = '\0';
        return;
    }

    // Skip // at start
    const char *pos = line + 2;
    const char *end = line + line_len;
    
    // Skip name field (up to 8 chars)
    size_t name_chars = 0;
    while (*pos && pos < end && *pos != ' ' && name_chars < 8) {
        pos++;
        name_chars++;
    }
    
    // Skip spaces between name and operation
    while (*pos && pos < end && *pos == ' ') {
        pos++;
    }
    
    // Copy operation field (up to 4 chars)
    size_t i = 0;
    while (i < 4 && i < op_size - 1 && pos < end && *pos && *pos != ' ') {
        op[i++] = *pos++;
    }
    op[i] = '\0';

    // Right trim
    for (i--; i >= 0; i--) {
        if (isspace((unsigned char)op[i])) {
            op[i] = '\0';
        } else {
            break;
        }
    }
}

__asm__("\n&FUNC    SETC 'is_jcl_line'");
static int 
is_jcl_line(const char *line) 
{
    return (strncmp(line, "//", 2) == 0);
}

__asm__("\n&FUNC    SETC 'has_name_field'");
static int 
has_name_field(const char *line) 
{
    // Name field is columns 3-10 (0-based: 2-9)
    int ii = 0;
    for (ii = 2; ii < 10 && line[ii] != '\0'; ii++) {
        if (!isspace((unsigned char)line[ii])) {
            return 1;
        }
    }
    return 0;
}

__asm__("\n&FUNC    SETC 'find_job_card_range'");
static void 
find_job_card_range(char **lines, int count, int *start_idx, int *end_idx) 
{
    *start_idx = -1;
    *end_idx = -1;

    int ii = 0;
    for (ii = 0; ii < count; ii++) {
        // Skip if line is NULL or too short
        if (!lines[ii] || strlen(lines[ii]) < 3) {
            continue;
        }

        // Check if this is a JCL line
        if (!is_jcl_line(lines[ii])) {
            continue;
        }

        // Get operation field
        char op[5] = {0};
        get_operation(lines[ii], op, sizeof(op));

        // Is this a JOB statement?
        if (strcmp(op, "JOB") == 0) {
            // Found the start of job card
            *start_idx = ii;
            *end_idx = ii;

            // Look for continuation lines
            int jj = ii;
            while (jj < count) {
                char *line = lines[jj];
                size_t len = strlen(line);
                int has_comma = 0;

                // Find last non-space character
                int kk = 0;
                for (kk = len - 1; kk >= 0; kk--) {
                    if (!isspace((unsigned char)line[kk])) {
                        has_comma = (line[kk] == ',');
                        break;
                    }
                }

                // If no comma at end, this is the last line of job card
                if (!has_comma) {
                    *end_idx = jj;
                    break;
                }

                // Check next line
                jj++;
                if (jj >= count) {
                    *end_idx = jj - 1;
                    break;
                }

                // Next line must be a JCL continuation line
                if (!is_jcl_line(lines[jj])) {
                    *end_idx = jj - 1;
                    break;
                }

                // Must be a continuation line (// followed by spaces)
                int is_continuation = 1;
                for (kk = 2; kk < 10; kk++) {
                    if (!isspace((unsigned char)lines[jj][kk])) {
                        is_continuation = 0;
                        break;
                    }
                }

                if (!is_continuation) {
                    *end_idx = jj - 1;
                    break;
                }

                // Valid continuation line, continue checking
                *end_idx = jj;
            }
            return;
        }
    }
}

/*
 * INTRDR job submission must place a real USER=/PASSWORD= on the JOB card (see
 * process_jobcard): MVS 3.8j/RAKF does no userid propagation, so a passwordless
 * job would run as the PROD default. The identity and password come from the
 * credential httpd already resolved for this request -- not from re-parsing
 * Authorization -- so this works for Basic and token auth alike. httpd retains
 * the caller's password (blowfish-encrypted) in the CRED for the whole session;
 * http_get_password() decrypts it in httpd's context (mvslovers/httpd#111) and
 * http_get_userid() returns the RACF-canonical userid from the ACEE. Both are
 * already uppercase (RACF userids are; cred_login() upper-cases the password at
 * login), which is what JES2/RAKF job initiation expects. Returns 0, or -1 when
 * the session has no usable userid+password (e.g. a token-only session with no
 * password login). See #164.
 */
__asm__("\n&FUNC    SETC 'get_caller_credentials'");
static int
get_caller_credentials(Session *session, char *user, size_t user_len,
                          char *password, size_t password_len)
{
	if (!user || user_len == 0 || !password || password_len == 0) {
		return -1;
	}

	/* userid from the ACEE (RACF-canonical); NULL if unauthenticated */
	if (!http_get_userid(session->httpc, (UCHAR *)user, (unsigned)user_len)) {
		return -1;
	}

	/* plaintext password from the resolved credential; NULL if the session
	 * carries no password (e.g. a token-only session with no password login) */
	if (!http_get_password(session->httpc, (UCHAR *)password, (unsigned)password_len)) {
		return -1;
	}

	return 0;
}

/*
 * Locate the NOTIFY keyword on a job card line, or NULL when the line has none.
 *
 * A bare strstr() will not do. "NOTIFY" also occurs inside the quoted
 * programmer-name field -- //J JOB (ACCT),'NOTIFY ME' -- and the '=' a caller
 * then looks for is the one belonging to some later operand, so the card reads
 * as carrying a NOTIFY it does not have. That misreading is silent in both
 * directions: it makes the &SYSUID rewrite consider the wrong text, and it
 * suppresses the injection below for a card that needs it.
 *
 * So require the keyword to start at an operand boundary (the blank after the
 * JOB verb, a comma, or the blanks of a continuation card), to sit outside
 * quotes, and to be followed by '='. Apostrophe doubling needs no special case:
 * '' toggles the quote state twice and leaves it where it was.
 */
__asm__("\n&FUNC    SETC 'find_notify_operand'");
static char *
find_notify_operand(char *line)
{
    int in_quotes = 0;
    int at_operand = 1;
    char *pp = NULL;

    if (!line) {
        return NULL;
    }

    for (pp = line; *pp != '\0'; pp++) {
        if (*pp == '\'') {
            in_quotes = !in_quotes;
            at_operand = 0;
            continue;
        }

        if (in_quotes) {
            continue;
        }

        if (at_operand && strncmp(pp, "NOTIFY", 6) == 0) {
            const char *qq = pp + 6;

            while (*qq == ' ') {
                qq++;
            }

            if (*qq == '=') {
                return pp;
            }
        }

        at_operand = (*pp == ',' || *pp == ' ');
    }

    return NULL;
}

__asm__("\n&FUNC    SETC 'process_jobcard'");
static int
process_jobcard(char **lines, int num_lines, char *jobname, char *jobclass, 
               const char *user, const char *password) 
{
    int rc = -1;
    int start_idx = -1;
    int end_idx = -1;
    int notify_replaced = 0;
    int notify_present = 0;

    if (!lines || num_lines <= 0 || !jobname || !jobclass || !user) {
        return JOBCARD_ERR_NO_CARD;
    }

    if (!password) {
        return JOBCARD_ERR_NO_CARD;
    }

    // Find the job card range
    find_job_card_range(lines, num_lines, &start_idx, &end_idx);
    if (start_idx < 0 || end_idx < 0) {
        return JOBCARD_ERR_NO_CARD;
    }

    // Extract jobname from first line (columns 3-10)
    const char *first_line = lines[start_idx];
    if (!first_line) {
        return JOBCARD_ERR_NO_CARD;
    }

    size_t first_line_len = strlen(first_line);
    if (first_line_len < 3) {
        return JOBCARD_ERR_NO_CARD;
    }

    int ii = 0;
    for (ii = 2; ii < 10 && ii < first_line_len && first_line[ii] != ' ' && first_line[ii] != '\0'; ii++) {
        jobname[ii - 2] = first_line[ii];
    }
    jobname[ii - 2] = '\0';

    // Extract class if present
    char *class_param = strstr(first_line, "CLASS=");
    if (class_param && strlen(class_param) > 6) {
        *jobclass = class_param[6];
    }

    // Process job card lines in-place: replace NOTIFY=&SYSUID
    for (ii = start_idx; ii <= end_idx; ii++) {
        if (!lines[ii]) {
            return JOBCARD_ERR_NO_CARD;
        }

        // Replace &SYSUID with actual user if present and not already replaced
        {
            char *notify_start = find_notify_operand(lines[ii]);
            if (notify_start) {
                char *equals = strchr(notify_start, '=');

                /* Note the NOTIFY whatever its value: the injection below must
                   not add a second one to a card that already names a userid,
                   and only the &SYSUID form is rewritten here. */
                notify_present = 1;

                if (equals && !notify_replaced) {
                    // Skip any whitespace after the equals sign
                    char *sysuid = equals + 1;
                    while (*sysuid == ' ') sysuid++;

                    if (strncmp(sysuid, "&SYSUID", 7) == 0) {
                        char temp_line[81] = {0};
                        char before[80] = {0};
                        char after[80] = {0};
                        size_t notify_offset = notify_start - lines[ii];

                        strncpy(temp_line, lines[ii], 80);

                        // Copy part before NOTIFY
                        strncpy(before, temp_line, notify_offset);

                        // Find end of &SYSUID
                        char *sysuid_end = sysuid + 7;
                        char *real_end = sysuid_end;

                        // Skip spaces after &SYSUID
                        while (*real_end == ' ') real_end++;

                        // Find actual end of parameter (comma or end of line)
                        while (*real_end != '\0' && *real_end != ',' && *real_end != ' ') {
                            real_end++;
                        }

                        // Copy remaining text after parameter
                        if (*real_end == ',') {
                            strncpy(after, real_end, sizeof(after) - 1);
                        } else {
                            // Skip any trailing spaces
                            while (*real_end == ' ') real_end++;

                            if (*real_end) {
                                rc = snprintf(after, sizeof(after), ",%s", real_end);
                                if (rc < 0 || rc >= sizeof(after)) {
                                    return JOBCARD_ERR_TOO_LONG;
                                }
                            }
                        }

                        // Strip trailing blanks carried over from the fixed
                        // 80-column input record. JCL ignores columns past the
                        // last significant character; leaving the padding in
                        // would overflow the 72-byte job card buffer below when
                        // NOTIFY is not the final parameter (e.g. NOTIFY=&SYSUID
                        // followed by REGION=).
                        {
                            size_t after_len = strlen(after);
                            while (after_len > 0 && after[after_len - 1] == ' ') {
                                after[--after_len] = '\0';
                            }
                        }

                        // Combine parts with actual user directly into lines[ii]
                        rc = snprintf(lines[ii], 72, "%sNOTIFY=%s%s",
                                    before, user, after);
                        if (rc < 0 || rc >= 72) {
                            return JOBCARD_ERR_TOO_LONG;
                        }
                        lines[ii][80] = '\0';
                        notify_replaced = 1;
                    }
                }
            }
        }

        // For last job card line, ensure it ends with comma
        if (ii == end_idx) {
            size_t len = strlen(lines[ii]);
            while (len > 0 && lines[ii][len-1] == ' ') {
                len--;
            }
            if (len > 0 && lines[ii][len-1] != ',') {
                if (len >= 70) {
                    return JOBCARD_ERR_TOO_LONG;
                }
                lines[ii][len++] = ',';
                lines[ii][len] = '\0';
            }
        }
    }

    // Shift remaining lines (after job card) down by 1 to make room for the
    // USER/PASSWORD continuation card
    for (ii = num_lines - 1; ii > end_idx; ii--) {
        strncpy(lines[ii + 1], lines[ii], 80);
        lines[ii + 1][80] = '\0';
    }

    /* Insert USER and PASSWORD on a single continuation card, plus a trailing
     * "GENERATED BY MVSMF" marker -- one card like usermod ZP60034's IKJEFF10
     * ("GENERATED BY IKJEFF10"). PASSWORD= is the last operand, so the blank
     * before the marker ends the operand field and the rest is a JCL comment;
     * JES2 masks the password in listings while the marker remains.
     *
     * NOTIFY= joins it when the submitted card carried none (#307). It has to
     * go *before* USER=, not after PASSWORD=, for two reasons: it must not
     * displace PASSWORD= from the end of the operand field, on which the
     * masking above depends -- and the card has no room for it at the end.
     * Worst case is 11 (//+9 blanks) + 7 + 8 (NOTIFY=userid) + 6 + 8 (,USER=)
     * + 10 + 8 (,PASSWORD=) = 58 of the 71 usable columns, which leaves 13 for
     * the marker; the long one needs 21. So the marker shortens exactly when
     * a NOTIFY is injected, and a card that already has one is emitted
     * byte-for-byte as before.
     *
     * Why inject at all: HASPSSSM gates every write to JCTCNVRC/JCTJTFLG/
     * JCTJTCC on CLI JCTTSUAF,0, so a job submitted without NOTIFY records no
     * completion code anywhere and reports "retcode": null however it ended.
     * No z/OSMF client adds NOTIFY -- on z/OS none needs to -- so without this
     * "zowe jobs submit --wait-for-output" never finishes. */
    {
        char notify[32] = {0};

        if (!notify_present) {
            rc = snprintf(notify, sizeof(notify), "NOTIFY=%s,", user);
            if (rc < 0 || (size_t)rc >= sizeof(notify)) {
                return JOBCARD_ERR_TOO_LONG;
            }
        }

        rc = snprintf(lines[end_idx + 1], 72,
                      "//         %sUSER=%s,PASSWORD=%s   GENERATED BY MVSMF",
                      notify, user, password);
        if (rc < 0 || rc >= 72) {
            rc = snprintf(lines[end_idx + 1], 72,
                          "//         %sUSER=%s,PASSWORD=%s   BY MVSMF",
                          notify, user, password);
        }
        if (rc < 0 || rc >= 72) {
            return JOBCARD_ERR_TOO_LONG;
        }
    }

    return num_lines + 1;
}

__asm__("\n&FUNC    SETC 'submit_jcl_content'");
static 
int submit_jcl_content(Session *session, VSFILE *intrdr, const char *content, size_t content_length, 
                      char *jobname, char *jobid, char *jobclass) 
{
    int rc = 0;
    char *ebcdic_content = NULL;
    char **lines = NULL;
    char *lines_buf = NULL;
    int num_lines = 0;
    int capacity = INITIAL_JCL_CAPACITY;
    int final_lines_count = 0;
    
    *jobclass = 'A';
    memset(jobname, 0, JOBNAME_STR_SIZE + 1);
    memset(jobid, 0, JOBID_STR_SIZE + 1);

    /* Use malloc+memcpy instead of strdup to ensure all bytes are copied
     * even if content contains embedded nulls */
    ebcdic_content = (char *)malloc(content_length + 1);
    if (!ebcdic_content) {
        wtof(MSG_STORAGE_FAILED, ALLOC_JCL_TEXT);
        rc = -1;
        goto quit;
    }
    memcpy(ebcdic_content, content, content_length);
    ebcdic_content[content_length] = '\0';

    http_xlate((unsigned char *)ebcdic_content, content_length, httpx->xlate_cp037->atoe);

    /* Allocate lines array + contiguous buffer */
    lines = (char **)calloc(capacity, sizeof(char *));
    lines_buf = (char *)calloc(capacity, 81);
    if (!lines || !lines_buf) {
        wtof(MSG_STORAGE_FAILED, ALLOC_JCL_LINES);
        rc = -1;
        goto quit;
    }
    {
        int li;
        for (li = 0; li < capacity; li++) {
            lines[li] = lines_buf + (li * 81);
        }
    }

    char delimiter[2] = {EBCDIC_NEL, '\0'}; // CP037 A2E maps ASCII LF to NEL (0x15)
    char *saveptr = NULL;
    char *line = tokenize(ebcdic_content, delimiter, &saveptr);

    // Collect all lines
    while (line != NULL) {
        size_t line_len;

        if (num_lines >= capacity) {
            if (grow_lines_arrays(&lines, &lines_buf, &capacity,
                                  num_lines + 1) < 0) {
                wtof(MSG_STORAGE_FAILED, ALLOC_JCL_LINES);
                rc = -1;
                goto quit;
            }
        }

        line_len = strlen(line);

        // Remove trailing CR if present
        if (line_len > 0 && line[line_len - 1] == '\r') {
            line[line_len - 1] = '\0';
            line_len--;
        }

        strncpy(lines[num_lines], line, 80);
        lines[num_lines][80] = '\0';
        num_lines++;

        line = tokenize(NULL, delimiter, &saveptr);
    }

    /* ensure room for the extra line added by process_jobcard */
    if (grow_lines_arrays(&lines, &lines_buf, &capacity, num_lines + 1) < 0) {
        wtof(MSG_STORAGE_FAILED, ALLOC_JCL_LINES);
        rc = -1;
        goto quit;
    }

    /* Analyze and potentially modify job card */
    char user[64] = {0};
    char password[256] = {0};

    if (get_caller_credentials(session, user, sizeof(user),
                                   password, sizeof(password)) < 0) {
        sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST, CATEGORY_SERVICE,
                        RC_ERROR, REASON_INVALID_REQUEST,
                        "Job submission requires an authenticated session with a password", NULL, 0);
        rc = -1;
        goto quit;
    }

    rc = process_jobcard(lines, num_lines, jobname, jobclass, user, password);
    memset(password, 0, sizeof(password));   /* scrub; it now lives on the card */
    if (rc == JOBCARD_ERR_TOO_LONG) {
        sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST, CATEGORY_SERVICE,
                        RC_ERROR, REASON_JOBCARD_TOO_LONG,
                        ERR_MSG_JOBCARD_TOO_LONG, NULL, 0);
        goto quit;
    }
    if (rc < 0) {
        sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST, CATEGORY_SERVICE,
                        RC_ERROR, REASON_INVALID_REQUEST,
                        "No valid JOB card found in submitted JCL", NULL, 0);
        goto quit;
    }

    // Submit all lines
    final_lines_count = rc;

    int submit_idx = 0;
    for (submit_idx = 0; submit_idx < final_lines_count; submit_idx++) {
        if (lines[submit_idx][0] != '\0') {  // Only submit non-empty lines
            rc = jesirput(intrdr, lines[submit_idx]);
            if (rc < 0) {
                wtof(MSG_INTRDR_WRITE);
                goto quit;
            }
        }
    }

    /* jesircl2() copies the jobid out between the ENDREQ and the close --
       the old read of intrdr->rpl.rplrbar after jesircls() fetched from the
       freed VSFILE (#296).  The handle is gone even on a close error, so
       drop the pointer right away instead of letting quit: close it again. */
    {
        unsigned char jobid_raw[8];

        rc = jesircl2(intrdr, jobid_raw);
        intrdr = NULL;
        if (rc < 0) {
            wtof(MSG_INTRDR_CLOSE);
            goto quit;
        }

        memcpy(jobid, jobid_raw, JOBID_STR_SIZE);
        jobid[JOBID_STR_SIZE] = '\0';
    }

    wtof(MSG_JOB_SUBMITTED, jobname, jobid);
    rc = 0;


quit:
	// Close internal reader if it was still opened
	if (intrdr)	 {
		jesircls(intrdr);
	}

    // Free all allocated memory
    if (lines) {
        free((void *) lines);
    }
    if (lines_buf) {
        free((void *) lines_buf);
    }

    if (ebcdic_content) {
        free((void *) ebcdic_content);
    }

    return rc;
}

