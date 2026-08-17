#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <time.h>
#include <clibwto.h>
#include <libufs.h>
#include <time64.h>

#include "ussapi.h"
#include "common.h"
#include "etag.h"
#include "httpcgi.h"

// Data type constants
#define USS_DATA_TYPE_TEXT   1
#define USS_DATA_TYPE_BINARY 2

// Wording deliberately identical to the data set path (ERR_MSG_ETAG_MISMATCH
// in dsapi_err.h): one condition, one message, whichever resource it is about.
#define USS_MSG_ETAG_MISMATCH \
	"The resource was modified since the supplied ETag was created"

// Forward declarations
static int uss_extract_json_string(const char *json, const char *key,
                                   char *out, size_t outlen);

//
// UFSD RC → HTTP status mapping
//
// Several rows below answer with a status that is not the most precise one HTTP
// offers. That is deliberate and it is not an httpd limitation: httpd learned
// 409, 414 and 507 in httpd#28/PR#56, and a live probe confirmed a CGI-set 414
// reaches the client unchanged. The constraint is z/OSMF, which enumerates the
// status codes its API uses -- 200, 204, 206, 304, 400, 401, 404, 405, 412,
// 413, 429, 500, 503 -- and mvsMF is a clone of it. "Already exists" and "not
// empty" are therefore 400 rather than 409, "no space" and "no inodes" are 500
// rather than 507, and "name too long" is 400 rather than 414. Closed as
// won't-do in #102; do not re-open it from the httpd side alone.
//
// UFSD_RC_ROFS answers 400 for the same reason, decided in #250 together with
// the 410 that used to come back for purged spool output. It could not be
// settled by measurement -- a read-only file system is a UFSD condition, and
// the reference has no equivalent state to provoke -- so it followed the rule
// the other rows follow rather than becoming a second exception. Category 4
// still separates it from the other bad requests. The row is unreachable in
// practice today: UFSD has no read-only mount, so nothing produces this rc.
//

