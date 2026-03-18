#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <errno.h>
#include <clibwto.h>
#include <clibthrd.h>
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
	case UFSD_RC_ROFS:        return 403;
	default:
		wtof("MVSMF83D ufsd_rc_to_http: unmapped rc=%d, defaulting to 500", rc);
		return 500;
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
	case UFSD_RC_ROFS:        return 4;  /* forbidden */
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
	case UFSD_RC_ROFS:        return "Read-only file system";
	default:                  return "Unknown UFSD error";
	}
}

//
// UFS cleanup callback for ESTAE recovery (called by session_cleanup)
//

__asm__("\n&FUNC    SETC 'uss_cleanup_cb'");
static void
uss_cleanup_callback(Session *session)
{
	if (session->ufs_file) {
		wtof("MVSMF99I Recovery: closing UFS file at %p",
			 session->ufs_file);
		ufs_fclose((void *)&session->ufs_file);
	}
	if (session->ufs) {
		wtof("MVSMF99I Recovery: freeing UFS session at %p",
			 session->ufs);
		ufsfree((void *)&session->ufs);
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

	// Track UFS session for ESTAE recovery
	session->ufs = ufs;
	session->ufs_cleanup = uss_cleanup_callback;

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
// Build absolute path from {*filepath} capture.
// The route pattern "/zosmf/restfiles/fs/{*filepath}" consumes the
// slash before the wildcard, so the captured value lacks a leading "/".
// This helper prepends it into a caller-supplied buffer.
// Returns the buffer pointer, or NULL if the path would overflow.
//

__asm__("\n&FUNC    SETC 'uss_build_path'");
static char *
uss_build_path(char *buf, size_t bufsz, const char *captured)
{
	size_t len = strlen(captured);
	if (len + 2 > bufsz) return NULL;  // +2 for '/' prefix and NUL
	buf[0] = '/';
	memcpy(buf + 1, captured, len + 1);  // includes NUL
	return buf;
}

//
// Receive raw data from socket, one byte at a time.
// Mirrors the receive_raw_data() pattern in jobsapi.c to work around
// the MVS 3.8j TCP/IP ring buffer bug (see Known Platform Bugs).
// DO NOT change to multi-byte recv().
//

#define USS_RECV_MAX_RETRIES 200

__asm__("\n&FUNC    SETC 'uss_recv_raw'");
static int
uss_recv_raw(HTTPC *httpc, char *buf, int len)
{
	int total = 0;
	int n = 0;
	int retries = 0;
	unsigned ecb = 0;
	int sockfd = httpc->socket;

	while (total < len) {
		n = recv(sockfd, buf + total, 1, 0);
		if (n < 0) {
			if (errno == EINTR) continue;
			if (errno == EWOULDBLOCK) {
				if (++retries > USS_RECV_MAX_RETRIES) {
					wtof("MVSMF80E recv() EWOULDBLOCK timeout after %d retries", retries);
					return -1;
				}
				ecb = 0;
				cthread_timed_wait((void *)&ecb, 5, 0);
				continue;
			}
			return -1;
		}
		if (n == 0) break;
		retries = 0;
		total += n;
	}

	return total;
}

//
// Read the full request body into a malloc'd buffer.
// Supports Content-Length transfer only (no chunked).
// Caller must free the returned buffer.
// Returns NULL on error (also sends error response).
//

__asm__("\n&FUNC    SETC 'uss_read_body'");
static char *
uss_read_body(Session *session, size_t *out_len)
{
	const char *cl_str = NULL;
	size_t content_length = 0;
	char *body = NULL;
	int received = 0;

	cl_str = getHeaderParam(session, "Content-Length");
	if (!cl_str) {
		sendErrorResponse(session, 400, 2, 8, 1,
			"Missing Content-Length header", NULL, 0);
		return NULL;
	}

	content_length = strtoul(cl_str, NULL, 10);
	if (content_length == 0) {
		sendErrorResponse(session, 400, 2, 8, 1,
			"Empty request body", NULL, 0);
		return NULL;
	}

	body = (char *)malloc(content_length);
	if (!body) {
		sendErrorResponse(session, 500, 10, 8, 1,
			"Memory allocation failed", NULL, 0);
		return NULL;
	}

	received = uss_recv_raw(session->httpc, body, (int)content_length);
	if (received < 0 || (size_t)received != content_length) {
		free(body);
		sendErrorResponse(session, 500, 10, 8, 1,
			"Failed to read request body", NULL, 0);
		return NULL;
	}

	*out_len = content_length;
	return body;
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
		session->ufs = NULL;
		return rc;
	}

	// Send response headers (streaming JSON like dsapi.c)
	session->headers_sent = 1;
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
		session->ufs = NULL;
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
	char *raw_path = NULL;
	char abspath[UFS_PATH_MAX];
	const char *content_type;
	UFS *ufs = NULL;
	UFSFILE *fp = NULL;
	char buf[USS_READ_BUFSZ];
	UINT32 n;

	// Get filepath from path variable and build absolute path
	raw_path = getPathParam(session, "filepath");
	if (!raw_path || raw_path[0] == '\0') {
		return sendErrorResponse(session, 400, 2, 8, 1,
			"Missing file path", NULL, 0);
	}

	if (!uss_build_path(abspath, sizeof(abspath), raw_path)) {
		return sendErrorResponse(session, 414, 2, 8, 1,
			"Path name too long", NULL, 0);
	}

	// Determine data type from X-IBM-Data-Type header
	data_type = get_data_type(session);

	// Open UFS session
	ufs = uss_open_session(session);
	if (!ufs) {
		return -1;
	}

	// Open file for reading
	fp = ufs_fopen(ufs, abspath, "r");
	if (!fp) {
		rc = sendErrorResponse(session, 404, 6, 8, 1,
			"File not found or is a directory", NULL, 0);
		ufsfree(&ufs);
		session->ufs = NULL;
		return rc;
	}
	session->ufs_file = fp;

	// Check for error after open (e.g. ISDIR)
	if (fp->error != UFSD_RC_OK) {
		int urc = fp->error;
		ufs_fclose(&fp);
		session->ufs_file = NULL;
		rc = sendErrorResponse(session,
			ufsd_rc_to_http(urc), ufsd_rc_to_category(urc), 8, 1,
			ufsd_rc_message(urc), NULL, 0);
		ufsfree(&ufs);
		session->ufs = NULL;
		return rc;
	}

	// Send response headers
	content_type = (data_type == USS_DATA_TYPE_BINARY)
		? "application/octet-stream"
		: "text/plain";

	session->headers_sent = 1;
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
		session->ufs_file = NULL;
	}
	if (ufs) {
		ufsfree(&ufs);
		session->ufs = NULL;
	}

	return rc;
}

