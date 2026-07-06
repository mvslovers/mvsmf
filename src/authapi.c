#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <clibb64.h>

#include "authapi.h"
#include "common.h"
#include "json.h"
#include "httpcgi.h"

/*
 * z/OSMF Authentication service -- POST/DELETE /zosmf/services/authenticate.
 * See docs/endpoints/auth/authenticate.md.
 *
 * httpd resolves the client credential before dispatching here (Basic on the
 * login POST, LtpaToken2 cookie / Bearer on later calls) and exposes it via
 * the HTTPX auth export. These handlers only READ that state:
 *   - login  reads the session token (http_get_token) and hands it back as
 *            the LtpaToken2 cookie (base64 of httpd's opaque CREDTOK);
 *   - logout drops the credential (http_logout -> credtok_logout).
 * mvsMF owns no credential-store logic and issues no per-request racf_login.
 *
 * The response body is the z/OSMF login shape { returnCode, reasonCode,
 * message } -- NOT the restfiles { category, rc, reason } shape -- so it is
 * built here directly rather than via sendErrorResponse().
 *
 * NOTE: MVSMF is link-edited RENT (read-only static storage) -- this module
 * keeps NO writable static/global data; all state is on the stack or heap.
 */

/* z/OSMF login-result messages (IBM "log in to the z/OSMF server" spec). */
#define AUTH_MSG_SUCCESS      "Success."
#define AUTH_MSG_LOGIN_FAILED "Login failed. Check whether the user ID and "  \
                              "password you use for the Basic Auth is "       \
                              "correct, and if the user ID has the required " \
                              "SAF permissions."
#define AUTH_MSG_INTERNAL     "The request failed because an internal error " \
                              "occurred."

/* CREDTOK is 32 bytes (SHA-256); 64 leaves head-room without pulling in the
 * credentials layout. http_get_token() returns the actual byte count. */
#define AUTH_TOKEN_BUFSIZE    64

/* "LtpaToken2=" + 44 base64 chars (32-byte token) + "; Path=/" fits easily. */
#define AUTH_COOKIE_BUFSIZE   128

/* ------------------------------------------------------------------ */
/* Build the z/OSMF login body { returnCode, reasonCode, message }.    */
/* Returns a malloc'd JSON string (caller frees) or NULL on failure.   */
/* ------------------------------------------------------------------ */
__asm__("\n&FUNC	SETC 'auth_body'");
static char *
auth_body(int return_code, int reason_code, const char *message)
{
	char *json = NULL;
	JsonBuilder *b = createJsonBuilder();
	if (!b) {
		return NULL;
	}

	if (startJsonObject(b) < 0 ||
	    addJsonNumber(b, "returnCode", return_code) < 0 ||
	    addJsonNumber(b, "reasonCode", reason_code) < 0 ||
	    addJsonString(b, "message", message) < 0 ||
	    endJsonObject(b) < 0) {
		freeJsonBuilder(b);
		return NULL;
	}

	json = getJsonString(b);   /* caller frees */
	freeJsonBuilder(b);
	return json;
}

/* ------------------------------------------------------------------ */
/* Emit a complete response: status line, optional Set-Cookie, the     */
/* standard headers, and an optional JSON body. Headers and body go    */
/* through http_printf, which converts EBCDIC->ASCII on the wire. A    */
/* NULL body sends no Content-Type/Content-Length (used for 204).      */
/* ------------------------------------------------------------------ */
__asm__("\n&FUNC	SETC 'auth_send'");
static int
auth_send(Session *session, int status, const char *set_cookie, const char *json)
{
	HTTPC *httpc = session->httpc;
	int rc = 0;

	session->headers_sent = 1;

	rc = http_resp(httpc, status);
	if (rc < 0) {
		return rc;
	}

	if (set_cookie) {
		rc = http_printf(httpc, "Set-Cookie: %s\r\n", set_cookie);
		if (rc < 0) {
			return rc;
		}
	}

	if (json) {
		rc = http_printf(httpc, "Content-Type: %s\r\n", HTTP_CONTENT_TYPE_JSON);
		if (rc < 0) {
			return rc;
		}
		rc = http_printf(httpc, "Content-Length: %d\r\n", (int)strlen(json));
		if (rc < 0) {
			return rc;
		}
	} else if (status != 204) {
		/* Header-only response with an explicit empty body. Send Content-Length: 0
		   so http_printf does not inject Transfer-Encoding: chunked on it (204 is
		   body-less and is handled without a Content-Length). */
		rc = http_printf(httpc, "Content-Length: 0\r\n");
		if (rc < 0) {
			return rc;
		}
	}

	rc = http_printf(httpc, "Cache-Control: no-store\r\n");
	if (rc < 0) {
		return rc;
	}
	rc = http_printf(httpc, "Access-Control-Allow-Origin: *\r\n");
	if (rc < 0) {
		return rc;
	}
	rc = http_printf(httpc, "\r\n");
	if (rc < 0) {
		return rc;
	}

	if (json) {
		rc = http_printf(httpc, "%s", json);
		if (rc < 0) {
			return rc;
		}
	}

	return 0;
}

