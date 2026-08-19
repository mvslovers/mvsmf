#include <clibstr.h>
#include <clibio.h>
#include <clibsmf.h>
#include <clibthrd.h>
#include <clibwto.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "common.h"
#include "httpcgi.h"
#include "json.h"
#include "mvsmfmsg.h"
#include "sendall.h"

#define INITIAL_BUFFER_SIZE 4096

//
// private function prototypes
//

static int send_data(Session *session, char *buf);
static char *get_env_param(Session *session, const char *prefix, const char *name);

//
// public functions
//

char *
getQueryParam(Session *session, const char *name)
{
	return get_env_param(session, "QUERY_", name);
}

char *
getPathParam(Session *session, const char *name)
{
	return get_env_param(session, "HTTP_", name);
}

char *
getHeaderParam(Session *session, const char *name)
{
	return get_env_param(session, "HTTP_", name);
}

const char *
getRequestScheme(Session *session)
{
	const char *proto = getHeaderParam(session, "X-Forwarded-Proto");

	if (!proto) {
		return "http";
	}

	/* Chained proxies append their own value, so the header can be a list
	   ("https, http"); the leftmost entry is the one the client used. */
	if (http_cmpn((const UCHAR *)proto, (const UCHAR *)"https", 5) == 0 &&
		(proto[5] == '\0' || proto[5] == ',' || proto[5] == ' ')) {
		return "https";
	}

	return "http";
}

/* The headers every mvsMF response carries, in one place.
 *
 * Before #324 fourteen call sites across common.c, authapi.c, dsapi.c and
 * ussapi.c each wrote their own block, and they had drifted: two sites sent
 * Cache-Control: no-cache where the rest sent no-store, auth_send sent neither
 * Cache-Control nor the CORS header, and Content-Length: 0 for an empty body
 * had been fixed in auth_send only.
 *
 * FRAMING STAYS WITH THE CALLER and must not move in here: Content-Type,
 * Content-Length and Transfer-Encoding depend on the status. A 204 and a 304
 * carry no body and no Content-Length, so a shared block that emitted one
 * would break send_not_modified() and auth_send()'s 204 path.
 *
 * No Access-Control-Allow-Origin. The reference z/OSMF sends no CORS header at
 * all, the Desktop is served from this httpd and is same-origin, and the
 * wildcard could never have helped a cross-origin client anyway: browsers
 * reject "*" for a credentialed request, and every mvsMF route is
 * authenticated. It protected nothing and enabled nothing. If a cross-origin
 * browser client is ever wanted, it needs an origin allowlist and
 * Access-Control-Allow-Credentials, not a wildcard.
 */
/* Is this request a scripted request from inside a browser page?
 *
 * Only a browser fetch/XHR is withheld the WWW-Authenticate challenge below,
 * so this has to separate "a page's JavaScript asked" from everything else.
 * Two independent signals, either is enough:
 *
 *   X-MVSMF-Client   the Desktop sends it on every apiFetch (static/js/
 *                    systems.js). We control both ends, so it does not depend
 *                    on what httpd chooses to pass through.
 *   Sec-Fetch-Mode   set by the browser itself on subresource requests and by
 *                    no CLI. "navigate" is excluded deliberately: that is a
 *                    top-level navigation -- somebody typing the URL -- where
 *                    the browser's own credential prompt is the useful answer,
 *                    not an obstacle.
 *
 * X-CSRF-ZOSMF-HEADER is deliberately NOT used even though the Desktop sends
 * it: Zowe and the SDKs send it too, and they must keep getting exactly what
 * the reference sends.
 */
__asm__("\n&FUNC	SETC 'is_browser_fetch'");
static
int is_browser_fetch(Session *session)
{
	const char *mode;

	if (getHeaderParam(session, "X-MVSMF-Client")) {
		return 1;
	}

	mode = getHeaderParam(session, "Sec-Fetch-Mode");
	if (mode && strcmp(mode, "navigate") != 0) {
		return 1;
	}

	return 0;
}

