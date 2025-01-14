#include <clibary.h>
#include <clibio.h>
#include <clibstr.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <clibjes2.h>
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

#define INITIAL_BUFFER_SIZE 4096
#define MAX_JOBS_LIMIT 1000
#define MAX_URL_LENGTH 256
#define MAX_ERR_MSG_LENGTH 256
#define MAX_JCL_LINES 1000  // Neue Konstante für maximale JCL Zeilen

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
static int submit_file(VSFILE *intrdr, const char *filename);
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

	// Validate internal reader headers
	rc = validate_intrdr_headers(session);
	if (rc < 0) {
		sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST, CATEGORY_SERVICE,
						RC_ERROR, REASON_INVALID_QUERY,
						"Invalid internal reader parameters", NULL, 0);
		goto quit;
	}

	// Open internal reader
	rc = jesiropn(&intrdr);
	if (rc < 0) {
		wtof("MVSMF22E Unable to open JES internal reader");
		sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR, CATEGORY_SERVICE,
						RC_SEVERE, REASON_SERVER_ERROR,
						"Failed to open internal reader", NULL, 0);
		goto quit;
	}

	// Read request content
	rc = read_request_content(session, &data, &data_size);
	if (rc < 0) {
		sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST, CATEGORY_SERVICE,
						RC_ERROR, REASON_INVALID_REQUEST,
						"Failed to read request content", NULL, 0);
		goto quit;
	}

	// Submit JCL content
	rc = submit_jcl_content(session, intrdr, data, data_size, jobname, jobid, &jobclass);
	if (rc < 0) {
		goto quit;
	}

	const char *host = getHeaderParam(session, "HOST");
	rc = find_and_send_job_status(session, jobname, jobid, host);

quit:
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
	rc = addJsonString(builder, "retcode", "n/a");
	
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

	sockfd = httpc->socket;
	while (total_bytes_received < len) {
		bytes_received = recv(sockfd, buf + total_bytes_received, len - total_bytes_received, 0);
		if (bytes_received < 0) {
			if (errno == EINTR) {
				// Interrupted by a signal, retry
				continue;
			} 
			// An error occurred
			return -1;
			
		} 
		
		if (bytes_received == 0) {
			// Connection closed by the client
			break;
		}
		total_bytes_received += bytes_received;
	}

	return total_bytes_received;
}

