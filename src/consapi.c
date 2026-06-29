#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <clibwto.h>
#include <clibgrt.h>
#include <clibmtt.h>
#include <clibary.h>

#include "consapi.h"
#include "common.h"
#include "json.h"
#include "httpcgi.h"

/*
 * z/OSMF Console services -- Issue command (endpoint 1).
 * See doc/endpoints/restconsoles-issue-command.md.
 *
 * NOTE: MVSMF is link-edited RENT (read-only static storage) -- this module
 * keeps NO writable static/global data; all state is on the stack or heap.
 */

#define CMD_MAX        126        /* z/OSMF command length limit              */
#define RESP_CAP       32768      /* cap on captured cmd-response bytes        */
#define POLL_SECONDS   3          /* sync capture window (~ TOD high-word ticks)*/

/* Column layout of a formatted MTT line (see /zosmf/test?fn=mtt output):
 *   "0000  9.24.38 STC  320  IEE136I ..."
 *    flags^   time^    jobtype+num^    message^
 * Offsets are first-cut and tuned against live data.                         */
#define MTT_SRC_OFF    15         /* jobtype+number field ("STC  320")        */
#define MTT_SRC_LEN    8
#define MTT_MSG_OFF    24         /* message text start                       */

/* ------------------------------------------------------------------ */
/* small helpers                                                       */
/* ------------------------------------------------------------------ */

/* TOD clock high word -- LSB ~= 1.05 s, good enough for a ~3 s window. */
__asm__("\n&FUNC	SETC 'tod_hi'");
static unsigned tod_hi(void)
{
	unsigned char clk[8];
	__asm__ volatile("STCK %0" : "=m"(clk) : : "cc");
	return *(unsigned *)clk;
}

/* Minimal JSON string-field extractor (body is already EBCDIC).
 * Returns 0 and copies the value on success, -1 if not found / not a string. */
__asm__("\n&FUNC	SETC 'json_get_str'");
static int json_get_str(const char *body, const char *key, char *out, size_t outsz)
{
	char pat[40];
	const char *p, *v, *e;
	size_t klen = strlen(key);
	size_t vlen;

	if (klen + 3 > sizeof(pat)) return -1;
	pat[0] = '"';
	memcpy(pat + 1, key, klen);
	pat[klen + 1] = '"';
	pat[klen + 2] = '\0';

	p = strstr(body, pat);
	if (!p) return -1;
	p += klen + 2;

	while (*p && *p != ':') p++;
	if (*p != ':') return -1;
	p++;
	while (*p == ' ' || *p == '\t') p++;
	if (*p != '"') return -1;            /* only string values supported    */

	v = p + 1;
	e = v;
	while (*e && *e != '"') e++;          /* no escape handling (MVP)        */
	if (*e != '"') return -1;

	vlen = (size_t)(e - v);
	if (vlen >= outsz) vlen = outsz - 1;
	memcpy(out, v, vlen);
	out[vlen] = '\0';
	return 0;
}

/* Issue an operator command via SVC 34 (MGCR), under the caller's ACEE. */
__asm__("\n&FUNC	SETC 'issue_command'");
static void issue_command(const char *cmd, unsigned cmdlen)
{
	unsigned char cmdbuf[128];
	unsigned char *cmdp = cmdbuf;

	if (cmdlen > 100) cmdlen = 100;

	memset(cmdbuf, 0, sizeof(cmdbuf));
	cmdbuf[1] = 104;                     /* IEECDCM dcminlgn                 */
	memset(&cmdbuf[4], ' ', 124);        /* EBCDIC blanks                    */
	memcpy(&cmdbuf[4], cmd, cmdlen);

	__asm__("MODESET MODE=SUP,KEY=ZERO");
	__asm__ volatile("  L   1,%0\n"
	                 "  SLR 0,0\n"
	                 "  SVC 34"
	                 :
	                 : "m"(cmdp)
	                 : "0", "1", "14", "15");
	__asm__("MODESET MODE=PROB,KEY=NZERO");
}

/* Trim trailing blanks; return logical length. */
__asm__("\n&FUNC	SETC 'rstrip_len'");
static int rstrip_len(const char *s, int len)
{
	while (len > 0 && s[len - 1] == ' ') len--;
	return len;
}

