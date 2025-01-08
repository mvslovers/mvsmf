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
#include "jobsapi_err.h"
#include "jobsapi_msg.h"
#include "json.h"

#define INITIAL_BUFFER_SIZE 4096
#define MAX_JOBS_LIMIT 1000
#define MAX_URL_LENGTH 256
#define MAX_ERR_MSG_LENGTH 256
#define TYPE_STR_SIZE    3 + 1
#define CLASS_STR_SIZE   3 + 1
#define JES_INFO_SIZE   20 + 1
#define RECFM_SIZE       3 + 1
//
// private functions prototypes
//

/* TODO (MIG) refactor sysout stuff*/
static int  do_print_sysout(Session *session, JES *jes, JESJOB *job, unsigned dsid);
static void sanitize_jesinfo(const HASPCP *cp, char *jesinfo, size_t size);
static void process_job_list_filters(Session *session, const char **filter, JESFILT *jesfilt);
static int  process_single_job(JsonBuilder *builder, JESJOB *job, const char *owner, const char *host);
static int  submit_file(Session *session, VSFILE *intrdr, const char *filename);
static int  get_self(char *jobname, char *jobid);
static int  should_skip_job(const JESJOB *job, const char *owner);

// TODO (MIG) remove these
static int _recv(HTTPC *httpc, char *buf, int len);
static int _send_response(Session *session, int status_code, const char *content_type, const char *data);
static const unsigned char ASCII_CRLF[] = {CR, LF};

//
// public functions
//

