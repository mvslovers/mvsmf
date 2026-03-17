#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <clibwto.h>
#include <libufs.h>
#include <time64.h>

#include "ussapi.h"
#include "common.h"
#include "httpcgi.h"
#include "xlate.h"

// Data type constants
#define USS_DATA_TYPE_TEXT   1
#define USS_DATA_TYPE_BINARY 2

//
// UFSD RC → HTTP status mapping
//

__asm__("\n&FUNC    SETC 'ufsd_rc_to_http'");
static int
ufsd_rc_to_http(int rc)
{
	switch (rc) {
	case UFSD_RC_OK:          return 200;
	case UFSD_RC_NOFILE:      return 404;
	case UFSD_RC_EXIST:       return 409;
	case UFSD_RC_NOTDIR:      return 400;
	case UFSD_RC_ISDIR:       return 400;
	case UFSD_RC_NOSPACE:     return 507;
	case UFSD_RC_NOINODES:    return 507;
	case UFSD_RC_IO:          return 500;
	case UFSD_RC_BADFD:       return 500;
	case UFSD_RC_NOTEMPTY:    return 409;
	case UFSD_RC_NAMETOOLONG: return 414;
	default:                  return 500;
	}
}

__asm__("\n&FUNC    SETC 'ufsd_rc_to_category'");
static int
ufsd_rc_to_category(int rc)
{
	switch (rc) {
	case UFSD_RC_NOFILE:      return 6;  /* not found */
	case UFSD_RC_EXIST:       return 4;  /* conflict  */
	case UFSD_RC_NOTDIR:      return 2;  /* bad request */
	case UFSD_RC_ISDIR:       return 2;  /* bad request */
	case UFSD_RC_NOSPACE:     return 8;  /* resource  */
	case UFSD_RC_NOINODES:    return 8;  /* resource  */
	case UFSD_RC_IO:          return 10; /* server    */
	case UFSD_RC_BADFD:       return 10; /* server    */
	case UFSD_RC_NOTEMPTY:    return 4;  /* conflict  */
	case UFSD_RC_NAMETOOLONG: return 2;  /* bad request */
	default:                  return 10; /* server    */
	}
}

__asm__("\n&FUNC    SETC 'ufsd_rc_message'");
static const char *
ufsd_rc_message(int rc)
{
	switch (rc) {
	case UFSD_RC_OK:          return "Success";
	case UFSD_RC_NOFILE:      return "File or directory not found";
	case UFSD_RC_EXIST:       return "File or directory already exists";
	case UFSD_RC_NOTDIR:      return "Not a directory";
	case UFSD_RC_ISDIR:       return "Is a directory";
	case UFSD_RC_NOSPACE:     return "No space left on device";
	case UFSD_RC_NOINODES:    return "No inodes available";
	case UFSD_RC_IO:          return "I/O error";
	case UFSD_RC_BADFD:       return "Bad file descriptor";
	case UFSD_RC_NOTEMPTY:    return "Directory not empty";
	case UFSD_RC_NAMETOOLONG: return "Path name too long";
	default:                  return "Unknown UFSD error";
	}
}

//
// UFS session helper
//

__asm__("\n&FUNC    SETC 'uss_open_session'");
static UFS *
uss_open_session(Session *session)
{
	UFS *ufs = ufsnew();
	if (!ufs) {
		sendErrorResponse(session, 503, 1, 8, 1,
			"UFSD subsystem not available", NULL, 0);
		return NULL;
	}

	if (session->acee) {
		ufs_set_acee(ufs, session->acee);
	}

	return ufs;
}

//
// Data type detection helper
//

__asm__("\n&FUNC    SETC 'get_data_type'");
static int
get_data_type(Session *session)
{
	char *dt = (char *) http_get_env(session->httpc,
		(const UCHAR *) "HTTP_X-IBM-Data-Type");

	if (!dt) return USS_DATA_TYPE_TEXT;
	if (strcmp(dt, "binary") == 0) return USS_DATA_TYPE_BINARY;
	return USS_DATA_TYPE_TEXT;
}