//
// ussPutHandler — PUT /zosmf/restfiles/fs/{*filepath}
//
// Writes data to a file via ufs_fopen("w") + ufs_fwrite().
// Creates the file if it does not exist.
// Content-Type application/json dispatches to utilities (Phase 2, 501).
// Text mode (default): ASCII→EBCDIC before write.
// Binary mode: raw bytes, no conversion.
//

int ussPutHandler(Session *session)
{
	int rc = 0;
	int data_type;
	char *raw_path = NULL;
	char abspath[UFS_PATH_MAX];
	char *body = NULL;
	size_t body_len = 0;
	const char *content_type = NULL;
	UFS *ufs = NULL;
	UFSFILE *fp = NULL;
	UINT32 written;

	// Get filepath from path variable and build absolute path
	raw_path = getPathParam(session, "filepath");
	if (!raw_path || raw_path[0] == '\0') {
		return sendErrorResponse(session, 400, 2, 8, 1,
			"Missing file path", NULL, 0);
	}

	if (!uss_build_path(abspath, sizeof(abspath), raw_path)) {
		return sendErrorResponse(session, 414, 2, 8, 1,
			"Path name too long", NULL, 0);
	}

	// Check Content-Type: application/json → utilities (Phase 2)
	content_type = getHeaderParam(session, "Content-Type");
	if (content_type && strstr(content_type, "application/json") != NULL) {
		return sendErrorResponse(session, 501, 10, 8, 1,
			"USS utilities not yet implemented", NULL, 0);
	}

	// Determine data type from X-IBM-Data-Type header
	data_type = get_data_type(session);

	// Read request body
	body = uss_read_body(session, &body_len);
	if (!body) {
		return -1;  // uss_read_body already sent error response
	}

	// Text mode: ASCII→EBCDIC before writing
	if (data_type == USS_DATA_TYPE_TEXT) {
		mvsmf_atoe((unsigned char *)body, (int)body_len);
	}

	// Open UFS session
	ufs = uss_open_session(session);
	if (!ufs) {
		free(body);
		return -1;
	}

	// Open file for writing (creates if not exists)
	fp = ufs_fopen(ufs, abspath, "w");
	if (!fp) {
		rc = sendErrorResponse(session, 404, 6, 8, 1,
			"Cannot open file for writing", NULL, 0);
		goto quit;
	}
	session->ufs_file = fp;

	// Check for error after open
	if (fp->error != UFSD_RC_OK) {
		int urc = fp->error;
		ufs_fclose(&fp);
		session->ufs_file = NULL;
		fp = NULL;
		rc = sendErrorResponse(session,
			ufsd_rc_to_http(urc), ufsd_rc_to_category(urc), 8, 1,
			ufsd_rc_message(urc), NULL, 0);
		goto quit;
	}

	// Write body to file
	written = ufs_fwrite(body, 1, (UINT32)body_len, fp);
	if (written != (UINT32)body_len) {
		int urc = fp->error;
		ufs_fclose(&fp);
		session->ufs_file = NULL;
		fp = NULL;
		if (urc != UFSD_RC_OK) {
			rc = sendErrorResponse(session,
				ufsd_rc_to_http(urc), ufsd_rc_to_category(urc), 8, 1,
				ufsd_rc_message(urc), NULL, 0);
		} else {
			rc = sendErrorResponse(session, 500, 10, 8, 1,
				"Incomplete write to file", NULL, 0);
		}
		goto quit;
	}

	// Success — 204 No Content
	rc = sendDefaultHeaders(session, 204, HTTP_CONTENT_TYPE_NONE, 0);

quit:
	if (fp) {
		ufs_fclose(&fp);
		session->ufs_file = NULL;
	}
	free(body);
	if (ufs) {
		ufsfree(&ufs);
		session->ufs = NULL;
	}

	return rc;
}