int 
jobListHandler(Session *session) 
{
	int rc = 0;
	
	HASPCP *cp = NULL;
	JES *jes = NULL;
	JESJOB **joblist = NULL;
	JESFILT jesfilt = FILTER_NONE;
	const char *filter = NULL;

	JsonBuilder *builder = createJsonBuilder();

	unsigned max_jobs = MAX_JOBS_LIMIT;

	if (!builder) {
		sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
						CATEGORY_UNEXPECTED, RC_SEVERE, REASON_SERVER_ERROR,
						ERR_MSG_SERVER_ERROR, NULL, 0);
		goto quit;
	}

	const char *host = getHeaderParam(session, "HOST");
	const char *owner = getQueryParam(session, "owner");
	const char *max_jobs_str = getQueryParam(session, "max-jobs");

	if (owner == NULL) {
		owner = getHeaderParam(session, "CURRENT_USER");
	}

	if (owner[0] == '*') {
		owner = NULL;
	}

	process_job_list_filters(session, &filter, &jesfilt);

	// convert max_jobs_str to max_jobs (unsigned int)
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

	jes = jesopen();
	if (!jes) {
		wtof(MSG_JOB_JES_ERROR);
		sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR, CATEGORY_VSAM,
						RC_SEVERE, REASON_INCORRECT_JES_VSAM_HANDLE,
						ERR_MSG_INCORRECT_JES_VSAM_HANDLE, NULL, 0);
		goto quit;
	}

	// retrieve the job list from JES with the given filter
	joblist = jesjob(jes, filter, jesfilt, 0);

	// start a new JSON array
	startArray(builder);

	int ii = 0;
	for (ii = 0; ii < MIN(max_jobs, array_count(&joblist)); ii++) {
		rc = process_single_job(builder, joblist[ii], owner, host);
		if (rc < 0) {
			goto quit;
		}
	}

	// end the JSON array
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

	unsigned first = 1;
	unsigned jcount = 0;
	unsigned ddcount = 0;

	HASPCP *cp = NULL;
	JES *jes = NULL;
	JESJOB **joblist = NULL;
	JESFILT jesfilt = FILTER_NONE;

	JsonBuilder *builder = createJsonBuilder();

	int dd = 1;
	
	char jesinfo[JES_INFO_SIZE] = "unknown";
  	char recfm[RECFM_SIZE] = {0};

	const char *filter = NULL;
	const char *jobname = NULL;
	const char *jobid = NULL;

	
	unsigned job_found = 0;


	if (!builder) {
		sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
						CATEGORY_UNEXPECTED, RC_SEVERE, REASON_SERVER_ERROR,
						ERR_MSG_SERVER_ERROR, NULL, 0);
		goto quit;
	}

	jobname = getPathParam(session, "job-name");
	jobid   = getPathParam(session, "jobid");

	if (!jobname || !jobid) {
		sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
						CATEGORY_UNEXPECTED, RC_SEVERE, REASON_SERVER_ERROR,
						ERR_MSG_SERVER_ERROR, NULL, 0);
		goto quit;
	}

	filter = jobid;
	jesfilt = FILTER_JOBID;

	jes = jesopen();
	if (!jes) {
		wtof(MSG_JOB_JES_ERROR);
		sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR, CATEGORY_VSAM,
						RC_SEVERE, REASON_INCORRECT_JES_VSAM_HANDLE,
						ERR_MSG_INCORRECT_JES_VSAM_HANDLE, NULL, 0);
		goto quit;
	}

	cp = jes->cp;
	joblist = jesjob(jes, filter, jesfilt, dd);

	if (cp && cp->buf) {
		sanitize_jesinfo(cp, jesinfo, sizeof(jesinfo));
	}

	int ii = 0;
	int jj = 0;
	int kk = 0;
	for (ii = 0; ii < array_count(&joblist); ii++) {

		JESJOB *job = joblist[ii];

		if (!job) {
			continue;
		}
		
		if (http_cmp((const UCHAR *)job->jobname, (const UCHAR *)jobname) != 0) {
			continue;
		}

		// check if we have more than one job with the same name
		job_found++;
		if (job_found > 1) {
			wtof("MVSMF22E More than one job found for reference: '%s(%s)'", jobname, jobid);
			sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR, CATEGORY_UNEXPECTED,
						RC_SEVERE, REASON_SERVER_ERROR,
						ERR_MSG_SERVER_ERROR, NULL, 0);

			goto quit;
		}

		// start a new JSON array
		startArray(builder);

		for (jj = 0; jj < array_count(&job->jesdd); jj++) {
			JESDD *dd = job->jesdd[jj];

			// skip JESINTXT
			if (http_cmp((const UCHAR *)dd->ddname, (const UCHAR *)"JESINTXT") == 0) {
				continue;
			}


			kk = 0;
			if ((dd->recfm & RECFM_U) == RECFM_U) {
				recfm[kk++] = 'U';
			} else if ((dd->recfm & RECFM_F) == RECFM_F) {
				recfm[kk++] = 'F';
			} else if ((dd->recfm & RECFM_V) == RECFM_V) {
				recfm[kk++] = 'V';
			}

			if (dd->recfm & RECFM_BR) {
				recfm[kk++] = 'B';
			}

			if (dd->recfm & RECFM_CA) {
				recfm[kk++] = 'A';
			} else if (dd->recfm & RECFM_CM) {
				recfm[kk++] = 'M';
			}

			if (recfm[0] == 'V' && (dd->recfm & RECFM_SB)) {
				recfm[kk++] = 'S'; /* spanned records */
			}
			recfm[kk] = 0;

			rc = startJsonObject(builder);

			rc = addJsonString(builder, "recfm", recfm);
			rc = addJsonString(builder, "records-url", "http://foo");
			rc = addJsonString(builder, "subsystem", "JES2");
			// addJsonString(builder, "job-correlator", "");
			rc = addJsonString(builder, "byte-count", 0);
			rc = addJsonNumber(builder, "lrecl", dd->lrecl);
			rc = addJsonString(builder, "jobid", (char *) job->jobid);
			rc = addJsonString(builder, "ddname", (char *) dd->ddname);
			rc = addJsonNumber(builder, "id", dd->dsid);
			rc = addJsonNumber(builder, "record-count", (int) dd->records);
			rc = addJsonString(builder, "class", (char[]){(char)dd->oclass, '\0'});
			rc = addJsonString(builder, "jobname", (char *) job->jobname);
		
			if (dd->stepname[0] != '\0') {
				rc = addJsonString(builder, "stepname", (char *) dd->stepname);
			} else {
				rc = addJsonString(builder, "stepname", "JES2");
			}

			if (dd->procstep[0] != '\0') {
				rc = addJsonString(builder, "procstep", (char *) dd->procstep);
			} else {
				rc = addJsonString(builder, "procstep", NULL);
			}

			rc = endJsonObject(builder);

			if (rc < 0) {
				goto quit;
			}
		}

		// end the JSON array
		endArray(builder);
	}
	
	if (job_found == 0) {
		char msg[MAX_ERR_MSG_LENGTH] = {0};
		rc = snprintf(msg, sizeof(msg), ERR_MSG_JOB_NOT_FOUND, jobname, jobid);
		sendErrorResponse(session, HTTP_STATUS_NOT_FOUND, CATEGORY_SERVICE,
						RC_WARNING, REASON_JOB_NOT_FOUND,
						msg, NULL, 0);
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

	return 0;
}

