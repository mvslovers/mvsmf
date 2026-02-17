#include <clibary.h>
#include <clibio.h>
#include <clibstr.h>
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
#include <ufs/types.h>

#include "common.h"
#include "httpd.h"
#include "jobsapi.h"
#include "jobsapi_msg.h"
#include "json.h"
#include "router.h"
#include "xlate.h"

#define INITIAL_BUFFER_SIZE 4096
#define MAX_JOBS_LIMIT 1000
#define MAX_URL_LENGTH 256
#define MAX_ERR_MSG_LENGTH 256
#define MAX_JCL_LINES 5000

#define JES_INFO_SIZE   20 + 1
#define TYPE_STR_SIZE    3 + 1
#define CLASS_STR_SIZE   3 + 1
#define RECFM_STR_SIZE   4 + 1
#define JOBNAME_STR_SIZE 8      // the +1 for null termination will be added on initialization
#define JOBID_STR_SIZE   8      // the +1 for null termination will be added on initialization
#define DSNAME_STR_SIZE  44     // the +1 for null termination will be added on initialization

#define MIN_JES_SYSOUT_DSID 	  2
#define MAX_JES_SYSOUT_DSID 	  4
#define MIN_USER_SYSOUT_DSID 	100
#define MAX_USER_SYSOUT_DSID 	199

//
// private functions prototypes
//

/* TODO (MIG) refactor sysout stuff*/
static int  do_print_sysout(Session *session, JESJOB *job, unsigned dsid);

// needed by jobListHandler
static void process_job_list_filters(Session *session, const char **filter, JESFILT *jesfilt);
static unsigned get_max_jobs(Session *session);
static int  process_job(JsonBuilder *builder, JESJOB *job, const char *owner, const char *host);
static JESJOB* find_job_by_name_and_id(Session *session, const char *jobname, const char *jobid);
static int process_job_files(Session *session, JESJOB *job, const char *host, JsonBuilder *builder);
static int validate_intrdr_headers(Session *session);
static int submit_jcl_content(Session *session, VSFILE *intrdr, const char *content, size_t content_length, 
                              char *jobname, char *jobid, char *jobclass);
static const char *extract_file_value(char *json, size_t len);
static int submit_file(Session *session, VSFILE *intrdr, const char *filename,
                       char *jobname, char *jobid, char *jobclass);
static int read_request_content(Session *session, char **content, size_t *content_size);
static char* tokenize(char *str, const char *delim, char **saveptr);
static int process_jobcard(char **lines, int num_lines, char *jobname, char *jobclass, 
                          const char *user, const char *password);

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

	if (owner == NULL) {
		owner = getHeaderParam(session, "CURRENT_USER");
	}

	if (owner[0] == '*') {
		owner = NULL;
	}

	process_job_list_filters(session, &filter, &jesfilt);

	jes = jesopen();
	if (!jes) {
		wtof(MSG_JOB_JES_ERROR);
		sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR, CATEGORY_VSAM,
						RC_SEVERE, REASON_INCORRECT_JES_VSAM_HANDLE,
						ERR_MSG_INCORRECT_JES_VSAM_HANDLE, NULL, 0);
		goto quit;
	}

	joblist = jesjob(jes, filter, jesfilt, 0);

	startArray(builder);

	int ii = 0;
	for (ii = 0; ii < MIN(max_jobs, array_count(&joblist)); ii++) {
		rc = process_job(builder, joblist[ii], owner, host);
		if (rc < 0) {
			goto quit;
		}
	}

	endArray(builder);

	sendJSONResponse(session, HTTP_STATUS_OK, builder);

quit:
	if (builder) {
		freeJsonBuilder(builder);
	}

	if (jes) {
		jesclose(&jes);
	}

	return 0;
}