/* RFC 9110 11.6.1: a 401 MUST carry a challenge, and the reference z/OSMF sends
 * one on every endpoint -- measured, including to a client identifying itself
 * with X-CSRF-ZOSMF-HEADER, so there is no "API client" exemption to copy.
 *
 * The single exception is a browser fetch, and it is not cosmetic. Measured
 * (tests/probe-401-dialog.py): a same-origin fetch or XHR receiving a 401 with
 * this header makes the browser open its native credential dialog AND WITHHOLD
 * THE RESPONSE until a human dismisses it -- 6080 ms and 4805 ms in the run
 * that settled this. The Desktop's own "session expired -> login" handling
 * (the mvsmf:session-expired event in systems.js) never gets to run, and once
 * the dialog is satisfied the browser caches those Basic credentials and
 * replays them on every same-origin request, outliving the token logout that
 * mvsmf#161 exists to make meaningful.
 *
 * The reference has no equivalent client: its REST API is consumed by CLIs and
 * SDKs, and its browser clients sit behind the API Mediation Layer, which
 * terminates authentication itself. So no client the reference serves sees a
 * difference here.
 *
 * No-op for every status but 401.
 */
/* The Basic realm, from the SMF ID -- the same string httpd derives for its own
 * challenges (httpd#191, src/httprlm.c).
 *
 * Matching it is not cosmetic. A browser caches Basic credentials under
 * (origin, realm), and httpd and this CGI answer on the SAME origin: two
 * different realms there are two protection spaces, so a user who satisfied
 * one dialog is asked again by the other. A constant would be worse still --
 * that is exactly what httpd#191 removed, because it made every system on the
 * network advertise one shared protection space with no way for a human to
 * tell which machine was asking.
 *
 * Duplicated rather than shared: httprlm() lives in the server binary, and the
 * CGI-side httpd.a carries only the cgistart stub, so there is nothing to link
 * against. The rules are httpd's -- copy at most 4 characters, stop at the
 * first blank or NUL (__smfid() hands over a fixed 4-byte blank-padded field
 * that is not terminated, so neither bound may be dropped), and never produce
 * an empty realm, which RFC 7617 does not allow and which would collapse every
 * protection space on the origin into one.
 */
#define AUTH_REALM_MAX      8
#define AUTH_REALM_FALLBACK "MVS"

__asm__("\n&FUNC	SETC 'auth_realm'");
static
const char *auth_realm(char *out, size_t outlen)
{
	const unsigned char *smfid = __smfid();
	size_t n = 0;

	while (n < 4 && n < outlen - 1 && smfid && smfid[n] && smfid[n] != ' ') {
		out[n] = (char)smfid[n];
		n++;
	}

	if (n == 0) {
		strncpy(out, AUTH_REALM_FALLBACK, outlen - 1);
		out[outlen - 1] = '\0';
		return out;
	}

	out[n] = '\0';

	return out;
}

__asm__("\n&FUNC	SETC 'send_auth_challenge'");
int
send_auth_challenge(Session *session, int status)
{
	char realm[AUTH_REALM_MAX];

	if (status != HTTP_STATUS_UNAUTHORIZED || is_browser_fetch(session)) {
		return 0;
	}

	return http_printf(session->httpc,
			"WWW-Authenticate: Basic realm=\"%s\"\r\n",
			auth_realm(realm, sizeof(realm)));
}

__asm__("\n&FUNC	SETC 'send_common_headers'");
int
send_common_headers(Session *session)
{
	int rc;

	if ((rc = http_printf(session->httpc,
			"Cache-Control: no-store\r\n")) < 0) return rc;
	if ((rc = http_printf(session->httpc,
			"Pragma: no-cache\r\n")) < 0) return rc;
	if ((rc = http_printf(session->httpc,
			"X-Content-Type-Options: nosniff\r\n")) < 0) return rc;
	if ((rc = http_printf(session->httpc,
			"Content-Language: en\r\n")) < 0) return rc;

	return rc;
}