int jobRecordsHandler(Session *session) {
  int rc = 0;
  unsigned first = 1;
  unsigned count = 0;
  unsigned i, j, k = 0;

  HASPCP *cp = NULL;
  JES *jes = NULL;
  JESJOB **joblist = NULL;
  JESFILT jesfilt = FILTER_NONE;

  int dd = 1;
  char jesinfo[JES_INFO_SIZE] = "unknown";

  const char *filter = NULL;
  const char *jobname = NULL;
  const char *jobid = NULL;
  const char *ddid = NULL;

  jobname =
      (char *)http_get_env(session->httpc, (const UCHAR *)"HTTP_job-name");
  jobid = (char *)http_get_env(session->httpc, (const UCHAR *)"HTTP_jobid");
  ddid = (char *)http_get_env(session->httpc, (const UCHAR *)"HTTP_ddid");
  if (!jobname || !jobid || !ddid) {
    rc = http_resp_internal_error(session->httpc);
    return rc;
  }

  filter = jobid;
  jesfilt = FILTER_JOBID;

  /* Open the JES2 checkpoint and spool datasets */
  jes = jesopen();
  if (!jes) {
    wtof("*** unable to open JES2 checkpoint and spool datasets ***");
    /* we don't quit here, instead we'll send back an empty JSON object */
  }

  if (jes) {
    cp = jes->cp;
    joblist = jesjob(jes, filter, jesfilt, dd);
  }

  if (cp && cp->buf) {
    sanitize_jesinfo(cp, jesinfo, sizeof(jesinfo));
  }

  /*
          {
                  "cache-control": "no-store, no-cache=set-cookie",
                  "content-language": "en-US",
                  "content-length": "900",
                  "content-type": "text/plain",
                  "date": "Wed, 09 Oct 2024 09:16:17 GMT",
                  "expires": "Thu, 01 Dec 1994 16:00:00 GMT",
                  "pragma": "no-cache",
                  "strict-transport-security": "max-age=31536000;
     includeSubDomains", "x-content-type-options": "nosniff", "x-powered-by":
     "Servlet/3.1", "x-xss-protection": "1; mode=block"
          }
  */

  if ((rc = http_resp(session->httpc, 200)) < 0)
    goto quit;
  if ((rc = http_printf(session->httpc, "Cache-Control: no-store\r\n")) < 0)
    goto quit;
  if ((rc = http_printf(session->httpc, "Content-Type: %s\r\n", "texp/plain")) <
      0)
    goto quit;
  if ((rc = http_printf(session->httpc, "Access-Control-Allow-Origin: *\r\n")) <
      0)
    goto quit;
  if ((rc = http_printf(session->httpc, "\r\n")) < 0)
    goto quit;

  count = array_count(&joblist);

  for (i = 0; i < count; i++) {
    JESJOB *job = joblist[i];

    if (!job)
      continue;
    if (http_cmp((const UCHAR *)job->jobname, (const UCHAR *)jobname) != 0)
      continue;

    do_print_sysout(session, jes, job, atoi(ddid));
  }

quit:

  if (jes) {
    jesclose(&jes);
  }

  return rc;

  /* TODO: error when ddid does not exist
  {
          "rc": 4,
          "reason": 12,
          "category": 6,
          "message": "Job 'mikeg3(T0339234)' does not contain spool file id 1"
  }
  */
}