//
// Parse a Unix permission string like "rwxr-xr-x" into an octal value.
// Returns the octal permission (e.g. 0755) or 0 on invalid input.
//

__asm__("\n&FUNC    SETC 'uss_parse_mode'");
static unsigned int
uss_parse_mode(const char *mode_str)
{
	unsigned int perm = 0;
	int i;

	if (!mode_str || strlen(mode_str) != 9) return 0;

	// Each triple: [rwx-][rwx-][rwx-] → owner, group, other
	for (i = 0; i < 9; i++) {
		perm <<= 1;
		if (mode_str[i] != '-') {
			perm |= 1;
		}
	}

	return perm;
}

//
// Simple JSON string extraction for ussCreateHandler.
// Operates on EBCDIC string (body already converted).
// Returns 0 on success, -1 if key not found.
//

__asm__("\n&FUNC    SETC 'uss_json_str'");
static int
uss_extract_json_string(const char *json, const char *key,
                        char *out, size_t outlen)
{
	char search[64];
	char *pos, *val_start, *val_end;
	size_t len;

	snprintf(search, sizeof(search), "\"%s\"", key);
	pos = strstr(json, search);
	if (!pos) return -1;

	pos += strlen(search);
	while (*pos == ' ' || *pos == '\t') pos++;
	if (*pos != ':') return -1;
	pos++;
	while (*pos == ' ' || *pos == '\t') pos++;
	if (*pos != '"') return -1;
	pos++;
	val_start = pos;

	val_end = strchr(val_start, '"');
	if (!val_end) return -1;

	len = val_end - val_start;
	if (len >= outlen) len = outlen - 1;
	memcpy(out, val_start, len);
	out[len] = '\0';
	return 0;
}