//
// Default max items for directory listing
//

#define USS_LIST_DEFAULT_MAX_ITEMS 1000

//
// ussListHandler — GET /zosmf/restfiles/fs?path=<filepath>
//
// Lists files and directories at the given path, returning
// z/OSMF-compatible JSON with file metadata from UFSDLIST entries.
//

int ussListHandler(Session *session)
{
	int rc = 0;
	int first = 1;
	unsigned maxitems = USS_LIST_DEFAULT_MAX_ITEMS;
	unsigned emitted = 0;
	unsigned total = 0;
	char *path = NULL;
	char *maxitems_str = NULL;
	UFS *ufs = NULL;
	UFSDDESC *dd = NULL;
	UFSDLIST *entry = NULL;

	// Get required path query parameter
	path = getQueryParam(session, "path");
	if (!path || path[0] == '\0') {
		return sendErrorResponse(session, 400, 2, 8, 1,
			"Missing required query parameter 'path'", NULL, 0);
	}

	// Parse optional X-IBM-Max-Items header (0 = unlimited)
	maxitems_str = getHeaderParam(session, "X-IBM-Max-Items");
	if (maxitems_str) {
		maxitems = (unsigned) atoi(maxitems_str);
	}

	// Open UFS session
	ufs = uss_open_session(session);
	if (!ufs) {
		return -1;
	}

	// Open directory
	dd = ufs_diropen(ufs, path, NULL);
	if (!dd) {
		rc = sendErrorResponse(session, 404, 6, 8, 1,
			"Path not found or is not a directory", NULL, 0);
		ufsfree(&ufs);
		return rc;
	}

	// Send response headers (streaming JSON like dsapi.c)
	if ((rc = http_resp(session->httpc, 200)) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Cache-Control: no-store\r\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Content-Type: %s\r\n", "application/json")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Pragma: no-cache\r\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Access-Control-Allow-Origin: *\r\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "\r\n")) < 0) goto quit;

	if ((rc = http_printf(session->httpc, "{\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "  \"items\": [\n")) < 0) goto quit;

	// Read directory entries
	while ((entry = ufs_dirread(dd)) != NULL) {
		struct tm *tm_info;
		char mtime_buf[32];

		// Skip . and ..
		if (strcmp(entry->name, ".") == 0 ||
			strcmp(entry->name, "..") == 0) {
			continue;
		}

		total++;

		// Enforce max items limit (0 = unlimited)
		if (maxitems > 0 && emitted >= maxitems) {
			continue;  // keep counting total
		}

		// Emit JSON object separator
		if (first) {
			if ((rc = http_printf(session->httpc, "    {\n")) < 0) goto quit;
			first = 0;
		} else {
			if ((rc = http_printf(session->httpc, "   ,{\n")) < 0) goto quit;
		}

		// Format mtime as ISO 8601 (mtime is milliseconds since epoch)
		tm_info = mgmtime64(&entry->mtime);
		if (tm_info) {
			snprintf(mtime_buf, sizeof(mtime_buf),
				"%04d-%02d-%02dT%02d:%02d:%02dZ",
				tm_info->tm_year + 1900, tm_info->tm_mon + 1,
				tm_info->tm_mday, tm_info->tm_hour,
				tm_info->tm_min, tm_info->tm_sec);
		} else {
			snprintf(mtime_buf, sizeof(mtime_buf), "1970-01-01T00:00:00Z");
		}

		// Emit fields matching UFSDLIST → JSON mapping from issue spec
		if ((rc = http_printf(session->httpc, "      \"name\": \"%s\",\n", entry->name)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"mode\": \"%s\",\n", entry->attr)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"size\": %u,\n", entry->filesize)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"user\": \"%s\",\n", entry->owner)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"group\": \"%s\",\n", entry->group)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"links\": %u,\n", (unsigned) entry->nlink)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"mtime\": \"%s\",\n", mtime_buf)) < 0) goto quit;
		if ((rc = http_printf(session->httpc, "      \"inode\": %u\n", entry->inode_number)) < 0) goto quit;

		if ((rc = http_printf(session->httpc, "    }\n")) < 0) goto quit;

		emitted++;
	}

	// Close JSON array and add metadata
	if ((rc = http_printf(session->httpc, "  ],\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "  \"returnedRows\": %u,\n", emitted)) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "  \"totalRows\": %u,\n", total)) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "  \"moreRows\": %s,\n",
		(maxitems > 0 && emitted < total) ? "true" : "false")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "  \"JSONversion\": 1\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "}\n")) < 0) goto quit;