int jobSubmitHandler(Session *session) {
  int rc = 0;

  char *data = NULL;      // Dynamic buffer to hold incoming data
  size_t data_size = 0;   // Total data size accumulated
  size_t buffer_size = 0; // Current allocated size of the data buffer
  size_t bytes_received = 0;
  char recv_buffer[1024]; // Buffer for each recv() call
  int has_content_length = 0;
  size_t content_length = 0;
  int is_chunked = 0;
  int done = 0;

  const char crlf[] = "\r\n";

  char jobname[9] = {0};
  char jobclass = 'A';
  char jobid[9] = {0};

  int was_submitted = 0;

  VSFILE *intrdr;

  rc = jesiropn(&intrdr);
  if (rc < 0) {
    // TODO: return 500 Internal Server Error and / or a defined json error
    // object
    wtof("Unable to open JES internal reader");
    goto quit;
  }

  /* check for valid intrdr_mode */
  const char *intrdr_mode = (char *)http_get_env(
      session->httpc, (const UCHAR *)"HTTP_X-IBM-Intrdr-Mode");
  if (intrdr_mode != NULL && strcmp(intrdr_mode, "TEXT") != 0) {
    // TODO: return 400 Bad Request or 415 Unsupported Media Type or a defined
    // json error object
    wtof("JOBSAPI: Invalid intrdr_mode - must be TEXT");
    goto quit;
  }

  /* check for valid intrdr_lrecl */
  const char *intrdr_lrecl = (char *)http_get_env(
      session->httpc, (const UCHAR *)"HTTP_X-IBM-Intrdr-Lrecl");
  if (intrdr_lrecl != NULL && strcmp(intrdr_lrecl, "80") != 0) {
    // TODO: return 400 Bad Request or 415 Unsupported Media Type or a defined
    // json error object
    wtof("JOBSAPI: Invalid intrdr_lrecl - must be 80");
    goto quit;
  }

  /* check for valid intrdr_recfm */
  const char *intrdr_recfm = (char *)http_get_env(
      session->httpc, (const UCHAR *)"HTTP_X-IBM-Intrdr-Recfm");
  if (intrdr_recfm != NULL && strcmp(intrdr_recfm, "F") != 0) {
    // TODO: return 400 Bad Request or 415 Unsupported Media Type or a defined
    // json error object
    wtof("JOBSAPI: Invalid intrdr_recfm - must be F");
    goto quit;
  }

  // Try to get the Content-Length header
  const char *content_length_str = (char *)http_get_env(
      session->httpc, (const UCHAR *)"HTTP_CONTENT-LENGTH");
  if (content_length_str != NULL) {
    has_content_length = 1;
    content_length = strtoul(content_length_str, NULL, 10);
  }

  // Check for Transfer-Encoding: chunked
  const char *transfer_encoding_str = (char *)http_get_env(
      session->httpc, (const UCHAR *)"HTTP_TRANSFER-ENCODING");
  if (transfer_encoding_str != NULL &&
      strstr(transfer_encoding_str, "chunked") != NULL) {
    is_chunked = 1;
  }

  if (!is_chunked && !has_content_length) {
    rc = http_resp(session->httpc, 400);
    if (rc < 0)
      goto quit;
    if ((rc = http_printf(session->httpc,
                          "Content-Type: application/json\r\n\r\n")) < 0)
      goto quit;
    if ((rc = http_printf(session->httpc,
                          "{\"rc\": -1, \"message\": \"Missing Content-Length "
                          "or Transfer-Encoding header\"}\n")) < 0)
      goto quit;
    goto quit;
  }

  // Allocate initial buffer
  data = malloc(INITIAL_BUFFER_SIZE);
  if (!data) {
    rc = -1;
    goto quit;
  }
  buffer_size = INITIAL_BUFFER_SIZE;

  if (is_chunked) {
    int chunk_size;
    char chunk_size_str[10];

    while (!done) {

      int i = 0;
      // Read chunk size as ASCII hex string
      while (i < sizeof(chunk_size_str) - 1) {
        if (_recv(session->httpc, chunk_size_str + i, 1) != 1) {
          rc = -1;
          goto quit;
        }
        if (chunk_size_str[i] == '\r') {
          chunk_size_str[i] = '\0';
          _recv(session->httpc, chunk_size_str + i, 1); // Read \n
          break;
        }
        i++;
      }

      // convert chunk size from ASCII hex to EBCDIC hex
      http_atoe((UCHAR *)chunk_size_str, sizeof(chunk_size_str));

      // convert chunk size from string to integer
      chunk_size = strtoul(chunk_size_str, NULL, 16);

      if (chunk_size == 0) {
        done = 1;
        break;
      }

      // check if we need to reallocate the buffer
      if (data_size + chunk_size > buffer_size) {
        // calculate new buffer size
        char *new_data = realloc(data, data_size + chunk_size + 1);
        if (new_data == NULL) {
          // TODO: return 500 Internal Server Error and / or a defined json
          // error object
          free(data);
          data = NULL;
          rc = -1;
          goto quit;
        }

        data = new_data;
        buffer_size = data_size + chunk_size;
      }

      // eread chunked data
      size_t bytes_read = 0;
      while (bytes_read < chunk_size) {
        bytes_received = _recv(session->httpc, data + data_size + bytes_read,
                               chunk_size - bytes_read);

        if (bytes_received <= 0) {
          rc = -1;
          goto quit;
        }
        bytes_read += bytes_received;
      }

      data_size += chunk_size;

      // read trailing CRLF
      char crlf[2];
      if (_recv(session->httpc, crlf, 2) != 2) {
        // TODO: return 500 Internal Server Error and / or a defined json error
        // object
        rc = -1;
        goto quit;
      }
    }
  } else {
    // Read content-length data
    while (data_size < content_length) {
      if (data_size + sizeof(recv_buffer) > buffer_size) {
        char *new_data = realloc(data, buffer_size * 2);
        if (!new_data) {
          rc = -1;
          goto quit;
        }
        data = new_data;
        buffer_size *= 2;
      }

      bytes_received = _recv(session->httpc, data + data_size,
                             content_length - data_size < sizeof(recv_buffer)
                                 ? content_length - data_size
                                 : sizeof(recv_buffer));

      if (bytes_received <= 0) {
        rc = -1;
        goto quit;
      }

      data_size += bytes_received;
    }
  }

  // convert data from ASCII to EBCDIC
  http_atoe((UCHAR *)data, data_size);

  // null terminate the data
  if (data_size + 1 > buffer_size) {
    char *new_data = realloc(data, data_size + 1);
    if (!new_data) {
      rc = -1;
      goto quit;
    }
    data = new_data;
  }
  data[data_size] = '\0';

  char delimiter[2];
  delimiter[0] = 0x25; // EBCDIC Line Feed
  delimiter[1] = '\0';

  char *line = strtok(data, delimiter);
  int line_number = 0;

  while (line != NULL) {
    size_t line_len = strlen(line);
    if (line_len > 0 && line[line_len - 1] == '\r') {
      line[line_len - 1] = '\0';
      line_len--;
    }

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
      } else {
        if (data[0] == '{') {
          char filename[256];
          char *file_start = strstr(data, "\"file\":\"");
          if (!file_start) {
            rc = -1;
            goto quit;
          }
          file_start += 8;
          char *file_end = strchr(file_start, '\"');
          if (!file_end) {
            rc = -1;
            goto quit;
          }
          strncpy(filename, file_start, file_end - file_start);
          filename[file_end - file_start] = '\0';

          // TODO: Submit file contents
          rc = submit_file(session, intrdr, filename);
          if (rc < 0)
            goto quit;
          was_submitted = 1;
          goto close;
        }
      }
    }

    rc = jesirput(intrdr, line);
    if (rc < 0) {
      // TODO: return 500 Internal Server Error and / or a defined json error
      // object
      goto quit;
    }

    line = strtok(NULL, delimiter);
    line_number++;
  }

  was_submitted = 1;