int 
jobFilesHandler(Session *session) 
{
	int rc = 0;
	
	JESJOB *job = NULL;

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

	job = find_job_by_name_and_id(session, jobname, jobid);
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

	const char *jobname = getPathParam(session, "job-name");
	const char *jobid = getPathParam(session, "jobid");
	const char *ddid = getPathParam(session, "ddid");

	if (!jobname || !jobid || !ddid) {
		sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR, CATEGORY_UNEXPECTED,
						RC_SEVERE, REASON_SERVER_ERROR, ERR_MSG_SERVER_ERROR, 
						NULL, 0);
		return rc;
	}

	job = find_job_by_name_and_id(session, jobname, jobid);
	if (!job) {
		char msg[MAX_ERR_MSG_LENGTH] = {0};
		rc = snprintf(msg, sizeof(msg), ERR_MSG_JOB_NOT_FOUND, jobname, jobid);
		sendErrorResponse(session, HTTP_STATUS_NOT_FOUND, CATEGORY_SERVICE,
						RC_WARNING, REASON_JOB_NOT_FOUND,
						msg, NULL, 0);
		goto quit;
	}

	sendDefaultHeaders(session, HTTP_STATUS_OK, "text/plain", 0);
	
	char *endptr = NULL;
	long ddid_val = strtol(ddid, &endptr, DECIMAL_BASE);
	
	if (*endptr != '\0' || ddid_val < 0) {
		sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST, CATEGORY_SERVICE,
						RC_ERROR, REASON_INVALID_QUERY,
						"Invalid DDID parameter", NULL, 0);
		goto quit;
	}

	rc = do_print_sysout(session, job, (unsigned)ddid_val);
	if (rc < 0) {
		// TODO (MIG) check if this will work, fater already sending default headers
		sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
						CATEGORY_UNEXPECTED, RC_SEVERE, REASON_SERVER_ERROR,
						ERR_MSG_SERVER_ERROR, NULL, 0);
		goto quit;
	}

quit:
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

	JESJOB 	*job = NULL;

	// Get jobname and jobid from request
	const char *jobname = getPathParam(session, "job-name");
	const char *jobid = getPathParam(session, "jobid");

	JsonBuilder *builder = createJsonBuilder();

	if (!jobname || !jobid) {
		sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST, CATEGORY_UNEXPECTED,
						  RC_SEVERE, REASON_SERVER_ERROR, ERR_MSG_SERVER_ERROR, 
						  NULL, 0);
		goto quit;
	}

	job = find_job_by_name_and_id(session, jobname, jobid);
	if (!job) {
		char msg[MAX_ERR_MSG_LENGTH] = {0};
		rc = snprintf(msg, sizeof(msg), ERR_MSG_JOB_NOT_FOUND, jobname, jobid);
		sendErrorResponse(session, HTTP_STATUS_NOT_FOUND, CATEGORY_SERVICE,
						RC_WARNING, REASON_JOB_NOT_FOUND,
						msg, NULL, 0);
		goto quit;
	}

	// Purge the job
	rc = jescanj(jobname, jobid, 1);

	switch (rc) {
	case CANJ_OK:
		rc = startJsonObject(builder);

		rc = addJsonString(builder, "owner", (const char *) job->owner);
		rc = addJsonString(builder, "jobid", jobid);
		rc = addJsonString(builder, "message", "Request was successful.");
		rc = addJsonString(builder, "original-jobid", jobid);
		rc = addJsonString(builder, "jobname", jobname);
		rc = addJsonNumber(builder, "status", 0);
		
		rc = endJsonObject(builder);
		if (rc < 0) {
			goto quit;
		}

		sendJSONResponse(session, HTTP_STATUS_OK, builder);
		
		break;
	case CANJ_ICAN:
		sendErrorResponse(session, HTTP_STATUS_FORBIDDEN, CATEGORY_SERVICE,
							RC_WARNING, REASON_STC_PURGE, ERR_MSG_STC_PURGE, 
							NULL, 0);

		break;
	default:
		// TODO (MIG) - adding details to the error message (different rc's) and a new error message in jobsapi_msg.h
		wtof("MVSMF42D JESCANJ got RC(%d)", rc);
		sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR, CATEGORY_UNEXPECTED,
							RC_SEVERE, REASON_SERVER_ERROR, ERR_MSG_SERVER_ERROR, 
							NULL, 0);
		break;
	}