int
sendDefaultHeaders(Session *session, int status, const char *content_type,
					   size_t content_length)
{
	int irc = 0;

	session->headers_sent = 1;

	irc = http_resp(session->httpc, status);
	if (irc < 0) {
		goto quit;
	}

	if (content_type && (strcmp(HTTP_CONTENT_TYPE_NONE, content_type) != 0)) {
		irc = http_printf(session->httpc, "Content-Type: %s\r\n", content_type);
		if (irc < 0) {
			goto quit;
		}
	}

	if (content_length > 0) {
		irc = http_printf(session->httpc, "Content-Length: %d\r\n", content_length);
		if (irc < 0) {
			goto quit;
		}
	} else if (!content_type || strcmp(HTTP_CONTENT_TYPE_NONE, content_type) == 0) {
		/* Content-Length: 0 for a body-less reply, not silence -- omitting it
		   made httpd fall back to Transfer-Encoding: chunked on a bodiless
		   401, where the reference sends Content-Length: 0 (#324).

		   The test is the content type, NOT content_length == 0: a zero length
		   also means "streaming, length not known yet", which is how
		   jobsapi.c:704 and :860 read spool records -- they declare
		   text/plain with length 0 and write the body afterwards. Announcing
		   Content-Length: 0 there would truncate the response to nothing.
		   HTTP_CONTENT_TYPE_NONE is the unambiguous "there is no body". */
		irc = http_printf(session->httpc, "Content-Length: 0\r\n");
		if (irc < 0) {
			goto quit;
		}
	}

	irc = send_auth_challenge(session, status);
	if (irc < 0) {
		goto quit;
	}

	irc = send_common_headers(session);
	if (irc < 0) {
		goto quit;
	}

  	irc = http_printf(session->httpc, "\r\n");
  	if (irc < 0) {
		goto quit;
  	}

quit:
	return irc;
}

int 
sendJSONResponse(Session *session, int status, JsonBuilder *builder)
{
  	int irc = 0;
  	char *json_str = NULL;

	if (!builder) {
		irc = -1;
		goto quit;
	}

	json_str = getJsonString(builder);
	if (!json_str) {
		irc = -1;
		goto quit;
	}

	irc = sendDefaultHeaders(session, status, HTTP_CONTENT_TYPE_JSON,
							strlen(json_str));
	if (irc < 0) {
		goto quit;
	}

	irc = send_data(session, json_str);

quit:
	if (json_str) {
		free(json_str);
	}

  	return irc;
}

int 
sendErrorResponse(Session *session, int status, int category, int rc,
					  int reason, const char *message, const char **details,
					  int details_count)
{
	int irc = RC_SUCCESS;  

	JsonBuilder *builder = createJsonBuilder();
	if (!builder) {
		goto quit;
	}

	irc = startJsonObject(builder);
	if (irc < 0) {
		goto quit;
	}

	irc = addJsonNumber(builder, "rc", rc);
	if (irc < 0) {
		goto quit;
	}

	irc = addJsonNumber(builder, "category", category);
	if (irc < 0) {
		goto quit;
	}

	irc = addJsonNumber(builder, "reason", reason);
	if (irc < 0) {
		goto quit;
	}

	if (message) {
		irc = addJsonString(builder, "message", message);
		if (irc < 0) {
			goto quit;
		}
	}

	/* "details" is an ARRAY of sentences, which is what z/OSMF sends and what
	 * a client parses. It used to be emitted as a bare string, and only
	 * because no caller had ever passed one -- the parameter had zero users
	 * until #228. Emitting details[0] as a string would have shipped a shape
	 * no reference response has. */
	if (details && details_count > 0) {
		int i;

		irc = startJsonArrayKey(builder, "details");
		if (irc < 0) {
			goto quit;
		}

		for (i = 0; i < details_count; i++) {
			irc = addJsonArrayString(builder, details[i]);
			if (irc < 0) {
				goto quit;
			}
		}

		irc = endArray(builder);
		if (irc < 0) {
			goto quit;
		}
	}

	irc = endJsonObject(builder);
	if (irc < 0) {
		goto quit;
	}

	irc = sendJSONResponse(session, status, builder);

quit:
	if (builder) {
		freeJsonBuilder(builder);
	}

	return irc;
}