/* Last whitespace-delimited token, if it is all digits -> the MLWTO number.
 * Copies it into num (NUL-terminated) and returns its length, else 0.        */
__asm__("\n&FUNC	SETC 'mlwto_num'");
static int mlwto_num(const char *line, int len, char *num, size_t numsz)
{
	int end, start, i;

	len = rstrip_len(line, len);
	end = len;
	while (end > 0 && line[end - 1] == ' ') end--;
	start = end;
	while (start > 0 && line[start - 1] != ' ') start--;
	if (end <= start || (size_t)(end - start) >= numsz) return 0;
	for (i = start; i < end; i++)
		if (line[i] < '0' || line[i] > '9') return 0;
	memcpy(num, &line[start], end - start);
	num[end - start] = '\0';
	return end - start;
}

/* ------------------------------------------------------------------ */
/* console-style error response: { return-code, reason-code, reason } */
/* ------------------------------------------------------------------ */
__asm__("\n&FUNC	SETC 'send_console_error'");
static int send_console_error(Session *session, int http, int retcode,
                              int reason_code, const char *reason)
{
	int rc = 0;
	JsonBuilder *b = createJsonBuilder();
	if (!b) {
		sendDefaultHeaders(session, http, HTTP_CONTENT_TYPE_NONE, 0);
		return -1;
	}
	if (startJsonObject(b) < 0 ||
	    addJsonNumber(b, "return-code", retcode) < 0 ||
	    addJsonNumber(b, "reason-code", reason_code) < 0 ||
	    addJsonString(b, "reason", reason) < 0 ||
	    endJsonObject(b) < 0) {
		rc = -1;
		goto quit;
	}
	rc = sendJSONResponse(session, http, b);
quit:
	freeJsonBuilder(b);
	return rc;
}

/* ------------------------------------------------------------------ */
/* capture: poll the MTT for up to ~3 s, correlate the response to the */
/* command we just issued, accumulate the message lines into *out.     */
/* Returns the number of response lines captured.                      */
/* ------------------------------------------------------------------ */
/* session is required because array_count() routes through the httpd httpx
 * vector (httpcgi.h macro), which dereferences session->httpd. */