quit:
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

	/* open internal reader */
	rc = jesiropn(&intrdr);
	if (rc < 0) {
		wtof("MVSMF22E Unable to open JES internal reader");
		sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR, CATEGORY_SERVICE,
						RC_SEVERE, REASON_SERVER_ERROR,
						"Failed to open internal reader", NULL, 0);
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

		if (is_json) {
			/* convert ASCII request body to EBCDIC so strstr/strchr work */
			mvsmf_atoe((unsigned char *)data, data_size);

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

__asm__("\n&FUNC	SETC 'do_print_sysout_line'");
static int 
do_print_sysout_line(const char *line, unsigned linelen) 
{
	int rc = 0;

// we do not have httpr in this function,
// so we have to use httpd
#undef httpx
#define httpx httpd->httpx

	CLIBGRT *grt = __grtget();
	HTTPD *httpd = grt->grtapp1;
	HTTPC *httpc = grt->grtapp2;

	rc = http_printf(httpc, "%-*.*s\r\n", linelen, linelen, line);

// switch back to httpr
#undef httpx
#define httpx session->httpd->httpx

	return rc;
}

__asm__("\n&FUNC	SETC 'do_print_sysout'");
static int 
do_print_sysout(Session *session, JESJOB *job, unsigned dsid) 
{
	int rc = 0;

	JES *jes = NULL;

	jes = jesopen();
	if (!jes) {
		wtof(MSG_JOB_JES_ERROR);
		goto quit;
	}

	unsigned ii = 0;
	for (ii = 0; ii < array_count(&job->jesdd); ii++) {
		JESDD *dd = job->jesdd[ii];

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

		rc = jesprint(jes, job, dd->dsid, do_print_sysout_line);
		if (rc < 0) {
			goto quit;
		}

		rc = http_printf(session->httpc, "- - - - - - - - - - - - - - - - - - - - "
										"- - - - - - - - - - - - - - - - - - - - "
										"- - - - - - - - - - - - - - - - - - - - "
										"- - - - - -\r\n");
		if (rc < 0) {
			goto quit;
		}
	}

quit:
	if (jes) {
		jesclose(&jes);
	}	

	return rc;
}

__asm__("\n&FUNC	SETC 'process_job_list_filters'");
static void 
process_job_list_filters(Session *session, const char **filter, JESFILT *jesfilt) 
{
	const char *prefix = getQueryParam(session, "prefix");
	const char *status = getQueryParam(session, "status");
	const char *jobid  = getQueryParam(session, "jobid");

	if (prefix && prefix[0] == '*') {
		prefix = NULL;
	}

	if (status && status[0] == '*') {
		status = NULL;
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
should_skip_job(const JESJOB *job, const char *owner) 
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

	return 0;
}

__asm__("\n&FUNC	SETC 'process_job'");
static int 
process_job(JsonBuilder *builder, JESJOB *job, const char *owner, const char *host) 
{
	int rc = 0;

	const char *host_str = host ? host : "127.0.0.1:8080";

	char type_str[TYPE_STR_SIZE];
	char class_str[CLASS_STR_SIZE];
	char url_str[MAX_URL_LENGTH];
	char files_url_str[MAX_URL_LENGTH];
	char *stat_str = "UNKNOWN";

	if (should_skip_job(job, owner)) {
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
					"http://%s/zosmf/restjobs/jobs/%s/%s", host_str, job->jobname, job->jobid);
	
	// files_url is the full url to the job sysout files
	rc = snprintf(files_url_str, sizeof(files_url_str), "%s/files", url_str);

	if (rc < 0) {
		wtof("MVSMF19E internal error");
		return -1;
	}

	if (job->q_type) {
		if (job->q_type & _XEQ) {
			stat_str = "ACTIVE";
		} else if (job->q_type & _INPUT) {
			stat_str = "INPUT";
		} else if (job->q_type & _XMIT) {
			stat_str = "XMIT";
		} else if (job->q_type & _SETUP) {
			stat_str = "SETUP";
		} else if (job->q_type & _RECEIVE) {
			stat_str = "RECEIVE";
		} else if (job->q_type & _OUTPUT || job->q_type & _HARDCPY) {
			stat_str = "OUTPUT";
		} else {
			stat_str = "UNKNOWN";
		}
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
	   before execution (converter RC):   4 = JCL error, 8 = I/O error, 36 = abend */
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
			} else if ((job->jtflg & JESJOB_ABD) && maxcc) {
				snprintf(retcode_buf, sizeof(retcode_buf), "ABEND U%04d", maxcc);
			} else {
				snprintf(retcode_buf, sizeof(retcode_buf), "CC %04d", maxcc);
			}
			retcode = retcode_buf;
		} else if (comp == 4 || comp == 8 || comp == 36) {
			/* JCL converter error */
			retcode = "JCL ERROR";
		}
	}
	rc = addJsonString(builder, "retcode", retcode);
	
	rc = endJsonObject(builder);

	return rc;
}