int
send_not_modified(Session *session, const char *etag)
{
	int rc;

	session->headers_sent = 1;
	if ((rc = http_resp(session->httpc,
			HTTP_STATUS_NOT_MODIFIED)) < 0) return rc;
	if ((rc = send_common_headers(session)) < 0) return rc;
	if ((rc = http_printf(session->httpc, "ETag: %s\r\n", etag)) < 0) return rc;
	if ((rc = http_printf(session->httpc, "\r\n")) < 0) return rc;

	return rc;
}

/* The z/OSMF error report for an authorization refusal (issue #228).
 *
 * The shape is measured, not designed -- see CATEGORY_AUTHORIZATION in
 * common.h. The one field mvsMF already had right is the status: 500 is what
 * the reference answers, because the reference takes the same S913 OPEN abend
 * and says so in its own details[] text.
 *
 * `detail` is the caller's, because the two producers of this body cannot claim
 * the same thing. The reference always reaches the abend; a pre-check that
 * refuses before the fopen() has not abended, and must not say it did.
 */
__asm__("\n&FUNC    SETC 'send_not_authorized'");
int
send_not_authorized(Session *session, const char *detail)
{
	const char *details[1];

	details[0] = detail ? detail : ERR_MSG_DENIED_DETAIL;

	return sendErrorResponse(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
			CATEGORY_AUTHORIZATION, RC_ERROR, REASON_NOT_AUTHORIZED,
			ERR_MSG_NOT_AUTHORIZED, details, 1);
}

//
// Send a whole buffer to the client (issue #298).
//
// Every raw send in mvsMF goes through here. The loop itself is in
// src/sendall.c so the host test can drive the real one; what stays here are
// the four services it needs, bound to this session. See include/sendall.h.
//
// Returns 0 when everything was sent, -1 otherwise.
//

__asm__("\n&FUNC    SETC 'send_op_send'");
static int
send_op_send(void *ctx, const unsigned char *buf, int len)
{
	Session *session = (Session *)ctx;

	return http_send(session->httpc, (const UCHAR *)buf, len);
}

__asm__("\n&FUNC    SETC 'send_op_pause'");
static void
send_op_pause(void *ctx)
{
	unsigned ecb = 0;

	(void)ctx;

	// The ECB is zeroed here, on this frame, every single time. A posted
	// ECB that outlives one wait makes every later wait return at once --
	// the 100% CPU spin this whole file exists to remove, back again and
	// invisible. receive_raw_data() re-zeros for the same reason.
	(void)cthread_timed_wait((void *)&ecb, SEND_STALL_PAUSE, 0);
}

__asm__("\n&FUNC    SETC 'send_op_abort'");
static int
send_op_aborted(void *ctx)
{
	Session *session = (Session *)ctx;
	unsigned char flag;

	// The client is finished or a failed send already marked it dead:
	// nothing more can go out, so do not wait for it.
	if (session->httpc->state >= CSTATE_DONE) {
		return 1;
	}

	// A stopping server must not sit out the stall budget -- shutdown waits
	// for the workers, so every worker wait has to honor quiesce
	// (httpd#122, #205). The macro is a volatile read and this function runs
	// once per poll, so the byte the operator-command thread sets is picked
	// up on the next turn -- never hoisted out of the send loop.
	flag = http_get_flag(session->httpd);
	if (flag & (HTTPD_FLAG_QUIESCE | HTTPD_FLAG_SHUTDOWN)) {
		return 1;
	}

	return 0;
}

__asm__("\n&FUNC    SETC 'send_op_gvup'");
static void
send_op_giveup(void *ctx, int stall)
{
	(void)ctx;

	wtof(MSG_SEND_TIMEOUT, stall);
}