quit:
	if (dd) {
		ufs_dirclose(&dd);
	}
	if (ufs) {
		ufsfree(&ufs);
	}

	return rc;
}

//
// ussGetHandler — GET /zosmf/restfiles/fs/{*filepath}
//
// Reads file content via ufs_fopen/ufs_fread in 4K chunks.
// Text mode (default): EBCDIC→ASCII conversion after each chunk.
// Binary mode: raw bytes, no conversion.
//

#define USS_READ_BUFSZ 4096

int ussGetHandler(Session *session)
{
	int rc = 0;
	int data_type;
	char *filepath = NULL;
	const char *content_type;
	UFS *ufs = NULL;
	UFSFILE *fp = NULL;
	char buf[USS_READ_BUFSZ];
	UINT32 n;

	// Get filepath from path variable
	filepath = getPathParam(session, "filepath");
	if (!filepath || filepath[0] == '\0') {
		return sendErrorResponse(session, 400, 2, 8, 1,
			"Missing file path", NULL, 0);
	}

	// Determine data type from X-IBM-Data-Type header
	data_type = get_data_type(session);

	// Open UFS session
	ufs = uss_open_session(session);
	if (!ufs) {
		return -1;
	}

	// Open file for reading
	fp = ufs_fopen(ufs, filepath, "r");
	if (!fp) {
		rc = sendErrorResponse(session, 404, 6, 8, 1,
			"File not found or is a directory", NULL, 0);
		ufsfree(&ufs);
		return rc;
	}

	// Check for error after open (e.g. ISDIR)
	if (fp->error != UFSD_RC_OK) {
		int urc = fp->error;
		ufs_fclose(&fp);
		rc = sendErrorResponse(session,
			ufsd_rc_to_http(urc), ufsd_rc_to_category(urc), 8, 1,
			ufsd_rc_message(urc), NULL, 0);
		ufsfree(&ufs);
		return rc;
	}

	// Send response headers
	content_type = (data_type == USS_DATA_TYPE_BINARY)
		? "application/octet-stream"
		: "text/plain";

	if ((rc = http_resp(session->httpc, 200)) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Cache-Control: no-store\r\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Content-Type: %s\r\n", content_type)) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Pragma: no-cache\r\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Access-Control-Allow-Origin: *\r\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "\r\n")) < 0) goto quit;

	// Stream file content in chunks
	while ((n = ufs_fread(buf, 1, sizeof(buf), fp)) > 0) {
		if (data_type == USS_DATA_TYPE_TEXT) {
			mvsmf_etoa((unsigned char *)buf, n);
		}
		rc = http_send(session->httpc, (const UCHAR *)buf, n);
		if (rc < 0) {
			goto quit;
		}
	}

	rc = 0;

quit:
	if (fp) {
		ufs_fclose(&fp);
	}
	if (ufs) {
		ufsfree(&ufs);
	}

	return rc;
}

int ussPutHandler(Session *session)
{
	return sendErrorResponse(session, 501, 10, 8, 1,
		"USS file write not yet implemented", NULL, 0);
}

int ussCreateHandler(Session *session)
{
	return sendErrorResponse(session, 501, 10, 8, 1,
		"USS create not yet implemented", NULL, 0);
}

int ussDeleteHandler(Session *session)
{
	return sendErrorResponse(session, 501, 10, 8, 1,
		"USS delete not yet implemented", NULL, 0);
}