__asm__("\n&FUNC	SETC 'submit_file'");
static int 
submit_file(VSFILE *intrdr, const char *filename) 
{
	int rc = 0;

	FILE *fp = NULL;
	
	char *buffer = NULL;
	size_t buffer_size = 0;

	char dsname[DSNAME_STR_SIZE + 1];

	size_t len = strlen(filename);
	if (len > 4 && filename[0] == '/' && filename[1] == '/' &&
		filename[2] == '\'' && filename[len - 1] == '\'') {
		// strip leading " //' " and trailing " ' "
		strncpy(dsname, &filename[3], len - 4);
		dsname[len - 4] = '\0'; // Nullterminator hinzufügen
	} else {
		// TODO (MIG) - return HTTP 400 error and / or a defined json error object
		wtof("invalid filename %s", filename);
		rc = -1;
		goto quit;
	}

	fp = fopen(dsname, "re");
	if (!fp) {
		// TODO (MIG) - return HTTP 404 error and / or a defined json error object
		goto quit;
	}

	buffer_size = fp->lrecl + 2;
	buffer = calloc(1, buffer_size);

	if (!buffer) {
		// TODO (MIG) - return HTTP error 500
		rc = fclose(fp);
		goto quit;
	}

	while (fgets(buffer, (int)buffer_size, fp) > 0) {
		// TODO (MIG) - extract jobname and jobclass from the first line of the file
		rc = jesirput(intrdr, buffer);
		if (rc < 0) {
			// TODO (MIG) - return HTTP error 500
			rc = fclose(fp);
			goto quit;
		}
	}

	free(buffer);
	rc = fclose(fp);

quit:
	return 0;
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
    size_t bytes_received = 0;
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
        // Handle chunked transfer encoding
        while (!done) {
            // Read chunk size
            char chunk_size_str[10];
            int i = 0;
            while (i < sizeof(chunk_size_str) - 1) {
                if (receive_raw_data(session->httpc, chunk_size_str + i, 1) != 1) {
                    return -1;
                }
                if (chunk_size_str[i] == '\r') {
                    chunk_size_str[i] = '\0';
                    receive_raw_data(session->httpc, chunk_size_str + i, 1); // Read \n
                    break;
                }
                i++;
            }

            // Convert chunk size
            http_atoe((UCHAR *)chunk_size_str, sizeof(chunk_size_str));
            int chunk_size = strtoul(chunk_size_str, NULL, 16);

            if (chunk_size == 0) {
                done = 1;
                break;
            }

            // Ensure buffer capacity
            if (*content_size + chunk_size > buffer_size) {
                char *new_content = realloc(*content, *content_size + chunk_size + 1);
                if (!new_content) {
                    wtof("MVSMF22E Memory reallocation failed");
                    free(*content);
                    *content = NULL;
                    return -1;
                }
                *content = new_content;
                buffer_size = *content_size + chunk_size;
            }

            // Read chunk data
            size_t bytes_read = 0;
            while (bytes_read < chunk_size) {
                bytes_received = receive_raw_data(session->httpc, *content + *content_size + bytes_read,
                                   chunk_size - bytes_read);
                if (bytes_received <= 0) {
                    return -1;
                }
                bytes_read += bytes_received;
            }

            *content_size += chunk_size;

            // Read trailing CRLF
            char crlf[2];
            if (receive_raw_data(session->httpc, crlf, 2) != 2) {
                return -1;
            }
        }
    } else {
        // Handle content-length data
        while (*content_size < content_length) {
            if (*content_size + sizeof(recv_buffer) > buffer_size) {
                char *new_content = realloc(*content, buffer_size * 2);
                if (!new_content) {
                    wtof("MVSMF22E Memory reallocation failed");
                    free(*content);
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
            free(*content);
            *content = NULL;
            return -1;
        }
        *content = new_content;
    }
    (*content)[*content_size] = '\0';

    return 0;
}

__asm__("\n&FUNC    SETC 'process_jobcard'");
static int
process_jobcard(char **lines, int num_lines, char *jobname, char *jobclass, 
               const char *user, const char *password) 
{
    if (!lines || num_lines <= 0 || !jobname || !jobclass || !user) {
        wtof("MVSMF22E Invalid parameters for process_jobcard");
        return -1;
    }

    int found_job_card = 0;
    char *continuation = NULL;
    char *params_start = NULL;
    char modified_line[80];
    char temp_line[80];
    int total_lines = num_lines;  // Track total number of lines
    int current_line = 0;         // Current line being processed
    char **temp_lines = calloc(MAX_JCL_LINES, sizeof(char *));  // Temporary array for building output
    int idx;  // Generic index variable
    int job_card_end = 0;  // Index of last job card continuation line
    
    if (!temp_lines) {
        wtof("MVSMF22E Memory allocation failed for temp lines");
        return -1;
    }

    // Allocate memory for each line
    for (idx = 0; idx < MAX_JCL_LINES; idx++) {
        temp_lines[idx] = calloc(72, sizeof(char));
        if (!temp_lines[idx]) {
            int cleanup_idx;
            for (cleanup_idx = 0; cleanup_idx < idx; cleanup_idx++) {
                free(temp_lines[cleanup_idx]);
            }
            free(temp_lines);
            wtof("MVSMF22E Memory allocation failed for temp line");
            return -1;
        }
    }

    // Find end of job card (last continuation line)
    for (idx = 0; idx < num_lines; idx++) {
        if (idx == 0) {
            if (strncmp(lines[idx], "//", 2) != 0 || !strstr(lines[idx], " JOB ")) {
                goto cleanup;
            }
            job_card_end = idx;
            continue;
        }
        
        if (strncmp(lines[idx], "//", 2) == 0) {
            if (strncmp(lines[idx] + 2, " ", 1) == 0) {
                job_card_end = idx;  // This is a continuation line
            } else {
                break;  // This is the next statement
            }
        }
    }

    // Analyze first line for jobname and class
    if (strncmp(lines[0], "//", 2) != 0) {
        goto cleanup;
    }

    // Extract jobname
    int i;
    for (i = 2; lines[0][i] != ' ' && lines[0][i] != '\0' && i - 2 < 8; i++) {
        jobname[i - 2] = lines[0][i];
    }
    jobname[i - 2] = '\0';

    // Find JOB statement
    params_start = strstr(lines[0], " JOB ");
    if (!params_start) {
        goto cleanup;
    }
    found_job_card = 1;

    // Extract class and check for USER/PASSWORD
    char *class_param = strstr(lines[0], "CLASS=");
    if (class_param && strlen(class_param) > 6) {
        *jobclass = class_param[6];
    }

	wtof("job_card_end: %d", job_card_end);
	
    // Copy and process job card lines
    // First copy the JOB statement line and all continuation lines
    for (idx = 0; idx <= job_card_end; idx++) {
        if (idx == 0) {
            // Replace &SYSUID with actual user if present
            strncpy(temp_line, lines[idx], sizeof(temp_line) - 1);
            temp_line[sizeof(temp_line) - 1] = '\0';
            
            char *notify_start = strstr(temp_line, "NOTIFY");
            if (notify_start) {
                char *equals = strchr(notify_start, '=');
                if (equals) {
                    // Skip any whitespace after the equals sign
                    char *sysuid = equals + 1;
                    while (*sysuid == ' ') sysuid++;
                    
                    if (strncmp(sysuid, "&SYSUID", 7) == 0) {
                        size_t prefix_len = notify_start - temp_line;
                        snprintf(modified_line, 71, "%.*sNOTIFY=%s%s", 
                                (int)prefix_len, temp_line, user, sysuid + 7);
                        strncpy(temp_lines[current_line], modified_line, 71);
                    } else {
                        strncpy(temp_lines[current_line], temp_line, 71);
                    }
                } else {
                    strncpy(temp_lines[current_line], temp_line, 71);
                }
            } else {
                strncpy(temp_lines[current_line], temp_line, 71);
            }
        } else {
            strncpy(temp_lines[current_line], lines[idx], 71);
        }
        temp_lines[current_line][71] = '\0';
        current_line++;
    }

    // Add comma to last job card line if needed
    current_line--;  // Point to last job card line
    size_t len = strlen(temp_lines[current_line]);
    if (len > 0 && temp_lines[current_line][len-1] != ',') {
        temp_lines[current_line][len] = ',';
        temp_lines[current_line][len+1] = '\0';
    }
    current_line++;

    // Add USER and PASSWORD parameters
    snprintf(temp_lines[current_line], 71, "//         USER=%s,", user);
    current_line++;

    if (!password) {
        wtof("MVSMF22E Password is required for user %s", user);
        goto cleanup;
    }
    snprintf(temp_lines[current_line], 71, "//         PASSWORD=%s", password);
    current_line++;

    // Copy remaining JCL statements
    for (idx = job_card_end + 1; idx < num_lines; idx++) {
        if (!lines[idx]) {
            wtof("MVSMF22W Skipping NULL line at index %d", idx);
            continue;
        }
        
        if (current_line >= MAX_JCL_LINES) {
            wtof("MVSMF22E Too many lines in JCL (max %d)", MAX_JCL_LINES);
            goto cleanup;
        }

        strncpy(temp_lines[current_line], lines[idx], 71);
        temp_lines[current_line][71] = '\0';
        current_line++;
    }

    // Copy temp lines back to original array
    for (idx = 0; idx < current_line; idx++) {
        strncpy(lines[idx], temp_lines[idx], 71);
        lines[idx][71] = '\0';
    }

    wtof("MVSMF22D Job card lines: %d, Total lines: %d", current_line, current_line);

cleanup:
    // Cleanup temp lines
    for (idx = 0; idx < MAX_JCL_LINES; idx++) {
        free(temp_lines[idx]);
    }
    free(temp_lines);

    return found_job_card ? current_line : -1;
}

__asm__("\n&FUNC    SETC 'submit_jcl_content'");
static 
int submit_jcl_content(Session *session, VSFILE *intrdr, const char *content, size_t content_length, 
                      char *jobname, char *jobid, char *jobclass) 
{
    int rc = 0;
   
    *jobclass = 'A';
    memset(jobname, 0, JOBNAME_STR_SIZE + 1);
    memset(jobid, 0, JOBID_STR_SIZE + 1);

    char *ebcdic_content = strdup(content);
    if (!ebcdic_content) {
        wtof("MVSMF22E Memory allocation failed for EBCDIC conversion");
        return -1;
    }
    
    http_atoe((UCHAR *)ebcdic_content, content_length);

    // Split content into lines
    char *lines[MAX_JCL_LINES] = {0}; 
    int num_lines = 0;
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
        
        // Skip empty lines
        if (line_len == 0) {
            line = tokenize(NULL, delimiter, &saveptr);
            continue;
        }

        // Allocate and copy line
        char *line_copy = calloc(72, sizeof(char));
        if (!line_copy) {
            wtof("MVSMF22E Memory allocation failed for line copy");
            int cleanup_idx;
            for (cleanup_idx = 0; cleanup_idx < num_lines; cleanup_idx++) {
                free(lines[cleanup_idx]);
            }
            free(ebcdic_content);
            return -1;
        }

        strncpy(line_copy, line, 71);
        line_copy[71] = '\0';
        lines[num_lines++] = line_copy;
        
        line = tokenize(NULL, delimiter, &saveptr);
    }

    // Analyze and potentially modify job card
    const char *user = getHeaderParam(session, "CURRENT_USER");
    const char *password = getHeaderParam(session, "CURRENT_PASSWORD");
    
    // Allocate memory for modified job card lines
    char **modified_lines = calloc(MAX_JCL_LINES, sizeof(char *));
    if (!modified_lines) {
        wtof("MVSMF22E Memory allocation failed for modified lines");
        free(ebcdic_content);
        return -1;
    }

    int alloc_idx;
    for (alloc_idx = 0; alloc_idx < MAX_JCL_LINES; alloc_idx++) {
        modified_lines[alloc_idx] = calloc(72, sizeof(char));
        if (!modified_lines[alloc_idx]) {
            int free_idx;
            for (free_idx = 0; free_idx < alloc_idx; free_idx++) {
                free(modified_lines[free_idx]);
            }
            free(modified_lines);
            free(ebcdic_content);
            return -1;
        }
    }

    // Copy original lines to modified lines
    int copy_idx;
    for (copy_idx = 0; copy_idx < num_lines; copy_idx++) {
        strncpy(modified_lines[copy_idx], lines[copy_idx], 71);
        modified_lines[copy_idx][71] = '\0';
    }
    
    rc = process_jobcard(modified_lines, num_lines, jobname, jobclass, user, password);
    if (rc < 0) {
        wtof("MVSMF22E Failed to analyze job card");
        int cleanup_idx;
        for (cleanup_idx = 0; cleanup_idx < MAX_JCL_LINES; cleanup_idx++) {
            free(modified_lines[cleanup_idx]);
        }
        free(modified_lines);
        free(ebcdic_content);
        return rc;
    }

    // Submit all lines
    int modified_lines_count = rc;
    int submit_idx;
    for (submit_idx = 0; submit_idx < modified_lines_count; submit_idx++) {
        if (modified_lines[submit_idx][0] != '\0') {  // Only submit non-empty lines
            wtof("INTRDR > %s", modified_lines[submit_idx]);
            rc = jesirput(intrdr, modified_lines[submit_idx]);
            if (rc < 0) {
                wtof("MVSMF22E Failed to write to internal reader");
                int error_cleanup_idx;
                for (error_cleanup_idx = 0; error_cleanup_idx < MAX_JCL_LINES; error_cleanup_idx++) {
                    free(modified_lines[error_cleanup_idx]);
                }
                free(modified_lines);
                free(ebcdic_content);
                return rc;
            }
        }
    }

    // Cleanup
    int final_idx;
    for (final_idx = 0; final_idx < MAX_JCL_LINES; final_idx++) {
        free(modified_lines[final_idx]);
    }
    free(modified_lines);
    free(ebcdic_content);

    rc = jesircls(intrdr);
    if (rc < 0) {
        wtof("MVSMF22E Failed to close internal reader");
        return rc;
    }

    strncpy(jobid, (const char *)intrdr->rpl.rplrbar, JOBID_STR_SIZE);
    jobid[JOBID_STR_SIZE] = '\0';

    wtof("MVSMF30I JOB %s(%s) SUBMITTED", jobname, jobid);
    
    return rc;
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