__asm__("\n&FUNC    SETC 'ufsd_rc_to_http'");
static int
ufsd_rc_to_http(int rc)
{
	switch (rc) {
	case UFSD_RC_OK:          return 200;
	case UFSD_RC_NOFILE:      return 404;
	case UFSD_RC_EXIST:       return 400;  /* not 409: not a z/OSMF status */
	case UFSD_RC_NOTDIR:      return 400;
	case UFSD_RC_ISDIR:       return 400;
	case UFSD_RC_NOSPACE:     return 500;  /* not 507: not a z/OSMF status */
	case UFSD_RC_NOINODES:    return 500;  /* not 507: not a z/OSMF status */
	case UFSD_RC_IO:          return 500;
	case UFSD_RC_BADFD:       return 500;
	case UFSD_RC_NOTEMPTY:    return 400;  /* not 409: not a z/OSMF status */
	case UFSD_RC_NAMETOOLONG: return 400;  /* not 414: not a z/OSMF status */
	case UFSD_RC_ROFS:        return 400;  /* not 403: not a z/OSMF status */
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
// uss_open_rc — the diagnosis for a ufs_fopen() that returned NULL (issue #269)
//
// A failed open reports through the UFS session, not through the file handle:
// libufs stores the server's rc in the UFS handle and returns NULL, so the
// `fp->error` check that follows every open in this file only ever sees an
// error on a handle that was opened successfully — which is none.
//
// A directory is the case that made this visible. UFSD answers ISDIR for an
// open of one in either mode (ufsd#fil.c, read and write alike), so the whole
// mapping table above was unreachable from an open and every failure came back
// as 404 "not found" — including ROFS, NOSPACE and NOINODES.
//
// ufs_fopen() has two NULL returns that never reach the server and so leave
// last_rc at whatever an earlier call put there: a path too long for the
// request block, and a reply too short to hold a descriptor. Neither is
// distinguishable from here. Only the "nothing was recorded" case is caught —
// it keeps the 404 this code answered before — so a stale value can still name
// the wrong error on a request that was failing either way. The path that
// leads there is a name of 252 characters or more; see uss_build_path().
//

__asm__("\n&FUNC    SETC 'uss_open_rc'");
static int
uss_open_rc(UFS *ufs)
{
	int urc = ufs_last_rc(ufs);

	return (urc == UFSD_RC_OK) ? UFSD_RC_NOFILE : urc;
}

//
// UFS session helper — uses HTTPD-managed session via http_get_ufs()
//

__asm__("\n&FUNC    SETC 'uss_get_ufs'");
static UFS *
uss_get_ufs(Session *session)
{
	UFS *ufs = http_get_ufs(session->httpc);
	if (!ufs) {
		sendErrorResponse(session, 503, 1, 8, 1,
			"UFSD subsystem not available", NULL, 0);
		return NULL;
	}

	// Set session owner from ACEE (userid/group for permission checks)
	if (session->acee) {
		ACEE *acee = session->acee;
		char userid[9];
		char group[9];
		unsigned char ulen = (unsigned char)acee->aceeuser[0];
		unsigned char glen = (unsigned char)acee->aceegrp[0];
		if (ulen > 8) ulen = 8;
		if (glen > 8) glen = 8;
		memset(userid, 0, sizeof(userid));
		memset(group, 0, sizeof(group));
		memcpy(userid, acee->aceeuser + 1, ulen);
		memcpy(group, acee->aceegrp + 1, glen);
		ufs_setuser(ufs, userid, group);
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
// uss_etag — compute the ETag of a USS file (issue #264)
//
// One extra read pass, opened and closed here. Both callers go through this
// function -- the GET before it sends its headers, the PUT before it opens for
// output and again after the file is closed -- so there is one definition of
// the stamp and no way for the read side and the write side to drift apart.
//
// Three properties this depends on:
//
//   - The bytes are hashed exactly as stored. No translation: the payload the
//     GET sends is IBM-1047-translated in text mode and raw in binary mode, so
//     stamping what goes on the wire would give one file two stamps. The same
//     reason the PUT stamps by re-reading the closed file rather than by
//     hashing the request body it has just translated.
//
//   - etag_update_raw(), not etag_update(). A USS file is a byte stream; the
//     chunking below is the reader's business and must not reach the value.
//     See etag.h.
//
//   - It never runs while the same file is open elsewhere in the handler.
//     Open-hash-close, then open for the body.
//
// Returns 0 with out filled. On failure returns -1 and sets *ufs_rc to the
// UFSD diagnosis, which the caller needs: a path that is a directory is a
// different answer from a path that is not there (see uss_check_if_match).
//

#define USS_ETAG_BUFSZ 1024

__asm__("\n&FUNC    SETC 'uss_etag'");
static int
uss_etag(UFS *ufs, const char *path, char *out, size_t outlen, int *ufs_rc)
{
	ETAGCTX  ctx;
	UFSFILE *fp;
	char     buf[USS_ETAG_BUFSZ];
	UINT32   n;

	*ufs_rc = UFSD_RC_NOFILE;

	fp = ufs_fopen(ufs, path, "r");
	if (!fp) {
		return -1;
	}

	if (fp->error != UFSD_RC_OK) {
		*ufs_rc = fp->error;
		ufs_fclose(&fp);
		return -1;
	}

	etag_init(&ctx);
	while ((n = ufs_fread(buf, 1, sizeof(buf), fp)) > 0) {
		etag_update_raw(&ctx, buf, n);
	}

	// A read that stopped short leaves a stamp over a prefix of the file,
	// which would compare unequal to itself on the next attempt. Fail
	// instead: no stamp is better than an unstable one.
	if (ufs_ferror(fp)) {
		*ufs_rc = (fp->error != UFSD_RC_OK) ? fp->error : UFSD_RC_IO;
		ufs_fclose(&fp);
		return -1;
	}

	*ufs_rc = UFSD_RC_OK;
	ufs_fclose(&fp);

	return etag_final(&ctx, out, outlen);
}

//
// uss_check_if_match — enforce an If-Match precondition before a write (#264)
//
// Returns 0 when the write may proceed -- either no If-Match was sent, or it
// still matches. Returns -1 when an error response has already been sent, in
// which case the caller must return without writing anything.
//
// A file that cannot be read fails the precondition rather than falling
// through to the write: the client is asserting "the state I read is still
// there", and a file since deleted is exactly the case that assertion exists
// to catch. That covers "If-Match: *" too -- the wildcard asserts existence.
//
// A directory is the exception, and it falls through instead. Adding If-Match
// to a request must not change how a path that is not a file is answered, and
// this check runs before the open that answers it. That answer is 400 ISDIR
// since #269; whatever it becomes, it is the write path's to give.
//
// The probe is ufs_stat(), which reads metadata without an open. Deliberately
// not ufs_last_rc(): the open here failed for its own reasons, and a stale rc
// would silently skip a precondition rather than merely misname an error. If
// the probe cannot answer, the precondition fails: 412 and no write is the
// safe direction.
//

__asm__("\n&FUNC    SETC 'uss_ck_ifmatch'");
static int
uss_check_if_match(Session *session, UFS *ufs, const char *path)
{
	const char *if_match;
	char        current[ETAG_SIZE];
	int         urc = UFSD_RC_OK;

	if_match = getHeaderParam(session, "If-Match");
	if (!if_match) {
		return 0;
	}

	if (uss_etag(ufs, path, current, sizeof(current), &urc) < 0) {
		UFSDLIST st;

		memset(&st, 0, sizeof(st));
		if (ufs_stat(ufs, path, &st) == UFSD_RC_OK && st.attr[0] == 'd') {
			return 0;  /* let the write path answer it */
		}

		sendErrorResponse(session, 412, 4, 8, 1,
			USS_MSG_ETAG_MISMATCH, NULL, 0);
		return -1;
	}

	if (!etag_matches(if_match, current)) {
		sendErrorResponse(session, 412, 4, 8, 1,
			USS_MSG_ETAG_MISMATCH, NULL, 0);
		return -1;
	}

	return 0;
}

//
// Default max items for directory listing
//

#define USS_LIST_DEFAULT_MAX_ITEMS 1000

//
// uss_stat_file — stat a single file via parent directory scan
//
// When path points to a file, opens the parent directory, finds the
// matching entry, and returns a single-item JSON list with the full
// path in the name field.  Returns 0 on success, -1 on error (with
// HTTP error response already sent).
//

__asm__("\n&FUNC    SETC 'uss_stat_file'");
static int
uss_stat_file(Session *session, UFS *ufs, const char *path)
{
	char parent[UFS_PATH_MAX];
	char filename[60];
	const char *slash;
	size_t plen;
	UFSDDESC *dd;
	UFSDLIST *entry;
	struct tm *tm_info;
	char mtime_buf[32];
	int rc;

	slash = strrchr(path, '/');
	if (!slash || slash == path + strlen(path) - 1) {
		return sendErrorResponse(session, 404, 6, 8, 1,
			"Path not found", NULL, 0);
	}

	// Split into parent directory and filename
	plen = (size_t)(slash - path);
	if (plen == 0) {
		parent[0] = '/';
		parent[1] = '\0';
	} else if (plen >= sizeof(parent)) {
		return sendErrorResponse(session, 400, 2, 8, 1,
			"Path too long", NULL, 0);
	} else {
		memcpy(parent, path, plen);
		parent[plen] = '\0';
	}

	if (strlen(slash + 1) >= sizeof(filename)) {
		return sendErrorResponse(session, 400, 2, 8, 1,
			"Filename too long", NULL, 0);
	}
	strcpy(filename, slash + 1);

	dd = ufs_diropen(ufs, parent, NULL);
	if (!dd) {
		return sendErrorResponse(session, 404, 6, 8, 1,
			"Path not found", NULL, 0);
	}

	// Scan parent directory for matching entry
	while ((entry = ufs_dirread(dd)) != NULL) {
		if (strcmp(entry->name, filename) == 0) {
			break;
		}
	}

	if (!entry) {
		ufs_dirclose(&dd);
		return sendErrorResponse(session, 404, 6, 8, 1,
			"File not found", NULL, 0);
	}

	// Format mtime
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

	// Send single-item response with full path in name
	session->headers_sent = 1;
	if ((rc = http_resp(session->httpc, 200)) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Cache-Control: no-store\r\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Content-Type: %s\r\n", "application/json")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Pragma: no-cache\r\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Access-Control-Allow-Origin: *\r\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "\r\n")) < 0) goto quit;

	rc = http_printf(session->httpc,
		"{\n"
		"  \"items\": [\n"
		"    {\n"
		"      \"name\": \"%s\",\n"
		"      \"mode\": \"%s\",\n"
		"      \"size\": %u,\n"
		"      \"user\": \"%s\",\n"
		"      \"group\": \"%s\",\n"
		"      \"links\": %u,\n"
		"      \"mtime\": \"%s\",\n"
		"      \"inode\": %u\n"
		"    }\n"
		"  ],\n"
		"  \"returnedRows\": 1,\n"
		"  \"totalRows\": 1,\n"
		/* no moreRows: a stat reply is one row and complete by
		   construction, and the key is emitted only when true (#279) */
		"  \"JSONversion\": 1\n"
		"}\n",
		path, entry->attr, entry->filesize,
		entry->owner, entry->group,
		(unsigned) entry->nlink,
		mtime_buf, entry->inode_number);

quit:
	ufs_dirclose(&dd);
	return rc;
}

//
// ussListHandler — GET /zosmf/restfiles/fs?path=<filepath>
//
// Lists files and directories at the given path, returning
// z/OSMF-compatible JSON with file metadata from UFSDLIST entries.
// When path points to a file, delegates to uss_stat_file() for a
// single-item stat response.
//

int ussListHandler(Session *session)
{
	int rc = 0;
	int first = 1;
	unsigned maxitems = USS_LIST_DEFAULT_MAX_ITEMS;
	unsigned emitted = 0;
	unsigned total = 0;
	int more = 0;
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
	ufs = uss_get_ufs(session);
	if (!ufs) {
		return -1;
	}

	// Open directory — if this fails, path may be a file (stat query)
	dd = ufs_diropen(ufs, path, NULL);
	if (!dd) {
		return uss_stat_file(session, ufs, path);
	}

	/* Directory listing -- send response headers (streaming JSON).

	   A listing cut short by X-IBM-Max-Items stays 200 and carries the fact in
	   moreRows below -- measured against z/OSMF 29, which answers 200 for every
	   truncation and emits no 206 on the files service at all (#274).  Nothing
	   here therefore depends on knowing the size of the directory before the
	   status line goes out, and the single walk below is the whole listing:
	   there is no ufs_dirrewind(), so measuring up front would cost a close and
	   a second open of every directory the client puts a limit on. */
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
	/* The emit loop keeps counting after the page is full, so total is the
	   whole directory and this is exact -- for the client's limit and for
	   USS_LIST_DEFAULT_MAX_ITEMS alike, which truncates the same way. */
	more = (maxitems > 0 && emitted < total);
	/* only when true -- see the note in datasetListHandler() (#279) */
	if (more) {
		if ((rc = http_printf(session->httpc, "  \"moreRows\": true,\n")) < 0) goto quit;
	}
	if ((rc = http_printf(session->httpc, "  \"JSONversion\": 1\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "}\n")) < 0) goto quit;

quit:
	if (dd) {
		ufs_dirclose(&dd);
	}
	if (ufs) {
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
	char etag[ETAG_SIZE] = {0};
	const char *etag_hdr = NULL;
	const char *if_none_match;
	int want_etag;

	// Get filepath from path variable and build absolute path
	raw_path = getPathParam(session, "filepath");
	if (!raw_path || raw_path[0] == '\0') {
		return sendErrorResponse(session, 400, 2, 8, 1,
			"Missing file path", NULL, 0);
	}

	if (!uss_build_path(abspath, sizeof(abspath), raw_path)) {
		return sendErrorResponse(session, 400, 2, 8, 1,
			"Path name too long", NULL, 0);
	}

	// Determine data type from X-IBM-Data-Type header
	data_type = get_data_type(session);

	// Open UFS session
	ufs = uss_get_ufs(session);
	if (!ufs) {
		return -1;
	}

	// ETag, if asked for (issue #264). Before the file is opened for the
	// body: one handle on a path at a time, and the value has to be known
	// before the first response byte goes out anyway. That costs a second
	// read pass over the file, which is why it is opt-in.
	//
	// One pass serves both halves of the protocol -- the value returned for
	// X-IBM-Return-Etag and the comparison for If-None-Match (issue #271).
	// Hashing twice would be two chances for the two answers to disagree.
	//
	// A file that cannot be hashed simply gets no ETag here; the open below
	// then produces the real diagnosis rather than this pass guessing at one.
	// That is what keeps a directory answering 400 ISDIR instead of taking the
	// 304 branch on "If-None-Match: *" -- uss_etag() fails on it, so there is
	// no stamp to match. Deliberately no ufs_stat() probe like the write side
	// has (uss_check_if_match): there a failed hash means 412, so the probe is
	// load-bearing; here it already means "no ETag, let the open diagnose it".
	if_none_match = getHeaderParam(session, "If-None-Match");
	want_etag = etag_requested(getHeaderParam(session, "X-IBM-Return-Etag"));

	if (if_none_match || want_etag) {
		int urc = UFSD_RC_OK;

		if (uss_etag(ufs, abspath, etag, sizeof(etag), &urc) == 0) {
			if (if_none_match && etag_matches(if_none_match, etag)) {
				return send_not_modified(session, etag);
			}
			// Either header means the client wants the validator, and this
			// branch is only reached when one of them was sent -- so the
			// stamp goes out on the miss too. Without it a reader polling on
			// If-None-Match alone would get the changed content and no way to
			// ask about the next change.
			etag_hdr = etag;
		}
	}

	// Open file for reading. A NULL handle carries no error of its own —
	// the diagnosis is on the session (issue #269).
	fp = ufs_fopen(ufs, abspath, "r");
	if (!fp) {
		int urc = uss_open_rc(ufs);
		rc = sendErrorResponse(session,
			ufsd_rc_to_http(urc), ufsd_rc_to_category(urc), 8, 1,
			ufsd_rc_message(urc), NULL, 0);
		return rc;
	}

	// Check for error after open (e.g. ISDIR)
	if (fp->error != UFSD_RC_OK) {
		int urc = fp->error;
		ufs_fclose(&fp);
		rc = sendErrorResponse(session,
			ufsd_rc_to_http(urc), ufsd_rc_to_category(urc), 8, 1,
			ufsd_rc_message(urc), NULL, 0);
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
	if (etag_hdr) {
		if ((rc = http_printf(session->httpc, "ETag: %s\r\n", etag_hdr)) < 0) goto quit;
		/* ETag is not a CORS-safelisted response header: without this a
		   cross-origin client gets null from headers.get("ETag") and
		   cannot tell that apart from a server with no ETag support. */
		if ((rc = http_printf(session->httpc,
			"Access-Control-Expose-Headers: ETag\r\n")) < 0) goto quit;
	}
	if ((rc = http_printf(session->httpc, "\r\n")) < 0) goto quit;

	// Stream file content in chunks
	while ((n = ufs_fread(buf, 1, sizeof(buf), fp)) > 0) {
		if (data_type == USS_DATA_TYPE_TEXT) {
			http_xlate((unsigned char *)buf, n, httpx->xlate_1047->etoa);
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
	}

	return rc;
}

//
// chtag handler — responds to chtag list/set/remove requests.
// UFSD has no file tagging, so list returns "untagged" and
// set/remove are accepted as no-ops.
//

__asm__("\n&FUNC    SETC 'uss_chtag'");
static int
uss_handle_chtag(Session *session, const char *filepath, const char *body)
{
	char action[16] = {0};

	if (uss_extract_json_string(body, "action", action, sizeof(action)) < 0) {
		return sendErrorResponse(session, 400, 2, 8, 1,
			"Missing or invalid 'action' in chtag request", NULL, 0);
	}

	if (strcmp(action, "list") == 0) {
		// Return untagged default — UFSD has no file tagging.
		// Format matches z/OSMF: {"stdout":["- untagged    T=off <path>"]}
		char tagline[300];
		int len;

		snprintf(tagline, sizeof(tagline),
			"- untagged    T=off %s", filepath);

		session->headers_sent = 1;
		if (http_resp(session->httpc, 200) < 0) return -1;
		if (http_printf(session->httpc,
			"Content-Type: application/json\r\n") < 0) return -1;
		if (http_printf(session->httpc,
			"Cache-Control: no-store\r\n") < 0) return -1;
		if (http_printf(session->httpc,
			"Pragma: no-cache\r\n") < 0) return -1;
		if (http_printf(session->httpc,
			"Access-Control-Allow-Origin: *\r\n") < 0) return -1;
		if (http_printf(session->httpc, "\r\n") < 0) return -1;

		if (http_printf(session->httpc,
			"{\"stdout\":[\"%s\"]}\n", tagline) < 0) return -1;

		return 0;
	}

	if (strcmp(action, "set") == 0 || strcmp(action, "remove") == 0) {
		// Accept but no-op — UFSD doesn't support file tags
		return sendDefaultHeaders(session, 200, HTTP_CONTENT_TYPE_NONE, 0);
	}

	return sendErrorResponse(session, 400, 2, 8, 1,
		"Invalid chtag action", NULL, 0);
}

//
// USS utilities dispatcher — called when PUT has Content-Type: application/json.
// Dispatches by the "request" field in the JSON body.
// Currently only "chtag" is implemented; any other utility is a 400.
//

__asm__("\n&FUNC    SETC 'uss_utilities'");
static int
uss_handle_utilities(Session *session, const char *filepath)
{
	int rc = 0;
	int free_body = 0;
	char *body = NULL;
	size_t body_len = 0;
	char request[32] = {0};

	// Read request body — try POST_STRING first (HTTPD pre-reads when
	// Content-Type is set), fall back to socket read otherwise.
	body = (char *)http_get_env(session->httpc,
		(const UCHAR *)"POST_STRING");

	if (body && *body) {
		body_len = strlen(body);
	} else {
		if (read_request_content(session, &body, &body_len) < 0 ||
				body_len == 0) {
			if (body) free(body);
			return sendErrorResponse(session, 400, 2, 8, 1,
				"Failed to read request body", NULL, 0);
		}
		free_body = 1;

		// Convert from ASCII to EBCDIC (IBM-1047) for JSON parsing
		http_xlate((unsigned char *)body, (int)body_len, httpx->xlate_1047->atoe);
	}

	// Extract "request" field to determine which utility
	if (uss_extract_json_string(body, "request", request, sizeof(request)) < 0) {
		if (free_body) free(body);
		return sendErrorResponse(session, 400, 2, 8, 1,
			"Missing or invalid 'request' in JSON body", NULL, 0);
	}

	if (strcmp(request, "chtag") == 0) {
		rc = uss_handle_chtag(session, filepath, body);
		if (free_body) free(body);
		return rc;
	}

	// Any other utility: 400, not 501. The service offers exactly one utility,
	// so a request naming another one is an incorrect parameter -- and 501 is
	// not a z/OSMF status in any case (see ufsd_rc_to_http above). Category 2
	// for the same reason the other bad requests in this function use it.
	if (free_body) free(body);
	return sendErrorResponse(session, 400, 2, 8, 1,
		"Unsupported utility request", NULL, 0);
}

//
// ussPutHandler — PUT /zosmf/restfiles/fs/{*filepath}
//
// Writes data to a file via ufs_fopen("w") + ufs_fwrite().
// Creates the file if it does not exist.
// Content-Type application/json dispatches to utilities handler.
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
	char etag[ETAG_SIZE] = {0};
	const char *etag_hdr = NULL;

	// Get filepath from path variable and build absolute path
	raw_path = getPathParam(session, "filepath");
	if (!raw_path || raw_path[0] == '\0') {
		return sendErrorResponse(session, 400, 2, 8, 1,
			"Missing file path", NULL, 0);
	}

	if (!uss_build_path(abspath, sizeof(abspath), raw_path)) {
		return sendErrorResponse(session, 400, 2, 8, 1,
			"Path name too long", NULL, 0);
	}

	// Check Content-Type: application/json → dispatch to utilities handler
	content_type = getHeaderParam(session, "Content-Type");
	if (content_type && strstr(content_type, "application/json") != NULL) {
		return uss_handle_utilities(session, abspath);
	}

	// Determine data type from X-IBM-Data-Type header
	data_type = get_data_type(session);

	// Read request body (supports Content-Length and chunked encoding)
	if (read_request_content(session, &body, &body_len) < 0) {
		sendErrorResponse(session, 400, 2, 8, 1,
			"Failed to read request body", NULL, 0);
		return -1;
	}
	// An empty body is valid: it truncates the file to zero length (e.g. Zowe
	// saving an emptied file, or uploading a touch'd file). The dataset PUT
	// handler allows this too, so do not reject body_len == 0 here.

	// Text mode: ASCII→EBCDIC (IBM-1047) before writing
	if (data_type == USS_DATA_TYPE_TEXT) {
		http_xlate((unsigned char *)body, (int)body_len, httpx->xlate_1047->atoe);
	}

	// Open UFS session
	ufs = uss_get_ufs(session);
	if (!ufs) {
		free(body);
		return -1;
	}

	// If-Match, before the file is opened for output (issue #264). The "w"
	// open truncates, so a precondition checked after it would already have
	// destroyed the content it exists to protect. The body is read first
	// regardless -- leaving it in the socket would break the connection for
	// the next request on it.
	if (uss_check_if_match(session, ufs, abspath) < 0) {
		free(body);
		return 0;
	}

	// Open file for writing (creates if not exists). A NULL handle carries no
	// error of its own — the diagnosis is on the session (issue #269).
	fp = ufs_fopen(ufs, abspath, "w");
	if (!fp) {
		int urc = uss_open_rc(ufs);
		rc = sendErrorResponse(session,
			ufsd_rc_to_http(urc), ufsd_rc_to_category(urc), 8, 1,
			ufsd_rc_message(urc), NULL, 0);
		goto quit;
	}

	// Check for error after open
	if (fp->error != UFSD_RC_OK) {
		int urc = fp->error;
		ufs_fclose(&fp);
		fp = NULL;
		rc = sendErrorResponse(session,
			ufsd_rc_to_http(urc), ufsd_rc_to_category(urc), 8, 1,
			ufsd_rc_message(urc), NULL, 0);
		goto quit;
	}

	// Write body to file (an empty body just truncates: the "w" open above
	// already set the file to zero length, so skip the zero-length write)
	written = body_len ? ufs_fwrite(body, 1, (UINT32)body_len, fp) : 0;
	if (written != (UINT32)body_len) {
		int urc = fp->error;
		ufs_fclose(&fp);
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

	// Close before stamping: the write-behind buffer is only flushed here,
	// so a stamp taken with the file still open would hash a stale tail.
	ufs_fclose(&fp);
	fp = NULL;

	// ETag of the state just written (issue #264), from re-reading the closed
	// file -- never from hashing the request body. The body has been
	// translated in place by now, and one definition of the stamp is what
	// makes the value a PUT returns usable as the next If-Match.
	if (etag_requested(getHeaderParam(session, "X-IBM-Return-Etag"))) {
		int urc = UFSD_RC_OK;

		if (uss_etag(ufs, abspath, etag, sizeof(etag), &urc) == 0) {
			etag_hdr = etag;
		}
	}

	// Success — 204 No Content. Hand-rolled rather than via
	// sendDefaultHeaders(), which has nowhere to put the ETag.
	session->headers_sent = 1;
	if ((rc = http_resp(session->httpc, 204)) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Cache-Control: no-store\r\n")) < 0) goto quit;
	if ((rc = http_printf(session->httpc, "Access-Control-Allow-Origin: *\r\n")) < 0) goto quit;
	if (etag_hdr) {
		if ((rc = http_printf(session->httpc, "ETag: %s\r\n", etag_hdr)) < 0) goto quit;
		if ((rc = http_printf(session->httpc,
			"Access-Control-Expose-Headers: ETag\r\n")) < 0) goto quit;
	}
	if ((rc = http_printf(session->httpc, "\r\n")) < 0) goto quit;

quit:
	if (fp) {
		ufs_fclose(&fp);
	}
	free(body);
	if (ufs) {
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

	// Get filepath from path variable and build absolute path
	raw_path = getPathParam(session, "filepath");
	if (!raw_path || raw_path[0] == '\0') {
		return sendErrorResponse(session, 400, 2, 8, 1,
			"Missing file path", NULL, 0);
	}

	if (!uss_build_path(abspath, sizeof(abspath), raw_path)) {
		return sendErrorResponse(session, 400, 2, 8, 1,
			"Path name too long", NULL, 0);
	}

	// Read request body — try POST_STRING first (HTTPD pre-reads when
	// Content-Type is set), fall back to socket read otherwise.
	// POST_STRING is already in EBCDIC; socket data needs conversion.
	body = (char *)http_get_env(session->httpc,
		(const UCHAR *)"POST_STRING");

	if (body && *body) {
		body_len = strlen(body);
	} else {
		if (read_request_content(session, &body, &body_len) < 0 ||
				body_len == 0) {
			if (body) free(body);
			return sendErrorResponse(session, 400, 2, 8, 1,
				"Failed to read request body", NULL, 0);
		}
		free_body = 1;

		// Convert from ASCII to EBCDIC (IBM-1047) for JSON parsing
		http_xlate((unsigned char *)body, (int)body_len, httpx->xlate_1047->atoe);
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

	// Open UFS session
	ufs = uss_get_ufs(session);
	if (!ufs) {
		return -1;
	}

	// Set create permission and save old value
	old_perm = ufs_set_create_perm(ufs, perm);

	if (strcmp(type_str, "file") == 0) {
		// Check if file already exists (ufs_fopen "w" would truncate)
		fp = ufs_fopen(ufs, abspath, "r");
		if (fp) {
			ufs_fclose(&fp);
			fp = NULL;
			ufs_set_create_perm(ufs, old_perm);
			rc = sendErrorResponse(session, 400, 4, 8, 1,
				"File or directory already exists", NULL, 0);
			goto quit;
		}

		// Create file: open for write then immediately close
		fp = ufs_fopen(ufs, abspath, "w");
		if (!fp) {
			urc = ufs_last_rc(ufs);
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
		// Check if directory already exists via diropen
		dd = ufs_diropen(ufs, abspath, NULL);
		if (dd) {
			ufs_dirclose(&dd);
			dd = NULL;
			ufs_set_create_perm(ufs, old_perm);
			rc = sendErrorResponse(session, 400, 4, 8, 1,
				"File or directory already exists", NULL, 0);
			goto quit;
		}

		// Create directory
		rc = ufs_mkdir(ufs, abspath);
		if (rc != 0) {
			urc = ufs_last_rc(ufs);
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
	rc = sendDefaultHeaders(session, 201, HTTP_CONTENT_TYPE_NONE, 0);

quit:
	if (ufs) {
	}

	return rc;
}

//
// Recursively delete a directory and all its contents.
// Walks the directory tree depth-first: removes files via ufs_remove(),
// recurses into subdirectories, then removes the now-empty directory.
//

__asm__("\n&FUNC    SETC 'uss_rec_del'");
static int
uss_recursive_delete(UFS *ufs, const char *path)
{
	UFSDDESC *dd = NULL;
	UFSDLIST *entry = NULL;
	char fullpath[UFS_PATH_MAX];
	int rc;

	dd = ufs_diropen(ufs, path, NULL);
	if (!dd) return -1;

	while ((entry = ufs_dirread(dd)) != NULL) {
		if (strcmp(entry->name, ".") == 0 ||
			strcmp(entry->name, "..") == 0) {
			continue;
		}

		snprintf(fullpath, sizeof(fullpath), "%s/%s", path, entry->name);

		if (entry->attr[0] == 'd') {
			rc = uss_recursive_delete(ufs, fullpath);
			if (rc != 0) {
				ufs_dirclose(&dd);
				return rc;
			}
		} else {
			rc = ufs_remove(ufs, fullpath);
			if (rc != 0) {
				ufs_dirclose(&dd);
				return rc;
			}
		}
	}

	ufs_dirclose(&dd);
	return ufs_rmdir(ufs, path);
}

//
// ussDeleteHandler — DELETE /zosmf/restfiles/fs/{*filepath}
//
// Deletes a file or directory. Strategy:
// 1. Try ufs_remove() first (works for regular files)
// 2. If ISDIR (RC 40): use ufs_rmdir() or uss_recursive_delete()
//    depending on X-IBM-Option: recursive header
// 3. Any other non-zero rc is reported from ufs_last_rc() — NOFILE (28)
//    for a path that is not there, so no existence probe is needed.
//
// Response: 204 No Content on success
//

__asm__("\n&FUNC    SETC 'UAPI0005'");
int ussDeleteHandler(Session *session)
{
	int rc = 0;
	int urc;
	int is_recursive = 0;
	char *raw_path = NULL;
	char abspath[UFS_PATH_MAX];
	char *option = NULL;
	UFS *ufs = NULL;

	// Get filepath from path variable and build absolute path
	raw_path = getPathParam(session, "filepath");
	if (!raw_path || raw_path[0] == '\0') {
		return sendErrorResponse(session, 400, 2, 8, 1,
			"Missing file path", NULL, 0);
	}

	if (!uss_build_path(abspath, sizeof(abspath), raw_path)) {
		return sendErrorResponse(session, 400, 2, 8, 1,
			"Path name too long", NULL, 0);
	}

	// Check X-IBM-Option header for recursive delete
	option = getHeaderParam(session, "X-IBM-Option");
	if (option && strcmp(option, "recursive") == 0) {
		is_recursive = 1;
	}

	// Open UFS session
	ufs = uss_get_ufs(session);
	if (!ufs) {
		return -1;
	}

	// Regular file — one round trip. ufs_remove() reports ISDIR for a
	// directory and NOFILE for a path that does not exist (ufsd#9).
	rc = ufs_remove(ufs, abspath);
	if (rc == 0) {
		return sendDefaultHeaders(session, 204, HTTP_CONTENT_TYPE_NONE, 0);
	}

	urc = ufs_last_rc(ufs);
	if (urc != UFSD_RC_ISDIR) {
		return sendErrorResponse(session,
			ufsd_rc_to_http(urc), ufsd_rc_to_category(urc), 8, 1,
			ufsd_rc_message(urc), NULL, 0);
	}

	// Path is a directory — use rmdir or recursive delete
	if (is_recursive) {
		rc = uss_recursive_delete(ufs, abspath);
	} else {
		rc = ufs_rmdir(ufs, abspath);
	}

	if (rc == 0) {
		return sendDefaultHeaders(session, 204, HTTP_CONTENT_TYPE_NONE, 0);
	}

	urc = ufs_last_rc(ufs);
	return sendErrorResponse(session,
		ufsd_rc_to_http(urc), ufsd_rc_to_category(urc), 8, 1,
		ufsd_rc_message(urc), NULL, 0);
}