close:

  rc = jesircls(intrdr);
  if (rc < 0) {
    // TODO: return 500 Internal Server Error and / or a defined json error
    // object
    goto quit;
  }

  if (was_submitted) {
    strncpy(jobid, (const char *)intrdr->rpl.rplrbar, 8);
    jobid[8] = '\0';

    wtof("MVSMF30I JOB %s(%s) SUBMITTED", jobname, jobid);

  } else {
    jobid[0] = '\0';
  }

  char response[INITIAL_BUFFER_SIZE];
  sprintf(
      response,
      ""
      "{ "
      "\"owner\": \"\", "
      "\"phase\": 128, "
      "\"subsystem\": \"JES2\", "
      "\"phase-name\": \"Job is active in input processing\", "
      "\"job-correlator\": \"\", "
      "\"type\": \"JOB\", "
      "\"url\": \"http://drnbrx3a.neunetz.it:1080/zosmf/restjobs/jobs/%s/%s\", "
      "\"jobid\": \"%s\", "
      "\"class\": \"%c\", "
      "\"files-url\": "
      "\"http://drnbrx3a.neunetz.it:1080/zosmf/restjobs/jobs/%s/%s/files\", "
      "\"jobname\": \"%s\", "
      "\"status\": \"INPUT\", "
      "\"retcode\": null "
      " }",
      jobname, jobid, jobid, jobclass, jobname, jobid, jobname);

  // Send initial HTTP response
  // if ((rc = http_resp(httpc, 201)) < 0) goto quit;
  if ((rc = _send_response(session, 201, "application/json", response)) < 0)
    goto quit;

quit:
  if (data)
    free(data);

  return rc;
}

