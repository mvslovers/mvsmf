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

#define JES_INFO_SIZE   20 + 1
#define TYPE_STR_SIZE    3 + 1
#define CLASS_STR_SIZE   3 + 1
#define RECFM_STR_SIZE   4 + 1
#define JOBNAME_STR_SIZE 8      // the +1 for null termination will be added on initialization
#define JOBID_STR_SIZE   8      // the +1 for null termination will be added on initialization

//
// private functions prototypes
//

/* TODO (MIG) refactor sysout stuff*/
static int  do_print_sysout(Session *session, JES *jes, JESJOB *job, unsigned dsid);

static void sanitize_jesinfo(const HASPCP *cp, char *jesinfo, size_t size);
static void process_job_list_filters(Session *session, const char **filter, JESFILT *jesfilt);
static int  process_job(JsonBuilder *builder, JESJOB *job, const char *owner, const char *host);
static int  submit_file(Session *session, VSFILE *intrdr, const char *filename);
static int  should_skip_job(const JESJOB *job, const char *owner);
static unsigned get_max_jobs(Session *session);
static JESJOB* find_job_by_name_and_id(Session *session, const char *jobname, const char *jobid, JES **jes_handle);
static int process_job_files(Session *session, JESJOB *job, const char *host, JsonBuilder *builder);

// TODO (MIG) remove these
static int _recv(HTTPC *httpc, char *buf, int len);
static int _send_response(Session *session, int status_code, const char *content_type, const char *data);

static const unsigned char ASCII_CRLF[] = {CR, LF};

// Add to private function prototypes
static int validate_intrdr_headers(Session *session);
static int submit_jcl_content(Session *session, VSFILE *intrdr, const char *content, size_t content_length);
static int read_request_content(Session *session, char **content, size_t *content_size);

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
	
	if (owner == NULL) {
		owner = getHeaderParam(session, "CURRENT_USER");
	}

	if (owner[0] == '*') {
		owner = NULL;
	}

	process_job_list_filters(session, &filter, &jesfilt);

	unsigned max_jobs = get_max_jobs(session);

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
	
	JES *jes = NULL;
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

	job = find_job_by_name_and_id(session, jobname, jobid, &jes);
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

	if (jes) {
		jesclose(&jes);
	}

	return 0;
}

int 
jobRecordsHandler(Session *session) 
{
	int rc = 0;

	JES *jes = NULL;
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

	job = find_job_by_name_and_id(session, jobname, jobid, &jes);
	if (!job) {
		char msg[MAX_ERR_MSG_LENGTH] = {0};
		rc = snprintf(msg, sizeof(msg), ERR_MSG_JOB_NOT_FOUND, jobname, jobid);
		sendErrorResponse(session, HTTP_STATUS_NOT_FOUND, CATEGORY_SERVICE,
						RC_WARNING, REASON_JOB_NOT_FOUND,
						msg, NULL, 0);
		goto quit;
	}

	sendDefaultHeaders(session, HTTP_STATUS_OK, "text/plain", 0);
	
	rc = do_print_sysout(session, jes, job, atoi(ddid));
	if (rc < 0) {
		// TODO (MIG) check if this will work, fater already sending default headers
		sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
						CATEGORY_UNEXPECTED, RC_SEVERE, REASON_SERVER_ERROR,
						ERR_MSG_SERVER_ERROR, NULL, 0);
		goto quit;
	}

quit:
	if (jes) {
		jesclose(&jes);
	}

	return rc;
}