// RENT: read-only, so it may be static. A writable static would S0C4.
static const SEND_OPS send_ops = {
	send_op_send,
	send_op_pause,
	send_op_aborted,
	send_op_giveup
};

__asm__("\n&FUNC    SETC 'send_all'");
int
send_all(Session *session, const UCHAR *buf, int len)
{
	int rc;

	if (!session || !session->httpc) {
		return -1;
	}

	rc = send_bytes(session, &send_ops, (const unsigned char *)buf, len);

	if (rc < 0) {
		// Drop the connection, both halves of it.
		//
		// CSTATE_DONE stops the handler's remaining output --
		// http_printf() and the entry guard in send_bytes() both refuse a
		// client at CSTATE_DONE -- instead of every later call paying its
		// own 10 second budget for a peer that is gone (httpd#203).
		//
		// It does NOT close the socket, though: DONE is the normal
		// completion state, and httpd walks DONE -> REPORT -> RESET, where
		// httprese() keeps the connection open if keepalive is still set.
		// That is fine for a response that finished and wrong for this one
		// -- the body is short of the Content-Length it announced, so the
		// next response on the socket would be appended to a truncated one
		// and the client would read the two as a single corrupt reply.
		// Clearing keepalive sends httprese() down its CSTATE_CLOSE branch.
		// httpd's chunked path clears the same flag for the same reason.
		if (session->httpc->state < CSTATE_DONE) {
			session->httpc->state = CSTATE_DONE;
		}
		session->httpc->keepalive = 0;
	}

	return rc;
}

//
// Read raw data from socket, one byte at a time.
// Works around the MVS 3.8j TCP/IP ring buffer bug that corrupts data
// when a multi-byte recv() spans the internal buffer wrap-around point.
// DO NOT change to multi-byte recv().
//
// The EWOULDBLOCK arm below is not a nicety, it is what makes a slow client
// work at all. httpd puts every accepted socket in non-blocking mode
// (FIONBIO, httpd.c), so a recv() that finds the receive buffer empty
// returns -1/EWOULDBLOCK immediately -- and an empty buffer mid-body means
// "the client has not sent the next byte yet", not "the client is gone".
// mvsMF consumes a text body at roughly 130 KB/s, so ANY client sending
// slower than that drains the buffer within the first second; measured on
// mvsdev, a 240 KB PUT throttled to 100 KB/s ran the buffer dry after
// 0.6 s. A bare recv() there fails a perfectly healthy upload -- and, with
// the target already open for output, replaces the resource with whatever
// arrived first (#247, and the destruction half of #246).
//
// A client sending `Expect: 100-continue` is the same failure at byte zero:
// it holds the body back until an interim response arrives, so the very
// first read finds nothing. Answering that expectation is httpd's job
// (httpd#207) -- but even once it does, the interim response and the
// client's first data segment are a round trip apart, so waiting here is
// still what carries the read across the gap.
//
// 200 retries x 50 ms = 10 s without a single byte before giving up, the
// same budget send_all() spends on a stalled send. Note the shape: retries
// resets on every byte received, so the budget is per stall, not per
// request. A client dribbling one byte every 9 s holds its worker -- and,
// mid-body, an open DCB on the target -- for as long as it keeps dribbling.
// That is the unavoidable price of waiting for slow clients; the guard
// against it is httpd's client timeout, not this loop.
//
// MSG_RECV_TIMEOUT stays even though #247 widened its reach from the four
// read_request_content() callers to every data set PUT. A ten second silence
// mid-request is an operator-visible symptom -- a held worker is precisely
// what #217 taught us to look for -- and it cannot flood the console the way
// a client-caused 404 can, because one stuck request emits at most one WTO
// per 10 s. MSG_SEND_TIMEOUT is the same policy on the send side; having one
// direction report a stall and the other stay silent would be worse than
// either choice made consistently.
//

#define RAW_RECV_MAX_RETRIES 200