__asm__("\n&FUNC    SETC 'find_job_by_name_and_id'");
static 
JESJOB* find_job_by_name_and_id(Session *session, const char *jobname, const char *jobid) 
{
	int job_found = 0;
	
	JES *jes = NULL;

	JESJOB *found_job = NULL;
	JESJOB **joblist = NULL;
	JESFILT jesfilt = FILTER_JOBID;
	const char *filter = jobid;

	if (!jobname || !jobid) {
		wtof("MVSMF22E Invalid parameters for find_job_by_name_and_id");
		goto quit;
	}

	jes = jesopen();
	if (!jes) {
		wtof(MSG_JOB_JES_ERROR);
		goto quit;
	}

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
			wtof("MVSMF22E More than one job found for reference: '%s(%s)'", jobname, jobid);
			goto quit;
		}

		found_job = job;
	}

quit:
	if (jes) {
		jesclose(&jes);
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
                    "http://%s/zosmf/restjobs/jobs/%s/%s/files/%d/records", 
                    host_str, job->jobname, job->jobid, dd->dsid);

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
        wtof("MVSMF22E Invalid intrdr_mode - must be TEXT");
        return -1;
    }

    const char *intrdr_lrecl = getHeaderParam(session, "X-IBM-Intrdr-Lrecl");
    if (intrdr_lrecl != NULL && strcmp(intrdr_lrecl, "80") != 0) {
        wtof("MVSMF22E Invalid intrdr_lrecl - must be 80");
        return -1;
    }

    const char *intrdr_recfm = getHeaderParam(session, "X-IBM-Intrdr-Recfm");
    if (intrdr_recfm != NULL && strcmp(intrdr_recfm, "F") != 0) {
        wtof("MVSMF22E Invalid intrdr_recfm - must be F");
        return -1;
    }

    return 0;
}