int 
jobStatusHandler(Session *session) 
{
	int rc = 0;

	JES *jes = NULL;
	JESJOB *job = NULL;

	const char *host = getHeaderParam(session, "HOST");

	const char *jobname = getPathParam(session, "job-name");
	const char *jobid = getPathParam(session, "jobid");

	JsonBuilder *builder = createJsonBuilder();

	if (!jobname || !jobid) {
		sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST, CATEGORY_UNEXPECTED,
						  RC_SEVERE, REASON_SERVER_ERROR, ERR_MSG_SERVER_ERROR, 
						  NULL, 0);
		goto quit;
	}

	job = find_job_by_name_and_id(session, jobname, jobid, &jes);
	if (!job) {
		char msg[MAX_ERR_MSG_LENGTH] = {0};
		rc = snprintf(msg, sizeof(msg), ERR_MSG_JOB_NOT_FOUND, jobname, jobid);
		sendErrorResponse(session, HTTP_STATUS_NOT_FOUND, CATEGORY_SERVICE,
						RC_WARNING, REASON_JOB_NOT_FOUND,
						msg, NULL, 0);
		goto quit;
	}

	rc = process_job(builder, job, NULL, host);
	if (rc < 0) {
		goto quit;
	}

	sendJSONResponse(session, HTTP_STATUS_OK, builder);

quit:
	if (builder) {
		freeJsonBuilder(builder);
	}

	if (jes) {
		jesclose(&jes);
	}

	return rc;
}

int 
jobPurgeHandler(Session *session) 
{
	int rc = 0;

	JES		*jes = NULL;
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

	job = find_job_by_name_and_id(session, jobname, jobid, &jes);
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

	if (jes) {
		jesclose(&jes);
	}

	return 0;
}

int jobSubmitHandler(Session *session) 
{
	int rc = 0;
	
	VSFILE *intrdr = NULL;
	
	char *data = NULL;
	size_t data_size = 0;

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
	rc = submit_jcl_content(session, intrdr, data, data_size);

quit:
	if (data) {
		free(data);
	}
	
	return 0;
}

//
// private functions
//

__asm__("\n&FUNC	SETC 'ifdsid'");
static int
ifdsid(Session *session, unsigned dsid, unsigned **array) 
{
	int rc = 0;
	unsigned count;
	unsigned n;

	if (array) {
		/* match dsid against array of DSID's */
		count = array_count(&array);
		for (n = 0; n < count; n++) {
			unsigned id = (unsigned)array[n];
			if (!id)
				continue;

			if (dsid == id) {
				/* matched */
				rc = 1;
				break;
			}
		}
		goto quit;
	}

	/* no array of DSID's */
	if (dsid < 2)
		goto quit; /* don't show input JCL			*/
	if (dsid > 4 && dsid < 100)
		goto quit; /* don't show interpreted JCL	*/

	/* assume this dsid is okay */
	rc = 1;

quit:
	return rc;
}

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
do_print_sysout(Session *session, JES *jes, JESJOB *job, unsigned dsid) 
{
	int rc = 0;

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
	return rc;
}