/* ------------------------------------------------------------------ */
/* POST /zosmf/services/authenticate                                   */
/* ------------------------------------------------------------------ */
int authLoginHandler(Session *session)
{
	HTTPC *httpc = session->httpc;
	UCHAR token[AUTH_TOKEN_BUFSIZE];
	int toklen = 0;
	unsigned char *b64 = NULL;
	size_t b64len = 0;
	char cookie[AUTH_COOKIE_BUFSIZE];
	char *json = NULL;
	int rc = 0;

	/* httpd has already resolved the Basic credential into httpc->cred; we
	   only read the resulting session token. 0 => no credential resolved
	   (bad or missing credentials) => z/OSMF-shaped 401. */
	toklen = http_get_token(httpc, token, sizeof(token));
	if (toklen <= 0) {
		json = auth_body(8, 1, AUTH_MSG_LOGIN_FAILED);
		rc = auth_send(session, HTTP_STATUS_UNAUTHORIZED, NULL, json);
		if (json) {
			free(json);
		}
		return rc;
	}

	/* The token is httpd's opaque CREDTOK; base64 it into the LtpaToken2
	   cookie value. base64_encode emits EBCDIC (the @@B64TBL alphabet is a C
	   string literal); http_printf then converts it to ASCII on the wire, so
	   it round-trips with httpd's base64_decode on later requests. */
	b64 = base64_encode(token, (size_t)toklen, &b64len);
	if (!b64) {
		json = auth_body(4, 40, AUTH_MSG_INTERNAL);
		rc = auth_send(session, HTTP_STATUS_INTERNAL_SERVER_ERROR, NULL, json);
		if (json) {
			free(json);
		}
		return rc;
	}

	/* Path=/ so the cookie is sent on the whole /zosmf API (the endpoint
	   lives under /zosmf/services/, not root). No Secure attribute: the MVS
	   deployment is plain HTTP and Secure would suppress the cookie. */
	(void)snprintf(cookie, sizeof(cookie),
	               "LtpaToken2=%s; Path=/", (char *)b64);

	json = auth_body(0, 0, AUTH_MSG_SUCCESS);
	rc = auth_send(session, HTTP_STATUS_OK, cookie, json);

	if (json) {
		free(json);
	}
	free(b64);
	return rc;
}

/* ------------------------------------------------------------------ */
/* DELETE /zosmf/services/authenticate                                 */
/* ------------------------------------------------------------------ */
int authLogoutHandler(Session *session)
{
	HTTPC *httpc = session->httpc;
	int rc = 0;

	/* Drop the credential from httpd's store. rc < 0 means there was no live
	   credential -- the request carried no valid token. The z/OSMF logout spec
	   requires one, so reject with 401. (Reachable now that httpd forwards the
	   authenticate route to the CGI; when httpd gates it, httpd 401s first.) */
	rc = http_logout(httpc);
	if (rc < 0) {
		return auth_send(session, HTTP_STATUS_UNAUTHORIZED, NULL, NULL);
	}

	/* Token invalidated: 204 No Content per the IBM logout spec; expire the
	   cookie client-side (mirrors httpd's Sec-Token deletion). auth_send sends
	   no body for a NULL json, and http_printf treats 204 as body-less. */
	return auth_send(session, 204,
	                 "LtpaToken2=deleted; Path=/; "
	                 "expires=Thu, 01 Jan 1970 00:00:00 GMT",
	                 NULL);
}