__asm__("\n&FUNC	SETC 'capture_response'");
static int capture_response(Session *session, const char *cmd_upper, char *out,
                            size_t outsz, int wait_full)
{
	unsigned start = tod_hi();
	int captured = 0;
	int stable = 0;
	size_t prev_used = 0;

	for (;;) {
		CMTT *cmtt = cmtt_new();
		MTENTRY **arr = cmtt ? cmtt_get_array(cmtt) : NULL;
		unsigned n = arr ? array_count(&arr) : 0;
		int ei = -1;
		unsigned i;
		char src[MTT_SRC_LEN + 1];
		char num[12];
		size_t used = 0;
		int have_num = 0;

		/* find OUR echo: newest entry whose text contains the command */
		for (i = n; i > 0; i--) {
			MTENTRY *e = arr[i - 1];
			char tmp[160];
			int len = e ? (int)e->mtentlen : 0;
			if (!e) continue;
			if (len > (int)sizeof(tmp) - 1) len = sizeof(tmp) - 1;
			memcpy(tmp, e->mtentdat, len);
			tmp[len] = '\0';
			if (strstr(tmp, cmd_upper)) { ei = (int)(i - 1); break; }
		}

		if (ei >= 0) {
			/* echo's source token (jobtype+number) */
			MTENTRY *ee = arr[ei];
			int elen = (int)ee->mtentlen;
			memset(src, ' ', MTT_SRC_LEN);
			if (elen >= MTT_SRC_OFF + MTT_SRC_LEN)
				memcpy(src, &ee->mtentdat[MTT_SRC_OFF], MTT_SRC_LEN);
			src[MTT_SRC_LEN] = '\0';

			/* collect the response block following the echo */
			used = 0;
			for (i = (unsigned)ei + 1; i < n; i++) {
				MTENTRY *e = arr[i];
				int len = e ? (int)e->mtentlen : 0;
				const char *dat = e ? e->mtentdat : "";
				const char *msg;
				int msglen, k;
				int has_src, blank_src, cont;

				if (!e) continue;

				/* classify the line relative to our command's block */
				has_src = (len >= MTT_SRC_OFF + MTT_SRC_LEN &&
				           memcmp(&dat[MTT_SRC_OFF], src, MTT_SRC_LEN) == 0);

				blank_src = (len >= MTT_SRC_OFF + MTT_SRC_LEN);
				for (k = MTT_SRC_OFF; blank_src && k < MTT_SRC_OFF + MTT_SRC_LEN; k++)
					if (dat[k] != ' ') blank_src = 0;

				cont = 0;
				if (have_num) {
					k = 0;
					while (k < len && dat[k] == ' ') k++;
					if (len - k >= (int)strlen(num) &&
					    memcmp(&dat[k], num, strlen(num)) == 0)
						cont = 1;
				}

				/* a different, attributed originator ends our block */
				if (!has_src && !blank_src && !cont) {
					if (used > 0) break;
					else continue;
				}

				if (cont && !has_src && !blank_src) {
					/* raw MLWTO continuation: drop leading blanks + number */
					k = 0;
					while (k < len && dat[k] == ' ') k++;
					k += (int)strlen(num);
					while (k < len && dat[k] == ' ') k++;
					msg = &dat[k];
					msglen = rstrip_len(msg, len - k);
				} else {
					/* prefixed line (echo originator or blank-src MLWTO
					 * header): take the message after the fixed prefix */
					if (len <= MTT_MSG_OFF) continue;
					msg = &dat[MTT_MSG_OFF];
					msglen = rstrip_len(msg, len - MTT_MSG_OFF);
					/* a trailing number marks an MLWTO; its continuations
					 * follow, prefixed with that number */
					if (mlwto_num(msg, msglen, num, sizeof(num)))
						have_num = 1;
				}

				if (msglen > 0 && used + (size_t)msglen + 1 < outsz) {
					memcpy(&out[used], msg, msglen);
					used += msglen;
					out[used++] = '\r';
					captured++;
				}
			}
		}

		if (cmtt) cmtt_free(&cmtt);

		out[used < outsz ? used : outsz - 1] = '\0';

		/* completion heuristic: stop early once the block stops growing
		 * (unless the caller wants the full window) */
		if (!wait_full && used > 0) {
			if (used == prev_used) {
				if (++stable >= 3) break;
			} else {
				stable = 0;
			}
		}
		prev_used = used;

		if (tod_hi() - start >= (unsigned)POLL_SECONDS) break;
	}

	return captured;
}