__asm__("\n&FUNC	SETC 'submit_file'");
static int 
submit_file(Session *session, VSFILE *intrdr, const char *filename) 
{
	int rc = 0;

	FILE *fp;
	char *buffer;
	size_t buffer_size = 0;

	char dsname[44 + 1];

	size_t len = strlen(filename);
	if (len > 4 && filename[0] == '/' && filename[1] == '/' &&
		filename[2] == '\'' && filename[len - 1] == '\'') {
		// strip leading " //' " and trailing " ' "
		strncpy(dsname, &filename[3], len - 4);
		dsname[len - 4] = '\0'; // Nullterminator hinzufügen
	} else {
		// TODO: return HTTP 400 error and / or a defined json error object
		wtof("invalid filename %s", filename);
		rc = -1;
		goto quit;
	}

	fp = fopen(dsname, "r");
	if (!fp) {
		// TODO: return HTTP 404 error and / or a defined json error object
		wtof("submit_file: unable to open file %s", filename);
		rc = -1;
		goto quit;
	}

	buffer_size = fp->lrecl + 2;
	buffer = calloc(1, buffer_size);

	if (!buffer) {
		fclose(fp);
		rc = -1;
		goto quit;
	}

	while (fgets(buffer, buffer_size, fp) > 0) {
		// TODO: extract jobname and jobclass from the first line of the file
		rc = jesirput(intrdr, buffer);
		// jesirput(intrdr, "FOO");
	}

	free(buffer);
	fclose(fp);

quit:
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

__asm__("\n&FUNC	SETC 'sanitize_jesinfo'");
static void 
sanitize_jesinfo(const HASPCP *cp, char *jesinfo, size_t size) 
{
	size_t i;
	for (i = 0; i < size - 1; i++) {
		if (!isprint(cp->buf[i]) || cp->buf[i] == '\\' || cp->buf[i] == '\"') {
			jesinfo[i] = '.';
		} else {
			jesinfo[i] = cp->buf[i];
		}
	}
	jesinfo[size - 1] = '\0';
}

__asm__("\n&FUNC	SETC 'should_skip_job'");
static int 
should_skip_job(const JESJOB *job, const char *owner) 
{
	if (!job) {
		return 1;
	}

	// skip job if owner does not match
	if (owner) {
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

__asm__("\n&FUNC	SETC 'uint_to_hex_ascii'");
static 
void uint_to_hex_ascii(size_t value, char *output) 
{
	int pos = 0;
	int i;
	char temp;
	
	/* Spezialfall für 0 */
	if (value == 0) {
		output[0] = 0x30; 
		output[1] = CR;  
		output[2] = LF;  
		output[3] = CR;
		output[4] = LF;
		output[5] = '\0';
		return;
	}
	
	/* Hex-Ziffern von rechts nach links aufbauen */
	while (value > 0) {
		int digit = value % 16;
		if (digit < 10) {
			output[pos++] = 0x30 + digit;    /* ASCII '0'-'9' (0x30-0x39) */
		} else {
			output[pos++] = 0x41 + digit - 10;  /* ASCII 'A'-'F' (0x41-0x46) */
		}
		value /= 16;
	}
	
	/* String umdrehen */
	for (i = 0; i < pos/2; i++) {
		temp = output[i];
		output[i] = output[pos-1-i];
		output[pos-1-i] = temp;
	}
	
	/* CRLF hinzufügen */
	output[pos++] = CR; 
	output[pos++] = LF; 
	output[pos] = '\0';
}

__asm__("\n&FUNC	SETC '_recv'");
static int 
_recv(HTTPC *httpc, char *buf, int len)
{
	int total_bytes_received = 0;
	int bytes_received;
	int sockfd;

	sockfd = httpc->socket;
	while (total_bytes_received < len) {
		bytes_received = recv(sockfd, buf + total_bytes_received, len - total_bytes_received, 0);
		if (bytes_received < 0) {
			if (errno == EINTR) {
				// Interrupted by a signal, retry
				continue;
			} else {
				// An error occurred
				return -1;
			}
		} else if (bytes_received == 0) {
			// Connection closed by the client
			break;
		}
		total_bytes_received += bytes_received;
	}

	return total_bytes_received;
}

__asm__("\n&FUNC	SETC '_send_response'");
static int 
_send_response(Session *session, int status_code, const char *content_type, const char *data)
{
	char buffer[INITIAL_BUFFER_SIZE];
	int ret;

	// HTTP-Statuszeile erstellen
	sprintf(buffer, "HTTP/1.0 %d ", status_code);

	// Statusnachricht basierend auf dem Statuscode hinzufügen
	switch (status_code) {
		case 200:
			strcat(buffer, "OK\r\n");
			break;
		case 201:
			strcat(buffer, "Created\r\n");
			break;
		case 400:
			strcat(buffer, "Bad Request\r\n");
			break;
		case 403:
			strcat(buffer, "Forbidden\r\n");
			break;			
		case 404:
			strcat(buffer, "Not Found\r\n");
			break;
		case 415:
			strcat(buffer, "Unsupported Media Type\r\n");
			break;
		case 500:
			strcat(buffer, "Internal Server Error\r\n");
			break; 
		default:
			strcat(buffer, "Unknown\r\n");
			break;
	}

	sprintf(buffer + strlen(buffer),
			"Content-Type: %s\r\n"
			"Transfer-Encoding: chunked\r\n"
			"Connection: close\r\n\r\n",
			content_type);
	
	http_etoa((UCHAR *) buffer, strlen(buffer));
	ret = send(session->httpc->socket, buffer, strlen(buffer), 0);
	if (ret < 0) {
		wtof("Failed to send HTTP header: %s", strerror(errno));
		return -1;
	}

	const char *current = data;
	size_t remaining = strlen(data);

	while (remaining > 0) {
		// Chunk-Größe bestimmen (angepasst an Puffergröße)
		size_t chunk_size = remaining > INITIAL_BUFFER_SIZE ? INITIAL_BUFFER_SIZE : remaining;
	
		char chunk_size_str[32 + 2];
		uint_to_hex_ascii(chunk_size, chunk_size_str);

		ret = send(session->httpc->socket, chunk_size_str, strlen(chunk_size_str), 0);
		if (ret < 0) {
			wtof("Failed to send chunk size: %s", strerror(errno));
			return -1;
		}


        // Chunk-Daten in temporären Puffer kopieren
        char chunk_buffer[INITIAL_BUFFER_SIZE];
        memcpy(chunk_buffer, current, chunk_size);

        // Chunk-Daten kodieren
        http_etoa((UCHAR *) chunk_buffer, chunk_size);

		// Chunk-Daten senden
		ret = send(session->httpc->socket, chunk_buffer, chunk_size, 0);
		if (ret < 0) {
			perror("Failed to send chunk data");
			return -1;
		}

		ret = send(session->httpc->socket, ASCII_CRLF, 2, 0);
		if (ret < 0) {
			perror("Failed to send CRLF");
			return -1;
		}

		// Zum nächsten Chunk fortschreiten
		current += chunk_size;
		remaining -= chunk_size;
	}

	// Finalen leeren Chunk senden, um das Ende zu signalisieren
	size_t chunk_size = 0;
	
	char chunk_size_str[32 + 2];
	uint_to_hex_ascii(chunk_size, chunk_size_str);

	ret = send(session->httpc->socket, chunk_size_str, strlen(chunk_size_str), 0);
	if (ret < 0) {
		perror("Failed to send final chunk");
		return -1;
	}

	return 0;
}

__asm__("\n&FUNC    SETC 'find_job_by_name_and_id'");
static 
JESJOB* find_job_by_name_and_id(Session *session, const char *jobname, const char *jobid, JES **jes_handle) 
{
	int job_found = 0;
	JESJOB *found_job = NULL;
	JESJOB **joblist = NULL;
	JESFILT jesfilt = FILTER_JOBID;
	const char *filter = jobid;

	if (!jobname || !jobid || !jes_handle) {
		wtof("MVSMF22E Invalid parameters for find_job_by_name_and_id");
		return NULL;
	}

	*jes_handle = jesopen();
	if (!*jes_handle) {
		wtof(MSG_JOB_JES_ERROR);
		return NULL;
	}

	joblist = jesjob(*jes_handle, filter, jesfilt, 1);
	if (!joblist) {
		return NULL;
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
			return NULL;
		}

		found_job = job;
	}

	return found_job;
}

__asm__("\n&FUNC    SETC 'get_recfm_string'");
static 
void get_recfm_string(int recfm, char *recfm_str, size_t size) 
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
        if (http_cmp((const UCHAR *)dd->ddname, (const UCHAR *)"JESINTXT") == 0) continue;

        rc = snprintf(url_str, sizeof(url_str),
                    "http://%s/zosmf/restjobs/jobs/%s/%s/files/%d/records", 
                    host_str, job->jobname, job->jobid, dd->dsid);

        get_recfm_string(dd->recfm, recfm_str, sizeof(recfm_str));

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

__asm__("\n&FUNC    SETC 'submit_jcl_content'");
static 
int submit_jcl_content(Session *session, VSFILE *intrdr, const char *content, size_t content_length) 
{
    int rc = 0;
    
	char jobclass = 'A';
	char jobname[JOBNAME_STR_SIZE + 1] = {0};
    char jobid[JOBID_STR_SIZE + 1] = {0};
    
	int was_submitted = 0;

    // Convert content from ASCII to EBCDIC
    char *ebcdic_content = strdup(content);
    if (!ebcdic_content) {
        wtof("MVSMF22E Memory allocation failed for EBCDIC conversion");
        return -1;
    }
    
	http_atoe((UCHAR *)ebcdic_content, content_length);

    // Split content into lines and submit
    char delimiter[2];
    delimiter[0] = 0x25; // EBCDIC Line Feed
    delimiter[1] = '\0';

    char *line = strtok(ebcdic_content, delimiter);
    int line_number = 0;

    while (line != NULL) {
        size_t line_len = strlen(line);
        if (line_len > 0 && line[line_len - 1] == '\r') {
            line[line_len - 1] = '\0';
            line_len--;
        }

        // Extract jobname and class from JOB card
        if (line_number == 0) {
            if (strncmp(line, "//", 2) == 0) {
                int i;
                for (i = 2; i < line_len && line[i] != ' ' && i - 2 < 8; i++) {
                    jobname[i - 2] = line[i];
                }
                jobname[i - 2] = '\0';

                char *class_param = strstr(line, "CLASS=");
                if (class_param && strlen(class_param) > 6) {
                    jobclass = class_param[6];
                }
            }
        }

        rc = jesirput(intrdr, line);
        if (rc < 0) {
            wtof("MVSMF22E Failed to write to internal reader");
            free(ebcdic_content);
            return rc;
        }

        line = strtok(NULL, delimiter);
        line_number++;
    }

    free(ebcdic_content);

    // Close internal reader and get jobid
    rc = jesircls(intrdr);
    if (rc < 0) {
        wtof("MVSMF22E Failed to close internal reader");
        return rc;
    }

    strncpy(jobid, (const char *)intrdr->rpl.rplrbar, JOBID_STR_SIZE);
    jobid[JOBID_STR_SIZE] = '\0';

    wtof("MVSMF30I JOB %s(%s) SUBMITTED", jobname, jobid);

    // Build and send response
	JsonBuilder *builder = createJsonBuilder();
	const char *host = getHeaderParam(session, "HOST");
	char url_str[MAX_URL_LENGTH] = {0};
	rc = snprintf(url_str, sizeof(url_str), "http://%s/zosmf/restjobs/jobs/%s/%s", host, jobname, jobid);

	rc = startJsonObject(builder);
	
	rc = addJsonString(builder, "owner", "");
	rc = addJsonString(builder, "subsystem", "JES2");
	rc = addJsonString(builder, "type", "JOB");
	rc = addJsonString(builder, "url", url_str);
	rc = addJsonString(builder, "jobid", jobid);
	rc = addJsonString(builder, "class", &jobclass);
	
	rc = endJsonObject(builder);
	if (rc < 0) {
		goto quit;
	}
	
	rc = sendJSONResponse(session, HTTP_STATUS_CREATED, builder);

quit:
	if (builder) {	
		freeJsonBuilder(builder);
	}

    return rc;
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
                if (_recv(session->httpc, chunk_size_str + i, 1) != 1) {
                    return -1;
                }
                if (chunk_size_str[i] == '\r') {
                    chunk_size_str[i] = '\0';
                    _recv(session->httpc, chunk_size_str + i, 1); // Read \n
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
                bytes_received = _recv(session->httpc, *content + *content_size + bytes_read,
                                   chunk_size - bytes_read);
                if (bytes_received <= 0) {
                    return -1;
                }
                bytes_read += bytes_received;
            }

            *content_size += chunk_size;

            // Read trailing CRLF
            char crlf[2];
            if (_recv(session->httpc, crlf, 2) != 2) {
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

            bytes_received = _recv(session->httpc, *content + *content_size,
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