__asm__("\n&FUNC	SETC 'receive_raw_data'");
static int
receive_raw_data(HTTPC *httpc, char *buf, int len)
{
	int total_bytes_received = 0;
	int bytes_received = 0;
	int sockfd = 0;
	int retries = 0;
	unsigned ecb = 0;

	sockfd = httpc->socket;
	while (total_bytes_received < len) {
		/*
		 * Workaround: Limit recv() to 2048 bytes per call.
		 * The MVS 3.8j TCP/IP stack appears to have a bug in its
		 * internal 2048-byte ring buffer that causes data corruption
		 * (replaying earlier data) when recv() is called with a
		 * request size larger than 2048 bytes.
		 */
		int request = len - total_bytes_received;
		if (request > 2048) request = 2048;
		bytes_received = recv(sockfd, buf + total_bytes_received, request, 0);
		if (bytes_received < 0) {
			if (errno == EINTR) {
				continue;
			}
			if (errno == EWOULDBLOCK) {
				if (++retries > 200) {
					wtof("MVSMF22E recv() EWOULDBLOCK timeout after %d retries", retries);
					return -1;
				}
				ecb = 0;
				cthread_timed_wait((void *)&ecb, 5, 0);
				continue;
			}
			return -1;
		}

		if (bytes_received == 0) {
			break;
		}
		retries = 0;
		total_bytes_received += bytes_received;
	}

	return total_bytes_received;
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

	buffer_size = fp->lrecl + 2;
	buffer = calloc(1, buffer_size);
	if (!buffer) {
		sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
						CATEGORY_UNEXPECTED, RC_SEVERE, REASON_SERVER_ERROR,
						ERR_MSG_SERVER_ERROR, NULL, 0);
		rc = -1;
		goto quit;
	}

	/* allocate lines array — all MAX_JCL_LINES slots, because
	   process_jobcard() adds USER/PASSWORD lines beyond num_lines */
	lines = (char **)calloc(MAX_JCL_LINES, sizeof(char *));
	lines_buf = (char *) calloc(MAX_JCL_LINES, 81);
	if (!lines || !lines_buf) {
		sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
						CATEGORY_UNEXPECTED, RC_SEVERE, REASON_SERVER_ERROR,
						ERR_MSG_SERVER_ERROR, NULL, 0);
		rc = -1;
		goto quit;
	}
	{
		int alloc_idx = 0;
		for (alloc_idx = 0; alloc_idx < MAX_JCL_LINES; alloc_idx++) {
			lines[alloc_idx] = lines_buf + (alloc_idx * 81);
		}
	}

	/* read dataset into lines array */
	while (fgets(buffer, (int)buffer_size, fp) > 0 && num_lines < MAX_JCL_LINES) {
		size_t line_len = strlen(buffer);

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

	if (num_lines >= MAX_JCL_LINES &&
		fgets(buffer, (int)buffer_size, fp) > 0) {
		wtof("MVSMF22E JCL too large, truncated at %d lines",
			MAX_JCL_LINES);
		fclose(fp);
		fp = NULL;
		rc = -1;
		goto quit;
	}

	fclose(fp);
	fp = NULL;

	/* process jobcard: inject USER/PASSWORD */
	{
		const char *user = getHeaderParam(session, "CURRENT_USER");
		const char *password = getHeaderParam(session, "CURRENT_PASSWORD");

		rc = process_jobcard(lines, num_lines, jobname, jobclass, user, password);
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
					wtof("MVSMF22E Failed to write to internal reader");
					sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
									CATEGORY_UNEXPECTED, RC_SEVERE, REASON_SERVER_ERROR,
									ERR_MSG_SERVER_ERROR, NULL, 0);
					goto quit;
				}
			}
		}
	}

	/* close internal reader and retrieve jobid */
	rc = jesircls(intrdr);
	if (rc < 0) {
		wtof("MVSMF22E Failed to close internal reader");
		sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
						CATEGORY_UNEXPECTED, RC_SEVERE, REASON_SERVER_ERROR,
						ERR_MSG_SERVER_ERROR, NULL, 0);
		goto quit;
	}

	strncpy(jobid, (const char *)intrdr->rpl.rplrbar, JOBID_STR_SIZE);
	jobid[JOBID_STR_SIZE] = '\0';

	wtof("MVSMF30I JOB %s(%s) SUBMITTED", jobname, jobid);
	rc = 0;

	intrdr = NULL;

