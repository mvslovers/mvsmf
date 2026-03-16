#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <clibwto.h>
#include <libufs.h>

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
// Handler stubs — return 501 Not Implemented
//

int ussListHandler(Session *session)
{
	return sendErrorResponse(session, 501, 10, 8, 1,
		"USS list not yet implemented", NULL, 0);
}

int ussGetHandler(Session *session)
{
	return sendErrorResponse(session, 501, 10, 8, 1,
		"USS file read not yet implemented", NULL, 0);
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