int jobStatusHandler(Session *session) {
  int rc = 0;
  unsigned first = 1;
  unsigned count = 0;
  unsigned i, j, k = 0;

  HASPCP *cp = NULL;
  JES *jes = NULL;
  JESJOB **joblist = NULL;
  JESFILT jesfilt = FILTER_NONE;

  int dd = 1;
  char jesinfo[JES_INFO_SIZE] = "unknown";

  const char *filter = NULL;
  const char *jobname = NULL;
  const char *jobid = NULL;
  const char *ddid = NULL;

  jobname =
      (char *)http_get_env(session->httpc, (const UCHAR *)"HTTP_job-name");
  jobid = (char *)http_get_env(session->httpc, (const UCHAR *)"HTTP_jobid");
  if (!jobname || !jobid) {
    rc = http_resp_internal_error(session->httpc);
    return rc;
  }

  filter = jobid;
  jesfilt = FILTER_JOBID;

  /* Open the JES2 checkpoint and spool datasets */
  jes = jesopen();
  if (!jes) {
    wtof("*** unable to open JES2 checkpoint and spool datasets ***");
    /* we don't quit here, instead we'll send back an empty JSON object */
  }

  if (jes) {
    cp = jes->cp;
    joblist = jesjob(jes, filter, jesfilt, dd);
  }

  if (cp && cp->buf) {
    sanitize_jesinfo(cp, jesinfo, sizeof(jesinfo));
  }

  /*
          {
                  "cache-control": "no-store, no-cache=set-cookie",
                  "content-language": "en-US",
                  "content-length": "900",
                  "content-type": "text/plain",
                  "date": "Wed, 09 Oct 2024 09:16:17 GMT",
                  "expires": "Thu, 01 Dec 1994 16:00:00 GMT",
                  "pragma": "no-cache",
                  "strict-transport-security": "max-age=31536000;
     includeSubDomains", "x-content-type-options": "nosniff", "x-powered-by":
     "Servlet/3.1", "x-xss-protection": "1; mode=block"
          }
  */

  if ((rc = http_resp(session->httpc, 200)) < 0)
    goto quit;
  if ((rc = http_printf(session->httpc, "Cache-Control: no-store\r\n")) < 0)
    goto quit;
  if ((rc = http_printf(session->httpc, "Content-Type: %s\r\n",
                        "application/json")) < 0)
    goto quit;
  if ((rc = http_printf(session->httpc, "Access-Control-Allow-Origin: *\r\n")) <
      0)
    goto quit;
  if ((rc = http_printf(session->httpc, "\r\n")) < 0)
    goto quit;

  count = array_count(&joblist);

  for (i = 0; i < count; i++) {
    JESJOB *job = joblist[i];
    /*
    {
"owner": "Z07850",
"phase": 20,
"subsystem": "JES2",
"phase-name": "Job is on the hard copy queue",
"job-correlator": "J0002020SVSCJES2E00F8F66.......:",
"type": "JOB",
"url":
"https://zxp.ibmz.ibm.com:10443/zosmf/restjobs/jobs/J0002020SVSCJES2E00F8F66.......%3A",
"jobid": "JOB02020",
"class": "A",
"files-url":
"https://zxp.ibmz.ibm.com:10443/zosmf/restjobs/jobs/J0002020SVSCJES2E00F8F66.......%3A/files",
"jobname": "Z07850A",
"status": "OUTPUT",
"retcode": "CC 0000"
}
    */

    if (!job)
      continue;
    if (http_cmp((const UCHAR *)job->jobname, (const UCHAR *)jobname) != 0)
      continue;

    const char *stat = "UNKNOWN";
    if (job->q_type) {
      if (job->q_type & _XEQ) {
        stat = "ACTIVE";
      } else if (job->q_type & _INPUT) {
        stat = "INPUT";
      } else if (job->q_type & _XMIT) {
        stat = "XMIT";
      } else if (job->q_type & _SETUP) {
        stat = "SSETUP";
      } else if (job->q_type & _RECEIVE) {
        stat = "RECEIVE";
      } else if (job->q_type & _OUTPUT || job->q_type & _HARDCPY) {
        stat = "OUTPUT";
      }
    }

    char clazz = ' ';
    if (job->eclass != '\\') {
      char class_char = (char)job->eclass;
      clazz = class_char;
    }

    char data[1024];
    sprintf(
        data,
        ""
        "{ "
        "\"owner\": \"%s\", "
        "\"phase\": 20, "
        "\"subsystem\": \"JES2\", "
        "\"phase-name\": \"Job is on the hard copy queue\", "
        "\"job-correlator\": \"\", "
        "\"type\": \"%.3s\", "
        "\"url\": "
        "\"http://drnbrx3a.neunetz.it:1080/zosmf/restjobs/jobs/%s/%s\", "
        "\"jobid\": \"%s\", "
        "\"class\": \"%s\", "
        "\"files-url\": "
        "\"http://drnbrx3a.neunetz.it:1080/zosmf/restjobs/jobs/%s/%s/files\", "
        "\"jobname\": \"%s\", "
        "\"status\": \"%s\", "
        "\"retcode\": \" n/a\" "
        " }",
        job->owner, job->jobid, job->jobname, job->jobid, job->jobid, clazz,
        job->jobname, job->jobid, job->jobname, stat);

    if ((rc = http_printf(session->httpc, "%s", data)) < 0)
      goto quit;
    if ((rc = http_printf(session->httpc, "\n")) < 0)
      goto quit;
  }

quit:

  if (jes) {
    jesclose(&jes);
  }

  return rc;

  /* TODO: error when ddid does not exist
  {
          "rc": 4,
          "reason": 12,
          "category": 6,
          "message": "Job 'mikeg3(T0339234)' does not contain spool file id 1"
  }
  */
}