quit:
	if (intrdr) {
		jesircls(intrdr);
	}

	if (fp) {
		fclose(fp);
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

__asm__("\n&FUNC    SETC 'read_request_content'");
static 
int read_request_content(Session *session, char **content, size_t *content_size) 
{
    int rc = 0;
    size_t buffer_size = 0;
    int bytes_received = 0;
    char recv_buffer[1024];
    int has_content_length = 0;
    size_t content_length = 0;
    int is_chunked = 0;
    int done = 0;

    // Check Content-Length header
    const char *content_length_str = getHeaderParam(session, "Content-Length");
    if (content_length_str != NULL) {
        has_content_length = 1;
        content_length = strtoul(content_length_str, NULL, 10);
    }

    // Check Transfer-Encoding header
    const char *transfer_encoding = getHeaderParam(session, "Transfer-Encoding");
    if (transfer_encoding != NULL && strstr(transfer_encoding, "chunked") != NULL) {
        is_chunked = 1;
    }

    if (!is_chunked && !has_content_length) {
        wtof("MVSMF22E Missing Content-Length or Transfer-Encoding header");
        return -1;
    }

    // Allocate initial buffer
    *content = malloc(INITIAL_BUFFER_SIZE);
    if (!*content) {
        wtof("MVSMF22E Memory allocation failed for content buffer");
        return -1;
    }
    buffer_size = INITIAL_BUFFER_SIZE;
    *content_size = 0;

    if (is_chunked) {
        while (!done) {
            char chunk_size_str[10];
            int i = 0;

            /* Read chunk size line (hex + CRLF) */
            while (i < sizeof(chunk_size_str) - 1) {
                if (receive_raw_data(session->httpc, chunk_size_str + i, 1) != 1) {
                    return -1;
                }
                if (chunk_size_str[i] == '\r') {
                    chunk_size_str[i] = '\0';
                    receive_raw_data(session->httpc, chunk_size_str + i, 1);
                    break;
                }
                i++;
            }

            mvsmf_atoe((unsigned char *)chunk_size_str, sizeof(chunk_size_str));
            {
                int chunk_size = strtoul(chunk_size_str, NULL, 16);
                int bytes_read = 0;

                if (chunk_size == 0) {
                    done = 1;
                    break;
                }

                /* Ensure buffer capacity */
                if (*content_size + chunk_size > buffer_size) {
                    char *new_content = realloc(*content, *content_size + chunk_size + 1);
                    if (!new_content) {
                        wtof("MVSMF22E Memory reallocation failed");
                        free((void *) *content);
                        *content = NULL;
                        return -1;
                    }
                    *content = new_content;
                    buffer_size = *content_size + chunk_size;
                }

                /* Read chunk data */
                while (bytes_read < chunk_size) {
                    bytes_received = receive_raw_data(session->httpc,
                                       *content + *content_size + bytes_read,
                                       chunk_size - bytes_read);
                    if (bytes_received <= 0) {
                        return -1;
                    }
                    bytes_read += bytes_received;
                }

                *content_size += chunk_size;
            }

            /* Consume trailing CRLF after chunk data */
            {
                char crlf[2];
                if (receive_raw_data(session->httpc, crlf, 2) != 2) {
                    return -1;
                }
            }
        }
    } else {
        while (*content_size < content_length) {
            if (*content_size + sizeof(recv_buffer) > buffer_size) {
                char *new_content = realloc(*content, buffer_size * 2);
                if (!new_content) {
                    wtof("MVSMF22E Memory reallocation failed");
                    free((void *) *content);
                    *content = NULL;
                    return -1;
                }
                *content = new_content;
                buffer_size *= 2;
            }

            bytes_received = receive_raw_data(session->httpc, *content + *content_size,
                               content_length - *content_size < sizeof(recv_buffer)
                                   ? content_length - *content_size
                                   : sizeof(recv_buffer));

            if (bytes_received <= 0) {
                return -1;
            }

            *content_size += bytes_received;
        }
    }

    // Ensure null termination
    if (*content_size + 1 > buffer_size) {
        char *new_content = realloc(*content, *content_size + 1);
        if (!new_content) {
            wtof("MVSMF22E Memory reallocation failed");
            free((void *) *content);
            *content = NULL;
            return -1;
        }
        *content = new_content;
    }
    (*content)[*content_size] = '\0';

    return 0;
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

    rc = process_job(builder, job, NULL, host);
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

    if (!jobname || !jobid) {
        sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST, CATEGORY_UNEXPECTED,
                      RC_SEVERE, REASON_SERVER_ERROR, ERR_MSG_SERVER_ERROR, 
                      NULL, 0);
        rc = -1;
	   	goto quit;
    }

    job = find_job_by_name_and_id(session, jobname, jobid);
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

__asm__("\n&FUNC    SETC 'process_jobcard'");
static int
process_jobcard(char **lines, int num_lines, char *jobname, char *jobclass, 
               const char *user, const char *password) 
{
    int rc = -1;
    char **temp_lines = NULL;
    char *temp_lines_buf = NULL;
    int start_idx = -1;
    int end_idx = -1;
    int out_line = 0;
    int notify_replaced = 0;

    if (!lines || num_lines <= 0 || !jobname || !jobclass || !user) {
        wtof("MVSMF22E Invalid parameters for process_jobcard");
        return rc;
    }

    if (!password) {
        wtof("MVSMF22E Password is required for user %s", user);
        return rc;
    }

    // Find the job card range
    find_job_card_range(lines, num_lines, &start_idx, &end_idx);
    if (start_idx < 0 || end_idx < 0) {
        wtof("MVSMF22E No valid JOB card found");
        return rc;
    }

    // Extract jobname from first line (columns 3-10)
    const char *first_line = lines[start_idx];
    if (!first_line) {
        wtof("MVSMF22E First line is NULL");
        return rc;
    }

    size_t first_line_len = strlen(first_line);
    if (first_line_len < 3) {
        wtof("MVSMF22E First line too short");
        return rc;
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

    // Allocate temporary lines array (contiguous buffer)
    temp_lines = (char **)calloc(MAX_JCL_LINES, sizeof(char *));
    temp_lines_buf = (char *) calloc(MAX_JCL_LINES, 81);
    if (!temp_lines || !temp_lines_buf) {
        wtof("MVSMF22E Memory allocation failed for temp lines");
        return rc;
    }
    for (ii = 0; ii < MAX_JCL_LINES; ii++) {
        temp_lines[ii] = temp_lines_buf + (ii * 81);
    }

    // Process job card lines
    for (ii = start_idx; ii <= end_idx; ii++) {
        if (!lines[ii]) {
            wtof("MVSMF22E NULL line at index %d", ii);
            goto cleanup;
        }

        char temp_line[81] = {0};
        strncpy(temp_line, lines[ii], 80);

        // Replace &SYSUID with actual user if present and not already replaced
        if (!notify_replaced) {
            char *notify_start = strstr(temp_line, "NOTIFY");
            if (notify_start) {
                char *equals = strchr(notify_start, '=');
                if (equals) {
                    // Skip any whitespace after the equals sign
                    char *sysuid = equals + 1;
                    while (*sysuid == ' ') sysuid++;
                    
                    if (strncmp(sysuid, "&SYSUID", 7) == 0) {
                        char before[80] = {0};
                        char after[80] = {0};
                        size_t notify_offset = notify_start - temp_line;
                        
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
                                    wtof("MVSMF21E Buffer overflow in snprintf");
                                    goto cleanup;
                                }
                            }
                        }
                        
                        // Combine parts with actual user
                        rc = snprintf(temp_lines[out_line], 72, "%sNOTIFY=%s%s",
                                    before, user, after);
                        if (rc < 0 || rc >= 72) {
                            wtof("MVSMF22E Buffer overflow in snprintf");
                            goto cleanup;
                        }
                        notify_replaced = 1;
                    } else {
                        strncpy(temp_lines[out_line], temp_line, 80);
                    }
                } else {
                    strncpy(temp_lines[out_line], temp_line, 80);
                }
            } else {
                strncpy(temp_lines[out_line], temp_line, 80);
            }
        } else {
            strncpy(temp_lines[out_line], temp_line, 80);
        }
        temp_lines[out_line][80] = '\0';

        // For last job card line, ensure it ends with comma
        if (ii == end_idx) {
            size_t len = strlen(temp_lines[out_line]);
            while (len > 0 && temp_lines[out_line][len-1] == ' ') {
                len--;
            }
            if (len > 0 && temp_lines[out_line][len-1] != ',') {
                if (len >= 70) {
                    wtof("MVSMF22E No space for comma at end of job card");
                    goto cleanup;
                }
                temp_lines[out_line][len++] = ',';
                temp_lines[out_line][len] = '\0';
            }
        }
        out_line++;
    }

    // Add USER and PASSWORD parameters
    rc = snprintf(temp_lines[out_line], 72, "//         USER=%s,", user);
    if (rc < 0 || rc >= 72) {
        wtof("MVSMF23E Buffer overflow in snprintf ");
        goto cleanup;
    }
    out_line++;

    rc = snprintf(temp_lines[out_line], 72, "//         PASSWORD=%s", password);
    if (rc < 0 || rc >= 72) {
        wtof("MVSMF24E Buffer overflow in snprintf");
        goto cleanup;
    }
    out_line++;

    // Copy remaining JCL statements
    for (ii = end_idx + 1; ii < num_lines; ii++) {
        if (!lines[ii]) {
            wtof("MVSMF22W Skipping NULL line at index %d", ii);
            continue;
        }
        
        if (out_line >= MAX_JCL_LINES) {
            wtof("MVSMF22E Too many lines in JCL (max %d)", MAX_JCL_LINES);
            rc = -1;
            goto cleanup;
        }

        strncpy(temp_lines[out_line], lines[ii], 80);
        temp_lines[out_line][80] = '\0';
        out_line++;
    }

    // Copy temp lines back to original array
    for (ii = 0; ii < out_line; ii++) {
        strncpy(lines[ii], temp_lines[ii], 80);
        lines[ii][80] = '\0';
    }

    rc = out_line;