/* ------------------------------------------------------------------ */
/* PUT /zosmf/restconsoles/consoles/{console-name}                     */
/* ------------------------------------------------------------------ */
int consoleIssueHandler(Session *session)
{
	int rc = 0;
	char *body = NULL;
	size_t body_len = 0;
	char *resp = NULL;
	JsonBuilder *b = NULL;

	char cmd[CMD_MAX + 2] = {0};
	char cmd_upper[CMD_MAX + 2] = {0};
	char async[4] = {0};
	char solkey[64] = {0};
	char solreg[4] = {0};
	char system[16] = {0};
	char key[24];
	char url[256];
	char uri[160];

	const char *cn = getPathParam(session, "console-name");
	const char *ct = getHeaderParam(session, "Content-Type");
	const char *host = getHeaderParam(session, "Host");
	int cmdlen, cnlen, i, is_async, sol_detected = 0;

	/* Content-Type must be application/json */
	if (!ct || !strstr(ct, "application/json")) {
		send_console_error(session, HTTP_STATUS_BAD_REQUEST, 1, 6,
		    "The Content-Type cannot be handled, 'application/json' is expected.");
		return -1;
	}

	/* console name: 2-8 chars */
	cnlen = cn ? (int)strlen(cn) : 0;
	if (cnlen < 2 || cnlen > 8) {
		send_console_error(session, HTTP_STATUS_BAD_REQUEST, 1, 14,
		    "Incorrect console name. The length must be greater than 1 and less than 9.");
		return -1;
	}

	/* read + EBCDIC-convert the JSON body */
	if (read_request_content(session, &body, &body_len) < 0 || !body) {
		send_console_error(session, HTTP_STATUS_BAD_REQUEST, 1, 12,
		    "The body of the request is not in JSON format.");
		return -1;
	}
	http_atoe((unsigned char *)body, body_len);
	body[body_len] = '\0';

	/* cmd (required) */
	if (json_get_str(body, "cmd", cmd, sizeof(cmd)) != 0 || cmd[0] == '\0') {
		send_console_error(session, HTTP_STATUS_BAD_REQUEST, 1, 13,
		    "Cannot find 'cmd' in request body, or value of 'cmd' is empty.");
		rc = -1;
		goto quit;
	}
	cmdlen = (int)strlen(cmd);
	if (cmdlen > CMD_MAX) {
		send_console_error(session, HTTP_STATUS_BAD_REQUEST, 1, 17,
		    "Command length must be less than 127.");
		rc = -1;
		goto quit;
	}

	/* optional fields */
	json_get_str(body, "async", async, sizeof(async));
	json_get_str(body, "system", system, sizeof(system));
	json_get_str(body, "sol-key", solkey, sizeof(solkey));
	json_get_str(body, "solKeyReg", solreg, sizeof(solreg));

	if (solreg[0] == 'Y' && solkey[0]) {
		send_console_error(session, HTTP_STATUS_BAD_REQUEST, 1, 25,
		    "Invalid value for sol-key: regular expressions are not supported.");
		rc = -1;
		goto quit;
	}

	/* system routing: only the local system is supported (TODO: CVTSNAME) */
	if (system[0]) {
		send_console_error(session, HTTP_STATUS_BAD_REQUEST, 1, 5,
		    "Routing to another system is not supported.");
		rc = -1;
		goto quit;
	}

	is_async = (async[0] == 'Y' || async[0] == 'y');

	/* uppercase the command (operator echo is uppercase) */
	for (i = 0; i < cmdlen; i++)
		cmd_upper[i] = (char)toupper((unsigned char)cmd[i]);
	cmd_upper[cmdlen] = '\0';

	/* issue under the authenticated user's ACEE (set by authmw) */
	issue_command(cmd_upper, (unsigned)cmdlen);

	/* TODO(endpoint 2): self-describing key = jobid + MLWTO# + TOD anchor.
	 * For now a TOD-derived token; collect is not wired yet.            */
	snprintf(key, sizeof(key), "C%08X", tod_hi());
	snprintf(uri, sizeof(uri),
	         "/zosmf/restconsoles/consoles/%s/solmsgs/%s", cn, key);
	snprintf(url, sizeof(url), "http://%s%s", host ? host : "localhost", uri);

	resp = malloc(RESP_CAP);
	if (!resp) {
		send_console_error(session, HTTP_STATUS_INTERNAL_SERVER_ERROR, 8, 14,
		    "Cannot get the command response.");
		rc = -1;
		goto quit;
	}
	resp[0] = '\0';

	if (!is_async) {
		capture_response(session, cmd_upper, resp, RESP_CAP, 0);
		if (solkey[0] && strstr(resp, solkey)) sol_detected = 1;
	}

	/* build the response */
	b = createJsonBuilder();
	if (!b) { rc = -1; goto quit; }

	if (startJsonObject(b) < 0) { rc = -1; goto quit; }
	if (!is_async) {
		if (addJsonStringEsc(b, "cmd-response", resp) < 0) { rc = -1; goto quit; }
	}
	if (addJsonString(b, "cmd-response-key", key) < 0 ||
	    addJsonString(b, "cmd-response-url", url) < 0 ||
	    addJsonString(b, "cmd-response-uri", uri) < 0) {
		rc = -1; goto quit;
	}
	if (!is_async && solkey[0]) {
		if (addJsonBool(b, "sol-key-detected", sol_detected) < 0) {
			rc = -1; goto quit;
		}
	}
	if (endJsonObject(b) < 0) { rc = -1; goto quit; }

	rc = sendJSONResponse(session, HTTP_STATUS_OK, b);

quit:
	if (b) freeJsonBuilder(b);
	if (resp) free(resp);
	if (body) free(body);
	return rc;
}