int jobPurgeHandler(Session *session) {
  int rc = 0;
  unsigned count = 0;
  unsigned i = 0;

  HASPCP *cp = NULL;
  JES *jes = NULL;
  JESJOB **joblist = NULL;
  JESFILT jesfilt = FILTER_NONE;

  char *jobname = NULL;
  char *jobid = NULL;

  char thisjobname[8 + 1] = "";
  char thisjobid[8 + 1] = "";

  const char *msg = "";
  char response[1024] = {0};

  // Get jobname and jobid from request
  jobname = getPathParam(session, "job-name");
  jobid = getPathParam(session, "jobid");

  if (!jobname || !jobid) {
    wtof(MSG_JOB_PURGE_MISSING_PARAM, jobname ? jobname : "NULL",
         jobid ? jobid : "NULL");
    sendErrorResponse(session, HTTP_STATUS_BAD_REQUEST, CATEGORY_CIM, RC_ERROR,
                      REASON_INVALID_QUERY, ERR_MSG_INVALID_QUERY, NULL, 0);
    goto quit;
  }

  get_self(thisjobname, thisjobid);

  // Open JES2
  jes = jesopen();
  if (!jes) {
    wtof(MSG_JOB_JES_ERROR);
    sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR, CATEGORY_VSAM,
                      RC_SEVERE, REASON_INCORRECT_JES_VSAM_HANDLE,
                      ERR_MSG_INCORRECT_JES_VSAM_HANDLE, NULL, 0);
    goto quit;
  }

  // Find the job
  joblist = jesjob(jes, jobid, FILTER_JOBID, 0);
  if (!joblist) {
    char msg[256];
    snprintf(msg, sizeof(msg), ERR_MSG_JOB_NOT_FOUND, jobname, jobid);
    sendErrorResponse(session, HTTP_STATUS_NOT_FOUND, CATEGORY_SERVICE,
                      RC_WARNING, REASON_JOB_NOT_FOUND, msg, NULL, 0);
    goto quit;
  }

  // Check if there is more than one job with the same jobid
  count = array_count(&joblist);

  // Find and purge the job
  for (i = 0; i < count; i++) {
    JESJOB *job = joblist[i];

    if (!job)
      continue;

    // Purge is not allowed for HTTPD (self purge)
    if (http_cmp((const UCHAR *)job->jobid, (const UCHAR *)thisjobid) == 0) {
      wtof(MSG_JOB_PURGE_SELF, jobname, jobid);
      sendErrorResponse(session, HTTP_STATUS_FORBIDDEN, CATEGORY_SERVICE,
                        RC_WARNING, REASON_SELF_PURGE, ERR_MSG_SELF_PURGE, NULL,
                        0);
      goto quit;
    }

    // Check if this is the job we want to purge
    if (http_cmp((const UCHAR *)job->jobname, (const UCHAR *)jobname) == 0 &&
        http_cmp((const UCHAR *)job->jobid, (const UCHAR *)jobid) == 0) {

      // Purge the job
      rc = jescanj(jobname, jobid, 1);

      switch (rc) {
      case CANJ_OK:
        // Send success response
        sprintf(response,
                "{"
                "\"owner\": \"%s\","
                "\"jobid\": \"%s\","
                "\"job-correlator\": \"\","
                "\"message\": \"%s\","
                "\"original-jobid\": \"%s\","
                "\"jobname\": \"%s\","
                "\"status\": 0"
                "}",
                job->owner, jobid, "Request was successful.", jobid, jobname);

        if ((rc = http_resp(session->httpc, 200)) < 0)
          goto quit;
        if ((rc = http_printf(session->httpc,
                              "Content-Type: application/json\r\n")) < 0)
          goto quit;
        if ((rc = http_printf(session->httpc, "Cache-Control: no-cache\r\n")) <
            0)
          goto quit;
        if ((rc = http_printf(session->httpc, "\r\n")) < 0)
          goto quit;
        if ((rc = http_printf(session->httpc, "%s\n", response)) < 0)
          goto quit;

        rc = 0;
        break;
      case CANJ_NOJB:
        msg = "JOB NAME NOT FOUND";
        wtof("MVSMF42D CANJ_NOJB: %s", msg);
        break;
      case CANJ_BADI:
        msg = "INVALID JOBNAME/JOB ID COMBINATION";
        wtof("MVSMF42D CANJ_BADI: %s", msg);
        break;
      case CANJ_NCAN:
        msg = "JOB NOT CANCELLED - DUPLICATE JOBNAMES AND NO JOB ID GIVEN";
        wtof("MVSMF42D CANJ_NCAN: %s", msg);
        break;
      case CANJ_SMALL:
        msg = "STATUS ARRAY TOO SMALL";
        wtof("MVSMF42D CANJ_SMALL: %s", msg);
        break;
      case CANJ_OUTP:
        msg = "JOB NOT CANCELLED or PURGED - JOB ON OUTPUT QUEUE";
        wtof("MVSMF42D CANJ_OUTP: %s", msg);
        break;
      case CANJ_SYNTX:
        msg = "JOBID WITH INVALID SYNTAX FOR SUBSYSTEM";
        wtof("MVSMF42D CANJ_SYNTX: %s", msg);
        break;
      case CANJ_ICAN:
        sendErrorResponse(session, HTTP_STATUS_FORBIDDEN, CATEGORY_SERVICE,
                          RC_WARNING, REASON_STC_PURGE, ERR_MSG_STC_PURGE, NULL,
                          0);

        rc = 0;
        break;
      }
    }
  }