//
// ussCreateHandler — POST /zosmf/restfiles/fs/{*filepath}
//
// Creates a file or directory from JSON body:
//   {"type":"file|directory|dir","mode":"rwxr-xr-x"}
//
// - type "directory" or "dir" → ufs_mkdir()
// - type "file" → ufs_fopen("w") + ufs_fclose()
// - mode is optional (default: 0755)
// - Permission set via ufs_set_create_perm() before create, restored after
//

__asm__("\n&FUNC    SETC 'UAPI0004'");
int ussCreateHandler(Session *session)
{
	int rc = 0;
	int free_body = 0;
	int urc = 0;
	char *raw_path = NULL;
	char abspath[UFS_PATH_MAX];
	char *body = NULL;
	size_t body_len = 0;
	char type_str[16] = {0};
	char mode_str[16] = {0};
	unsigned int perm = 0755;
	unsigned int old_perm;
	unsigned int parsed;
	UFS *ufs = NULL;
	UFSFILE *fp = NULL;
	UFSDDESC *dd = NULL;

	wtof("MVSMF83D ussCreateHandler entered");

	// Get filepath from path variable and build absolute path
	raw_path = getPathParam(session, "filepath");
	if (!raw_path || raw_path[0] == '\0') {
		return sendErrorResponse(session, 400, 2, 8, 1,
			"Missing file path", NULL, 0);
	}

	if (!uss_build_path(abspath, sizeof(abspath), raw_path)) {
		return sendErrorResponse(session, 414, 2, 8, 1,
			"Path name too long", NULL, 0);
	}

	wtof("MVSMF83D path=%s", abspath);

	// Read request body — try POST_STRING first (HTTPD pre-reads when
	// Content-Type is set), fall back to socket read otherwise.
	// POST_STRING is already in EBCDIC; socket data needs conversion.
	body = (char *)http_get_env(session->httpc,
		(const UCHAR *)"POST_STRING");

	if (body && *body) {
		body_len = strlen(body);
		wtof("MVSMF83D POST_STRING len=%d", (int)body_len);
	} else {
		body = uss_read_body(session, &body_len);
		if (!body) {
			return -1;  // uss_read_body already sent error response
		}
		free_body = 1;

		// Convert from ASCII to EBCDIC for JSON parsing
		mvsmf_atoe((unsigned char *)body, (int)body_len);
	}

	// Parse required "type" field
	if (uss_extract_json_string(body, "type", type_str, sizeof(type_str)) < 0) {
		if (free_body) free(body);
		return sendErrorResponse(session, 400, 2, 8, 1,
			"Missing or invalid 'type' in request body", NULL, 0);
	}

	// Validate type
	if (strcmp(type_str, "file") != 0 &&
	    strcmp(type_str, "directory") != 0 &&
	    strcmp(type_str, "dir") != 0) {
		if (free_body) free(body);
		return sendErrorResponse(session, 400, 2, 8, 1,
			"Invalid 'type': must be 'file', 'directory', or 'dir'",
			NULL, 0);
	}

	// Parse optional "mode" field
	if (uss_extract_json_string(body, "mode", mode_str, sizeof(mode_str)) == 0) {
		parsed = uss_parse_mode(mode_str);
		if (parsed != 0) {
			perm = parsed;
		}
	}

	if (free_body) free(body);
	body = NULL;

	wtof("MVSMF83D type=%s perm=%04o", type_str, perm);

	// Open UFS session
	ufs = uss_open_session(session);
	if (!ufs) {
		return -1;
	}

	wtof("MVSMF83D UFS session opened");

	// Set create permission and save old value
	old_perm = ufs_set_create_perm(ufs, perm);

	wtof("MVSMF83D set_create_perm done, old=%04o", old_perm);

	if (strcmp(type_str, "file") == 0) {
		wtof("MVSMF83D creating file: %s", abspath);
		wtof("MVSMF83D before fopen(r) existence check");
		fp = ufs_fopen(ufs, abspath, "r");
		wtof("MVSMF83D fopen(r) returned %p", (void *)fp);
		if (fp) {
			wtof("MVSMF83D file exists, closing and returning 409");
			ufs_fclose(&fp);
			fp = NULL;
			ufs_set_create_perm(ufs, old_perm);
			rc = sendErrorResponse(session, 409, 4, 8, 1,
				"File or directory already exists", NULL, 0);
			goto quit;
		}

		wtof("MVSMF83D before fopen(w) create");
		fp = ufs_fopen(ufs, abspath, "w");
		wtof("MVSMF83D fopen(w) returned %p", (void *)fp);
		if (!fp) {
			urc = ufs_last_rc(ufs);
			wtof("MVSMF83D fopen(w) failed, urc=%d", urc);
			ufs_set_create_perm(ufs, old_perm);
			rc = sendErrorResponse(session,
				ufsd_rc_to_http(urc), ufsd_rc_to_category(urc), 8, 1,
				ufsd_rc_message(urc), NULL, 0);
			goto quit;
		}
		if (fp->error != UFSD_RC_OK) {
			urc = fp->error;
			ufs_fclose(&fp);
			fp = NULL;
			ufs_set_create_perm(ufs, old_perm);
			rc = sendErrorResponse(session,
				ufsd_rc_to_http(urc), ufsd_rc_to_category(urc), 8, 1,
				ufsd_rc_message(urc), NULL, 0);
			goto quit;
		}
		ufs_fclose(&fp);
		fp = NULL;
	} else {
		wtof("MVSMF83D creating directory: %s", abspath);
		wtof("MVSMF83D before diropen existence check");
		dd = ufs_diropen(ufs, abspath, NULL);
		wtof("MVSMF83D diropen returned %p", (void *)dd);
		if (dd) {
			wtof("MVSMF83D dir exists, closing and returning 409");
			ufs_dirclose(&dd);
			dd = NULL;
			ufs_set_create_perm(ufs, old_perm);
			rc = sendErrorResponse(session, 409, 4, 8, 1,
				"File or directory already exists", NULL, 0);
			goto quit;
		}

		wtof("MVSMF83D before mkdir");
		rc = ufs_mkdir(ufs, abspath);
		wtof("MVSMF83D mkdir returned rc=%d", rc);
		if (rc != 0) {
			urc = ufs_last_rc(ufs);
			wtof("MVSMF85E ufs_mkdir(%s) failed: rc=%d urc=%d",
				abspath, rc, urc);
			ufs_set_create_perm(ufs, old_perm);
			if (urc == 0) urc = UFSD_RC_NOFILE;
			rc = sendErrorResponse(session,
				ufsd_rc_to_http(urc), ufsd_rc_to_category(urc), 8, 1,
				ufsd_rc_message(urc), NULL, 0);
			goto quit;
		}
	}

	// Restore default permission
	ufs_set_create_perm(ufs, old_perm);

	// Success — 201 Created
	wtof("MVSMF83D create succeeded, sending 201");
	rc = sendDefaultHeaders(session, 201, HTTP_CONTENT_TYPE_NONE, 0);

quit:
	wtof("MVSMF83D quit: rc=%d headers_sent=%d", rc, session->headers_sent);
	if (ufs) {
		ufsfree(&ufs);
		session->ufs = NULL;
	}

	return rc;
}

int ussDeleteHandler(Session *session)
{
	return sendErrorResponse(session, 501, 10, 8, 1,
		"USS delete not yet implemented", NULL, 0);
}