cleanup:
    if (temp_lines) {
        free(temp_lines);
    }
    if (temp_lines_buf) {
        free(temp_lines_buf);
    }

    return rc;
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
    char **modified_lines = NULL;
    char *modified_lines_buf = NULL;
    int num_lines = 0;
    int modified_lines_count = 0;
    
    *jobclass = 'A';
    memset(jobname, 0, JOBNAME_STR_SIZE + 1);
    memset(jobid, 0, JOBID_STR_SIZE + 1);

    ebcdic_content = strdup(content);
    if (!ebcdic_content) {
        wtof("MVSMF22E Memory allocation failed for EBCDIC conversion");
        rc = -1;
        goto quit;
    }

    mvsmf_atoe((unsigned char *)ebcdic_content, content_length);

    /* Allocate lines array + contiguous buffer */
    lines = (char **) calloc(MAX_JCL_LINES, sizeof(char *));
    lines_buf = (char *) calloc(MAX_JCL_LINES, 81);
    if (!lines || !lines_buf) {
        wtof("MVSMF22E Memory allocation failed for lines array");
        rc = -1;
        goto quit;
    }
    {
        int li;
        for (li = 0; li < MAX_JCL_LINES; li++) {
            lines[li] = lines_buf + (li * 81);
        }
    }

    char delimiter[2] = {EBCDIC_LF, '\0'}; // EBCDIC Line Feed
    char *saveptr = NULL;
    char *line = tokenize(ebcdic_content, delimiter, &saveptr);

    // Collect all lines
    while (line != NULL && num_lines < MAX_JCL_LINES) {
        size_t line_len = strlen(line);

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

    if (line != NULL) {
        wtof("MVSMF22E JCL too large, truncated at %d lines", MAX_JCL_LINES);
        rc = -1;
        goto quit;
    }

    /* Analyze and potentially modify job card */
    const char *user = getHeaderParam(session, "CURRENT_USER");
    const char *password = getHeaderParam(session, "CURRENT_PASSWORD");
    
    // Allocate memory for modified job card lines (contiguous buffer)
    modified_lines = (char **)calloc(MAX_JCL_LINES, sizeof(char *));
    modified_lines_buf = (char *) calloc(MAX_JCL_LINES, 81);
    if (!modified_lines || !modified_lines_buf) {
        wtof("MVSMF22E Memory allocation failed for modified lines");
        rc = -1;
        goto quit;
    }
    {
        int mi;
        for (mi = 0; mi < MAX_JCL_LINES; mi++) {
            modified_lines[mi] = modified_lines_buf + (mi * 81);
        }
    }

    // Copy original lines to modified lines
    int copy_idx = 0;
    for (copy_idx = 0; copy_idx < num_lines; copy_idx++) {
        strncpy(modified_lines[copy_idx], lines[copy_idx], 80);
        modified_lines[copy_idx][80] = '\0';
    }
    
    rc = process_jobcard(modified_lines, num_lines, jobname, jobclass, user, password);
    if (rc < 0) {
        wtof("MVSMF22E Failed to analyze job card");
        goto quit;
    }

    // Submit all lines
    modified_lines_count = rc;

    int submit_idx = 0;
    for (submit_idx = 0; submit_idx < modified_lines_count; submit_idx++) {
        if (modified_lines[submit_idx][0] != '\0') {  // Only submit non-empty lines
            rc = jesirput(intrdr, modified_lines[submit_idx]);
            if (rc < 0) {
                wtof("MVSMF22E Failed to write to internal reader");
                goto quit;
            }
        }
    }

    rc = jesircls(intrdr);
	if (rc < 0) {
        wtof("MVSMF22E Failed to close internal reader");
        goto quit;
    }

    strncpy(jobid, (const char *)intrdr->rpl.rplrbar, JOBID_STR_SIZE);
    jobid[JOBID_STR_SIZE] = '\0';

    wtof("MVSMF30I JOB %s(%s) SUBMITTED", jobname, jobid);
    rc = 0;

	intrdr = NULL; 
    
quit:
	// Close internal reader if it was still opened
	if (intrdr)	 {
		wtof("MVSMF22E Emergency closing of INTRDR");
		jesircls(intrdr);
	}

    // Free all allocated memory
    if (modified_lines) {
        free((void *) modified_lines);
    }
    if (modified_lines_buf) {
        free((void *) modified_lines_buf);
    }
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