quit:

  if (jes) {
    jesclose(&jes);
  }

  return rc;
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
  unsigned count;
  unsigned n;

  count = array_count(&job->jesdd);
  for (n = 0; n < count; n++) {
    JESDD *dd = job->jesdd[n];

    if (!dd)
      continue;

    if (!dd->mttr)
      continue; /* no spool data for this dd	*/

    if (dd->dsid != dsid)
      continue;

    if ((dd->flag & FLAG_SYSIN) && !dsid)
      continue; /* don't show SYSIN data		*/

    rc = jesprint(jes, job, dd->dsid, do_print_sysout_line);
    if (rc < 0)
      goto quit;

    rc = http_printf(session->httpc, "- - - - - - - - - - - - - - - - - - - - "
                                     "- - - - - - - - - - - - - - - - - - - - "
                                     "- - - - - - - - - - - - - - - - - - - - "
                                     "- - - - - -\r\n");
    if (rc < 0)
      goto quit;
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

__asm__("\n&FUNC	SETC 'get_self'");
static int
get_self(char *jobname, char *jobid) 
{
  unsigned *psa = (unsigned *)0;
  unsigned *tcb = (unsigned *)psa[540 / 4];   /* A(current TCB) */
  unsigned *jscb = (unsigned *)tcb[180 / 4];  /* A(JSCB) */
  unsigned *ssib = (unsigned *)jscb[316 / 4]; /* A(SSIB) */

  const char *name =
      (const char *)tcb[12 / 4]; /* A(TIOT), but the job name is first 8 chars
                                    of TIOT so we cheat just a bit */
  const char *id =
      ((const char *)ssib) + 12; /* jobid is in SSIB at offset 12 */
  int i;

  for (i = 0; i < 8 && name[i] > ' '; i++) {
    jobname[i] = name[i];
  }
  jobname[i] = 0;

  for (i = 0; i < 8 && id[i] >= ' '; i++) {
    jobid[i] = id[i];
    /* the job id may have space(s) which should be '0' */
    if (jobid[i] == ' ')
      jobid[i] = '0';
  }
  jobid[i] = 0;

  return 0;
}

__asm__("\n&FUNC	SETC 'process_job_list_filters'");
static void 
process_job_list_filters(Session *session, const char **filter, JESFILT *jesfilt) 
{
  const char *prefix = getQueryParam(session, "prefix");
  const char *status = getQueryParam(session, "status");
  const char *jobid = getQueryParam(session, "jobid");

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

__asm__("\n&FUNC	SETC 'process_single_job'");
static int 
process_single_job(JsonBuilder *builder, JESJOB *job, const char *owner, const char *host) 
{
	int rc = 0;

	const char *host_str = NULL;

	char type_str[TYPE_STR_SIZE];
	char class_str[CLASS_STR_SIZE];
	char url_str[MAX_URL_LENGTH];
	char files_url_str[MAX_URL_LENGTH];
	char *stat_str = "UNKNOWN";

	if (should_skip_job(job, owner)) {
		return 0;
	}

	if (host != NULL) {
		host_str = host;
	} else {
		host_str = "127.0.0.1:8080";
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