__asm__("\n&FUNC    SETC 'recv_raw_data'");
int
receive_raw_data(HTTPC *httpc, char *buf, int len)
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
				if (++retries > RAW_RECV_MAX_RETRIES) {
					wtof(MSG_RECV_TIMEOUT, retries);
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
// The bulk counterpart: one recv() of up to len bytes, retried on
// EWOULDBLOCK against the same budget.
//
// Read granularity is deliberately left alone. The binary record paths in
// dsapi.c have always read up to one LRECL per call, and turning them into
// byte-at-a-time reads would be a throughput change dressed up as a bug fix.
// What they were missing is only the wait -- so that is all this adds. The
// caller already handles a short read; every one of them loops until the
// declared length is in.
//

__asm__("\n&FUNC    SETC 'recv_raw_some'");
int
receive_raw_some(HTTPC *httpc, char *buf, int len)
{
	int n = 0;
	int retries = 0;
	unsigned ecb = 0;
	int sockfd = httpc->socket;

	while (1) {
		n = recv(sockfd, buf, len, 0);
		if (n >= 0) {
			return n;
		}
		if (errno == EINTR) continue;
		if (errno != EWOULDBLOCK) {
			return -1;
		}
		if (++retries > RAW_RECV_MAX_RETRIES) {
			wtof(MSG_RECV_TIMEOUT, retries);
			return -1;
		}
		// Zeroed on this frame every time -- an ECB that outlives one
		// wait returns instantly from every later one, which is the busy
		// spin this wait exists to avoid. Same reason as send_op_pause().
		ecb = 0;
		cthread_timed_wait((void *)&ecb, 5, 0);
	}
}

//
// Read the full request body into a malloc'd buffer.
// Supports both Content-Length and Transfer-Encoding: chunked.
// Caller must free the returned buffer via free().
// Returns 0 on success, -1 on error.
//

int
read_request_content(Session *session, char **content, size_t *content_size)
{
	size_t buffer_size = 0;
	int bytes_received = 0;
	int has_content_length = 0;
	size_t content_length = 0;
	int is_chunked = 0;
	int done = 0;

	// Check Content-Length header
	const char *cl_str = getHeaderParam(session, "Content-Length");
	if (cl_str != NULL) {
		has_content_length = 1;
		content_length = strtoul(cl_str, NULL, 10);
	}

	// Check Transfer-Encoding header
	const char *te = getHeaderParam(session, "Transfer-Encoding");
	if (te != NULL && strstr(te, "chunked") != NULL) {
		is_chunked = 1;
	}

	if (!is_chunked && !has_content_length) {
		return -1;
	}

	// Allocate initial buffer
	*content = malloc(INITIAL_BUFFER_SIZE);
	if (!*content) {
		wtof(MSG_STORAGE_FAILED, ALLOC_REQUEST_BODY);
		return -1;
	}
	buffer_size = INITIAL_BUFFER_SIZE;
	*content_size = 0;

	if (is_chunked) {
		while (!done) {
			char chunk_size_str[10];
			int i = 0;

			// Read chunk size line (hex + CRLF)
			while (i < (int)sizeof(chunk_size_str) - 1) {
				if (receive_raw_data(session->httpc,
						chunk_size_str + i, 1) != 1) {
					free(*content);
					*content = NULL;
					return -1;
				}
				if (chunk_size_str[i] == '\r') {
					chunk_size_str[i] = '\0';
					receive_raw_data(session->httpc,
						chunk_size_str + i, 1);
					break;
				}
				i++;
			}

			http_atoe((unsigned char *)chunk_size_str, i);
			{
				int chunk_size = (int)strtoul(chunk_size_str, NULL, 16);
				int bytes_read = 0;

				if (chunk_size == 0) {
					// Drain the terminating CRLF of the chunked body (RFC 7230 4.1).
					// Leaving it unread keeps 2 bytes in the socket; closing the
					// connection with unread inbound data triggers a TCP RST that
					// strict HTTP clients (Zowe/Node) report as ECONNRESET /
					// "socket hang up". Best-effort: the body is already complete
					// here, so do not fail on a short read. Trailers are not
					// expected (Zowe sends none); mirrors dsapi.c.
					char crlf[2];
					(void)receive_raw_data(session->httpc, crlf, 2);
					done = 1;
					break;
				}

				// Ensure buffer capacity
				if (*content_size + chunk_size > buffer_size) {
					char *new_buf = realloc(*content,
						*content_size + chunk_size + 1);
					if (!new_buf) {
						wtof(MSG_STORAGE_FAILED, ALLOC_REQUEST_BODY);
						free(*content);
						*content = NULL;
						return -1;
					}
					*content = new_buf;
					buffer_size = *content_size + chunk_size;
				}

				// Read chunk data
				while (bytes_read < chunk_size) {
					bytes_received = receive_raw_data(session->httpc,
						*content + *content_size + bytes_read,
						chunk_size - bytes_read);
					if (bytes_received <= 0) {
						free(*content);
						*content = NULL;
						return -1;
					}
					bytes_read += bytes_received;
				}

				*content_size += chunk_size;
			}

			// Consume trailing CRLF after chunk data
			{
				char crlf[2];
				if (receive_raw_data(session->httpc, crlf, 2) != 2) {
					free(*content);
					*content = NULL;
					return -1;
				}
			}
		}
	} else {
		char recv_buffer[1024];
		while (*content_size < content_length) {
			size_t remaining = content_length - *content_size;
			size_t to_read = remaining < sizeof(recv_buffer)
				? remaining : sizeof(recv_buffer);

			if (*content_size + sizeof(recv_buffer) > buffer_size) {
				char *new_buf = realloc(*content, buffer_size * 2);
				if (!new_buf) {
					wtof(MSG_STORAGE_FAILED, ALLOC_REQUEST_BODY);
					free(*content);
					*content = NULL;
					return -1;
				}
				*content = new_buf;
				buffer_size *= 2;
			}

			bytes_received = receive_raw_data(session->httpc,
				*content + *content_size, (int)to_read);
			if (bytes_received <= 0) {
				free(*content);
				*content = NULL;
				return -1;
			}

			*content_size += bytes_received;
		}
	}

	// Ensure null termination
	if (*content_size + 1 > buffer_size) {
		char *new_buf = realloc(*content, *content_size + 1);
		if (!new_buf) {
			wtof(MSG_STORAGE_FAILED, ALLOC_REQUEST_BODY);
			free(*content);
			*content = NULL;
			return -1;
		}
		*content = new_buf;
	}
	(*content)[*content_size] = '\0';

	return 0;
}

//
// private functions
//

/**
 * Extracts a parameter from environment variables
 *
 * @param session Current session context
 * @param prefix Prefix for the environment variable name (e.g. "HTTP_" or "QUERY_")
 * @param name Name of the parameter
 * @return Value of the parameter or NULL if not found
 */
__asm__("\n&FUNC    SETC 'get_env_param'");
static char *
get_env_param(Session *session, const char *prefix, const char *name)
{
	char env_name[ENV_NAME_SIZE];

	if (!session || !prefix || !name) {
		return NULL;
	}

	(void)snprintf(env_name, sizeof(env_name), "%s%s", prefix, name);
	return (char *)http_get_env(session->httpc, (const UCHAR *)env_name);
}

/**
 * Sends data to the client
 *
 * @param session Current session context
 * @param buf Buffer containing the data to send
 * @return 0 on success, negative value on error
 */
__asm__("\n&FUNC	SETC 'send_data'");
static int 
send_data(Session *session, char *buf) 
{
	size_t len = strlen(buf);

	http_etoa((unsigned char *)buf, len);

	/* sendJSONResponse() sets Content-Length before this, so the response is
	   NOT chunked -- which is precisely the mode where http_send() reports 0
	   for a full send buffer. Every JSON response mvsMF produces lands here,
	   so this is the normal path, not an edge case (issue #298). */
	return send_all(session, (const UCHAR *)buf, (int)len);
}
