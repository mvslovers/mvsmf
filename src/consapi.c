#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <time.h>
#include <clibwto.h>
#include <clibgrt.h>
#include <clibmtt.h>
#include <clibary.h>
#include <clibsmf.h>
#include <mvssupa.h>

#include "consapi.h"
#include "common.h"
#include "json.h"
#include "httpcgi.h"
#include "ntstore.h"
#include "mvsmfctx.h"

/*
 * z/OSMF Console services -- Issue command (endpoint 1).
 * See docs/endpoints/console/ (issue-command, collect, detections, hardcopy-log).
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
#define MTT_SRC_OFF    14         /* jobtype+number field ("STC  320")        */
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

/* Per-key cursor, stored opaquely in the kv-store value (the store never reads
 * it).  The cursor is a delivered-LINE COUNT, not a timestamp: the MTT has no
 * stable per-line sequence and its hh.mm.ss is second-granular. */
typedef struct sol_cursor {
	unsigned long long  issue_tod;   /* STCK at issue (reserved: re-issue disamb.) */
	unsigned            delivered;   /* # response lines already delivered         */
	unsigned char       cmdlen;
	char                cmd[126];    /* uppercased command, for MTT re-correlation  */
} SOL_CURSOR;

static unsigned long long tod64(void)
{
	unsigned long long t = 0;
	__getclk(&t);
	return t;
}

/* Copy an opaque response key into a fixed 16-byte store name (zero-padded). */
static void key_to_name(const char *key, char name[MVSMF_KVS_NAMELEN])
{
	int i;
	memset(name, 0, MVSMF_KVS_NAMELEN);
	if (!key) return;
	for (i = 0; i < MVSMF_KVS_NAMELEN && key[i]; i++)
		name[i] = key[i];
}

/* ------------------------------------------------------------------ */
/* correlate ONE MTT snapshot: find the command's echo, walk its       */
/* response block, append the lines with block-index >= skip to out,   */
/* and set *total to the block's total line count. Returns the number  */
/* of lines appended.  (session: array_count() routes through the      */
/* httpd httpx vector, which needs session->httpd.)                    */
/* ------------------------------------------------------------------ */
__asm__("\n&FUNC	SETC 'correlate_once'");
static int correlate_once(Session *session, const char *cmd_upper, char *out,
                          size_t outsz, unsigned skip, unsigned *total)
{
	CMTT *cmtt = cmtt_new();
	MTENTRY **arr = cmtt ? cmtt_get_array(cmtt) : NULL;
	unsigned n = arr ? array_count(&arr) : 0;
	int ei = -1;
	unsigned i, line_idx = 0;
	int appended = 0;
	size_t used = 0;
	char src[MTT_SRC_LEN + 1];
	char num[12];
	int have_num = 0;

	out[0] = '\0';

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
		MTENTRY *ee = arr[ei];
		int elen = (int)ee->mtentlen;
		memset(src, ' ', MTT_SRC_LEN);
		if (elen >= MTT_SRC_OFF + MTT_SRC_LEN)
			memcpy(src, &ee->mtentdat[MTT_SRC_OFF], MTT_SRC_LEN);
		src[MTT_SRC_LEN] = '\0';

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
				if (line_idx > 0) break;
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
				/* prefixed line (echo originator or blank-src MLWTO header):
				 * take the message after the fixed prefix */
				if (len <= MTT_MSG_OFF) continue;
				msg = &dat[MTT_MSG_OFF];
				msglen = rstrip_len(msg, len - MTT_MSG_OFF);
				if (mlwto_num(msg, msglen, num, sizeof(num)))
					have_num = 1;
			}

			/* block line #line_idx: emit only the new tail [skip..) */
			if (line_idx >= skip && msglen > 0 &&
			    used + (size_t)msglen + 1 < outsz) {
				memcpy(&out[used], msg, msglen);
				used += msglen;
				out[used++] = '\r';
				appended++;
			}
			line_idx++;
		}
	}

	out[used < outsz ? used : outsz - 1] = '\0';
	if (total) *total = line_idx;
	if (cmtt) cmtt_free(&cmtt);
	return appended;
}

/* Issue-time sync capture: poll up to ~3 s and return the whole response block
 * in out; the return value is the number of lines it contains. */
__asm__("\n&FUNC	SETC 'capture_response'");
static int capture_response(Session *session, const char *cmd_upper, char *out,
                            size_t outsz)
{
	unsigned start = tod_hi();
	int stable = 0;
	unsigned prev_total = 0;
	unsigned total = 0;

	for (;;) {
		correlate_once(session, cmd_upper, out, outsz, 0, &total);
		if (total > 0) {
			if (total == prev_total) {
				if (++stable >= 3) break;
			} else {
				stable = 0;
			}
		}
		prev_total = total;
		if (tod_hi() - start >= (unsigned)POLL_SECONDS) break;
	}

	return (int)total;
}

/* Unsolicited-keyword detection request, stored opaquely in the kv-store keyed
 * by the "D..." detection key. Detection fires when the number of MTT entries
 * matching the keyword grows past base_count (robust against pre-existing
 * occurrences; no per-entry timestamp comparison needed). anchor_hi is the TOD
 * high word at issue (each tick ~= 1.05 s) -> 64-bit-math-free window check. */
typedef struct sol_detection {
	unsigned        anchor_hi;    /* tod_hi() at issue (~1.05 s ticks)    */
	unsigned        detect_secs;  /* detect-time window (seconds)         */
	unsigned        base_count;   /* matches present at issue             */
	unsigned char   keylen;
	char            key[126];     /* uppercased unsol-key                 */
} SOL_DETECTION;

/* Count MTT entries whose (uppercased) text contains keyword_upper; record the
 * newest matching line into latest (rstripped, NUL-terminated). */
__asm__("\n&FUNC	SETC 'detect_count'");
static int detect_count(Session *session, const char *keyword_upper,
                        char *latest, size_t lsz)
{
	CMTT *cmtt = cmtt_new();
	MTENTRY **arr = cmtt ? cmtt_get_array(cmtt) : NULL;
	unsigned n = arr ? array_count(&arr) : 0;
	unsigned i;
	int count = 0;

	if (latest && lsz) latest[0] = '\0';

	for (i = 0; i < n; i++) {
		MTENTRY *e = arr[i];
		char up[200];
		int len = e ? (int)e->mtentlen : 0;
		int k;
		if (!e) continue;
		if (len > (int)sizeof(up) - 1) len = sizeof(up) - 1;
		for (k = 0; k < len; k++)
			up[k] = (char)toupper((unsigned char)e->mtentdat[k]);
		up[len] = '\0';
		if (strstr(up, keyword_upper)) {
			count++;
			if (latest && lsz) {
				/* return just the message text, not the raw MTT line:
				 * skip the flags+time+jobtype/num prefix (cols 0..23)
				 * and any leading blanks, then rstrip. */
				int off = (len > MTT_MSG_OFF) ? MTT_MSG_OFF : 0;
				int mlen;
				while (off < len && e->mtentdat[off] == ' ') off++;
				mlen = rstrip_len(e->mtentdat + off, len - off);
				if (mlen > (int)lsz - 1) mlen = (int)lsz - 1;
				memcpy(latest, e->mtentdat + off, mlen);
				latest[mlen] = '\0';
			}
		}
	}

	if (cmtt) cmtt_free(&cmtt);
	return count;
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
	char key[17];
	char name[MVSMF_KVS_NAMELEN];
	char url[256];
	char uri[160];

	const char *cn = getPathParam(session, "console-name");
	const char *ct = getHeaderParam(session, "Content-Type");
	const char *host = getHeaderParam(session, "Host");
	int cmdlen, cnlen, i, is_async, sol_detected = 0;
	unsigned delivered = 0;
	unsigned long long issue_tod;

	/* unsolicited-message detection (endpoint 3) */
	char unsolkey[64] = {0};
	char unsolreg[4] = {0};
	char unsoldsync[4] = {0};
	char detecttime[8] = {0};
	char unsoltimeout[8] = {0};
	char unsol_upper[66] = {0};
	char dkey[16] = {0};
	char det_status[16] = {0};
	char det_msg[200] = {0};
	int has_unsol = 0, unsol_sync = 0, unsol_base = 0, detect_secs = 30;

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

	/* unsolicited-keyword detection fields */
	json_get_str(body, "unsol-key", unsolkey, sizeof(unsolkey));
	json_get_str(body, "unsolKeyReg", unsolreg, sizeof(unsolreg));
	json_get_str(body, "unsol-detect-sync", unsoldsync, sizeof(unsoldsync));
	json_get_str(body, "detect-time", detecttime, sizeof(detecttime));
	json_get_str(body, "unsol-detect-timeout", unsoltimeout, sizeof(unsoltimeout));

	if (unsolreg[0] == 'Y' && unsolkey[0]) {
		send_console_error(session, HTTP_STATUS_BAD_REQUEST, 1, 25,
		    "Invalid value for unsol-key: regular expressions are not supported.");
		rc = -1;
		goto quit;
	}
	has_unsol  = (unsolkey[0] != '\0');
	unsol_sync = (unsoldsync[0] == 'Y' || unsoldsync[0] == 'y');
	if (detecttime[0]) detect_secs = atoi(detecttime);
	if (detect_secs <= 0) detect_secs = 30;

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

	/* issue under the authenticated user's ACEE (set by the identity middleware) */
	issue_command(cmd_upper, (unsigned)cmdlen);

	/* unsol-key: uppercase it and snapshot the baseline match count *before*
	 * the awaited (unsolicited) message can arrive */
	if (has_unsol) {
		int j;
		for (j = 0; unsolkey[j] && j < (int)sizeof(unsol_upper) - 1; j++)
			unsol_upper[j] = (char)toupper((unsigned char)unsolkey[j]);
		unsol_upper[j] = '\0';
		unsol_base = detect_count(session, unsol_upper, (char *)0, 0);
	}

	/* opaque 16-byte response key (a unique handle; the correlation context
	 * lives in the stored cursor, not in the key) */
	issue_tod = tod64();
	snprintf(key, sizeof(key), "%08X%08X",
	         (unsigned)(issue_tod >> 32), (unsigned)issue_tod);
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
		delivered = (unsigned)capture_response(session, cmd_upper, resp, RESP_CAP);
		if (solkey[0] && strstr(resp, solkey)) sol_detected = 1;
	}

	/* persist the cursor so collect can return only the new lines later */
	{
		NT_STORE *store = mvsmf_kvstore(session->httpd);
		if (store) {
			SOL_CURSOR cur;
			memset(&cur, 0, sizeof(cur));
			cur.issue_tod = issue_tod;
			cur.delivered = delivered;
			cur.cmdlen    = (unsigned char)cmdlen;
			strncpy(cur.cmd, cmd_upper, sizeof(cur.cmd) - 1);
			key_to_name(key, name);
			nt_set(store, name, &cur, sizeof(cur));
		}
	}

	/* unsolicited-keyword detection */
	if (has_unsol && unsol_sync) {
		/* block up to unsol-detect-timeout, polling the MTT for a new match.
		 * NOTE: a tight poll (each detect_count re-snapshots the MTT); the
		 * async path is preferred for long waits. */
		unsigned to = unsoltimeout[0] ? (unsigned)atoi(unsoltimeout) : 20;
		unsigned start = tod_hi();
		if (to == 0 || to > 60) to = 20;            /* sane bound */
		strcpy(det_status, "timeout");
		for (;;) {
			if (detect_count(session, unsol_upper, det_msg, sizeof(det_msg))
			    > unsol_base) {
				strcpy(det_status, "detected");
				break;
			}
			if (tod_hi() - start >= to) break;
		}
		if (strcmp(det_status, "detected") != 0) det_msg[0] = '\0';
	} else if (has_unsol) {
		/* async: store the detection request; client polls /detections/{key} */
		NT_STORE *store = mvsmf_kvstore(session->httpd);
		/* derive the handle from the STCK (issue_tod), not tod_hi(): tod_hi()
		 * only advances ~1.05 s, so two detections issued in the same second
		 * would collide on the same key (and overwrite each other in the
		 * store). issue_tod is microsecond-unique, like the cmd-response key. */
		snprintf(dkey, sizeof(dkey), "D%07X",
		         (unsigned)((issue_tod >> 12) & 0xFFFFFFF));
		if (store) {
			SOL_DETECTION det;
			char dname[MVSMF_KVS_NAMELEN];
			memset(&det, 0, sizeof(det));
			det.anchor_hi   = tod_hi();
			det.detect_secs = (unsigned)detect_secs;
			det.base_count  = (unsigned)unsol_base;
			det.keylen      = (unsigned char)strlen(unsol_upper);
			strncpy(det.key, unsol_upper, sizeof(det.key) - 1);
			key_to_name(dkey, dname);
			nt_set(store, dname, &det, sizeof(det));
		}
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
	if (has_unsol && unsol_sync) {
		if (addJsonString(b, "status", det_status) < 0 ||
		    addJsonStringEsc(b, "msg", det_msg) < 0) {
			rc = -1; goto quit;
		}
	} else if (has_unsol) {
		char duri[200], durl[256];
		snprintf(duri, sizeof(duri),
		         "/zosmf/restconsoles/consoles/%s/detections/%s", cn, dkey);
		snprintf(durl, sizeof(durl), "http://%s%s", host ? host : "localhost", duri);
		if (addJsonString(b, "detection-key", dkey) < 0 ||
		    addJsonString(b, "detection-url", durl) < 0 ||
		    addJsonString(b, "detection-uri", duri) < 0) {
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

/* collect response body: { "cmd-response": "<escaped lines>" } */
__asm__("\n&FUNC	SETC 'send_collect'");
static int send_collect(Session *session, const char *text)
{
	int rc;
	JsonBuilder *b = createJsonBuilder();
	if (!b) {
		sendDefaultHeaders(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
		                   HTTP_CONTENT_TYPE_NONE, 0);
		return -1;
	}
	if (startJsonObject(b) < 0 ||
	    addJsonStringEsc(b, "cmd-response", text) < 0 ||
	    endJsonObject(b) < 0) {
		freeJsonBuilder(b);
		return -1;
	}
	rc = sendJSONResponse(session, HTTP_STATUS_OK, b);
	freeJsonBuilder(b);
	return rc;
}

/* ------------------------------------------------------------------ */
/* GET /zosmf/restconsoles/consoles/{console-name}/solmsgs/{key}       */
/* Returns the response lines new since the previous poll; empty when  */
/* nothing new (or the key is unknown/evicted) -> the client stops.    */
/* ------------------------------------------------------------------ */
int consoleCollectHandler(Session *session)
{
	const char *key = getPathParam(session, "cmd-response-key");
	char name[MVSMF_KVS_NAMELEN];
	NT_STORE *store;
	SOL_CURSOR cur;
	unsigned curlen = 0;
	unsigned total = 0;
	char *resp;
	int rc;

	store = mvsmf_kvstore(session->httpd);

	/* store unavailable, or unknown / evicted key -> empty (done) */
	if (!key || !store) {
		return send_collect(session, "");
	}
	key_to_name(key, name);
	if (nt_get(store, name, &cur, sizeof(cur), &curlen) != 0 ||
	    curlen < sizeof(cur)) {
		return send_collect(session, "");
	}

	resp = malloc(RESP_CAP);
	if (!resp) {
		return send_collect(session, "");
	}
	resp[0] = '\0';

	/* return only the lines beyond what we already delivered, then advance */
	correlate_once(session, cur.cmd, resp, RESP_CAP, cur.delivered, &total);
	cur.delivered = total;
	nt_set(store, name, &cur, sizeof(cur));

	rc = send_collect(session, resp);
	free(resp);
	return rc;
}

/* ------------------------------------------------------------------ */
/* GET /zosmf/restconsoles/consoles/{console-name}/detections/{key}    */
/* Reports whether the unsol-key has appeared in the (unsolicited)      */
/* message stream since the command was issued: detected / waiting /    */
/* expired (after detect-time).                                         */
/* ------------------------------------------------------------------ */
int consoleDetectHandler(Session *session)
{
	const char *dkey = getPathParam(session, "detection-key");
	char name[MVSMF_KVS_NAMELEN];
	NT_STORE *store;
	SOL_DETECTION det;
	unsigned dlen = 0;
	char msg[200];
	const char *status;
	JsonBuilder *b;
	int rc;

	store = mvsmf_kvstore(session->httpd);
	if (!dkey || !store ||
	    nt_get(store, (key_to_name(dkey, name), name), &det, sizeof(det),
	           &dlen) != 0 ||
	    dlen < sizeof(det)) {
		return send_console_error(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
		    5, 9, "Cannot find the result for the specified detection ID.");
	}

	msg[0] = '\0';
	if (detect_count(session, det.key, msg, sizeof(msg)) > (int)det.base_count) {
		status = "detected";
	} else if (tod_hi() - det.anchor_hi > det.detect_secs) {
		status = "expired";
		msg[0] = '\0';
	} else {
		status = "waiting";
		msg[0] = '\0';
	}

	b = createJsonBuilder();
	if (!b) {
		sendDefaultHeaders(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
		                   HTTP_CONTENT_TYPE_NONE, 0);
		return -1;
	}
	if (startJsonObject(b) < 0 ||
	    addJsonString(b, "status", status) < 0 ||
	    addJsonStringEsc(b, "msg", msg) < 0 ||
	    endJsonObject(b) < 0) {
		freeJsonBuilder(b);
		return -1;
	}
	rc = sendJSONResponse(session, HTTP_STATUS_OK, b);
	freeJsonBuilder(b);
	return rc;
}

/* ================================================================== */
/* endpoint 4: hardcopy log                                            */
/* ================================================================== */

/* case-insensitive equality (EBCDIC-aware via toupper). */
__asm__("\n&FUNC	SETC 'ci_eq'");
static int ci_eq(const char *a, const char *b)
{
	if (!a || !b) return 0;
	while (*a && *b) {
		if (toupper((unsigned char)*a) != toupper((unsigned char)*b)) return 0;
		a++; b++;
	}
	return *a == *b;
}

/* seconds-of-day from the "hh.mm.ss" field of a formatted MTT line
 * (right after the 4-char flags field); -1 if it does not parse. */
__asm__("\n&FUNC	SETC 'mtt_secs_of_day'");
static int mtt_secs_of_day(const char *dat, int len)
{
	int i = 4, h = 0, nd = 0, m, s;

	while (i < len && dat[i] == ' ') i++;
	while (i < len && dat[i] >= '0' && dat[i] <= '9') {
		h = h * 10 + (dat[i] - '0'); i++; nd++;
	}
	if (nd == 0 || nd > 2 || i + 5 >= len) return -1;     /* need ".mm.ss" */
	if (dat[i] != '.' || dat[i + 3] != '.') return -1;
	if (dat[i+1] < '0' || dat[i+1] > '9' || dat[i+2] < '0' || dat[i+2] > '9') return -1;
	if (dat[i+4] < '0' || dat[i+4] > '9' || dat[i+5] < '0' || dat[i+5] > '9') return -1;
	m = (dat[i+1] - '0') * 10 + (dat[i+2] - '0');
	s = (dat[i+4] - '0') * 10 + (dat[i+5] - '0');
	if (h > 23 || m > 59 || s > 59) return -1;
	return h * 3600 + m * 60 + s;
}

/* parse "nnnu" (u in s/m/h, nnn 1-999) -> seconds; default 600; -1 bad. */
__asm__("\n&FUNC	SETC 'parse_time_range'");
static int parse_time_range(const char *p)
{
	int n = 0, nd = 0;

	if (!p || !*p) return 600;
	while (*p >= '0' && *p <= '9') { n = n * 10 + (*p - '0'); p++; nd++; }
	if (nd == 0 || nd > 3 || n < 1 || n > 999) return -1;
	switch (*p) {
	case 's': case 'S':            break;
	case 'm': case 'M': n *= 60;   break;
	case 'h': case 'H': n *= 3600; break;
	default: return -1;
	}
	return p[1] ? -1 : n;
}

/* format a UNIX time as "Wkd Mon DD HH:MM:SS GMT YYYY" (z/OSMF style). */
__asm__("\n&FUNC	SETC 'fmt_gmt_time'");
static void fmt_gmt_time(char *out, size_t osz, time_t secs)
{
	const char *wd[7]  = {"Sun","Mon","Tue","Wed","Thu","Fri","Sat"};
	const char *mo[12] = {"Jan","Feb","Mar","Apr","May","Jun",
	                      "Jul","Aug","Sep","Oct","Nov","Dec"};
	struct tm g;
	int wi, mi;

	gmtime_r(&secs, &g);
	wi = (g.tm_wday >= 0 && g.tm_wday < 7)  ? g.tm_wday : 0;
	mi = (g.tm_mon  >= 0 && g.tm_mon  < 12) ? g.tm_mon  : 0;
	snprintf(out, osz, "%s %s %02d %02d:%02d:%02d GMT %d",
	         wd[wi], mo[mi], g.tm_mday, g.tm_hour, g.tm_min, g.tm_sec,
	         g.tm_year + 1900);
}

/* Query parameter lookup tolerant of the CGI env name case: try the name as
 * the client sent it (e.g. "timeRange"), then the upper-cased form, since it
 * is unclear whether httpd preserves or upper-cases the query var name. */
__asm__("\n&FUNC	SETC 'qparam'");
static const char *qparam(Session *s, const char *name, const char *upper)
{
	const char *v = getQueryParam(s, name);
	return v ? v : getQueryParam(s, upper);
}

/* ------------------------------------------------------------------ */
/* GET /zosmf/restconsoles/v1/log -- hardcopy log (endpoint 4)         */
/*                                                                      */
/* 3.8j has no OPERLOG and the active SYSLOG on spool is not browsable  */
/* (records=0), so the source is the Master Trace Table -- the in-      */
/* memory tail of the hardcopy log.  MVP: a timeRange window backward   */
/* (or forward) from now / time / timestamp.  The MTT carries only      */
/* hh.mm.ss, so dates are reconstructed by walking newest->oldest and   */
/* rolling the date back at each midnight crossing.                     */
/* See docs/endpoints/console/hardcopy-log.md.                          */
/* ------------------------------------------------------------------ */
int consoleLogHandler(Session *session)
{
	const char *qrange = qparam(session, "timeRange", "TIMERANGE");
	const char *qtime  = qparam(session, "time", "TIME");
	const char *qts    = qparam(session, "timestamp", "TIMESTAMP");
	const char *qhard  = qparam(session, "hardcopy", "HARDCOPY");
	const char *qsys   = qparam(session, "sysName", "SYSNAME");
	const char *qdir   = qparam(session, "direction", "DIRECTION");

	int range, fwd = 0, tz_min, total = 0, i, days_back, prev_hms;
	time_t now, now_f, anchor, lo, hi;
	struct tm base, gt;
	const unsigned char *sid;
	char sysname[9], numbuf[24];
	CMTT *cmtt;
	MTENTRY **arr;
	unsigned n;
	time_t *esecs = NULL;
	JsonBuilder *b = NULL;
	int rc;

	/* ---- validate query params ---- */
	range = parse_time_range(qrange);
	if (range < 0)
		return send_console_error(session, HTTP_STATUS_BAD_REQUEST, 1, 22,
		    "The parameter timeRange is invalid. Example: 10m.");

	if (qdir && *qdir) {
		if (ci_eq(qdir, "forward")) fwd = 1;
		else if (ci_eq(qdir, "backward")) fwd = 0;
		else return send_console_error(session, HTTP_STATUS_BAD_REQUEST, 1, 22,
		    "The parameter direction is invalid. Use backward or forward.");
	}
	if (qhard && *qhard && !ci_eq(qhard, "operlog") && !ci_eq(qhard, "syslog"))
		return send_console_error(session, HTTP_STATUS_BAD_REQUEST, 1, 22,
		    "The parameter hardcopy is invalid. Use operlog or syslog.");
	if (qsys && strlen(qsys) > 8)
		return send_console_error(session, HTTP_STATUS_BAD_REQUEST, 1, 24,
		    "The sysName cannot exceed 8 characters.");

	now = time((time_t *)0);
	localtime_r(&now, &base);
	gmtime_r(&now, &gt);
	tz_min = (base.tm_hour * 60 + base.tm_min) - (gt.tm_hour * 60 + gt.tm_min);
	if (tz_min > 720)  tz_min -= 1440;
	if (tz_min < -720) tz_min += 1440;

	/* ---- anchor: timestamp (ms) overrides time; default now ----
	 * On 3.8j mktime() does NOT re-apply the TZ offset, so every entry's esecs
	 * (and the emitted timestamps) are the LOCAL wall clock numerically. Keep
	 * the anchor in that same frame: "now" via mktime(localtime(now)), and
	 * time/timestamp anchors taken as-is -- the client got its timestamps from
	 * this same field, so they round-trip without a TZ correction. */
	{ struct tm tmp = base; now_f = mktime(&tmp); }
	anchor = now_f;
	if (qts && *qts) {
		int l = (int)strlen(qts), k;
		char t[16];
		for (k = 0; k < l; k++)
			if (qts[k] < '0' || qts[k] > '9')
				return send_console_error(session, HTTP_STATUS_BAD_REQUEST, 1, 22,
				    "The parameter timestamp is invalid.");
		if (l <= 3) {
			anchor = 0;
		} else {
			int c = l - 3;                  /* ms -> s by dropping 3 digits */
			if (c > 15) c = 15;
			memcpy(t, qts, c); t[c] = '\0';
			anchor = (time_t)strtoul(t, (char **)0, 10);
		}
	} else if (qtime && *qtime) {
		struct tm it;
		int yy = 0, mo = 0, dd = 0, hh = 0, mm = 0, ss = 0;
		if (sscanf(qtime, "%d-%d-%dT%d:%d:%d", &yy, &mo, &dd, &hh, &mm, &ss) < 5)
			return send_console_error(session, HTTP_STATUS_BAD_REQUEST, 1, 22,
			    "The parameter time is invalid. Example: 2021-05-25T07:00Z.");
		memset(&it, 0, sizeof(it));
		it.tm_year = yy - 1900; it.tm_mon = mo - 1; it.tm_mday = dd;
		it.tm_hour = hh; it.tm_min = mm; it.tm_sec = ss; it.tm_isdst = -1;
		anchor = mktime(&it);          /* same (local wall clock) frame as esecs */
	}

	/* future-time error applies only to an explicitly supplied anchor; the
	 * default anchor is "now" and can never be in the future. */
	if (((qts && *qts) || (qtime && *qtime)) && anchor > now_f)
		return send_console_error(session, HTTP_STATUS_BAD_REQUEST, 1, 23,
		    "The time or timestamp specified is in the future.");

	if (fwd) { lo = anchor; hi = anchor + range; }
	else     { hi = anchor; lo = (anchor > (time_t)range) ? anchor - range : 0; }

	/* local system id (SMF SID) */
	sid = __smfid();
	if (sid) { memcpy(sysname, sid, 4); sysname[4] = '\0'; }
	else sysname[0] = '\0';
	{ int k = (int)strlen(sysname); while (k > 0 && sysname[k-1] == ' ') sysname[--k] = '\0'; }

	/* ---- snapshot the MTT, reconstruct each entry's UNIX time ---- */
	cmtt = cmtt_new();
	arr  = cmtt ? cmtt_get_array(cmtt) : (MTENTRY **)0;
	n    = arr ? array_count(&arr) : 0;

	if (n) {
		esecs = (time_t *)malloc(n * sizeof(time_t));
		if (!esecs) {
			if (cmtt) cmtt_free(&cmtt);
			return send_console_error(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
			    8, 1, "An error occurred during the retrieval of the hardcopy log.");
		}
	}

	days_back = 0;
	prev_hms  = base.tm_hour * 3600 + base.tm_min * 60 + base.tm_sec;
	for (i = (int)n - 1; i >= 0; i--) {                /* newest -> oldest */
		MTENTRY *e = arr[i];
		int sod = e ? mtt_secs_of_day((const char *)e->mtentdat, (int)e->mtentlen) : -1;
		struct tm etm;
		if (sod < 0) { esecs[i] = (time_t)0; continue; }
		if (sod > prev_hms + 43200) days_back++;       /* midnight crossing */
		prev_hms = sod;
		etm = base;
		etm.tm_mday -= days_back;
		etm.tm_hour  = sod / 3600;
		etm.tm_min   = (sod % 3600) / 60;
		etm.tm_sec   = sod % 60;
		etm.tm_isdst = -1;
		esecs[i] = mktime(&etm);
	}

	/* ---- build the response ---- */
	b = createJsonBuilder();
	if (!b) {
		free(esecs);
		if (cmtt) cmtt_free(&cmtt);
		sendDefaultHeaders(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
		                   HTTP_CONTENT_TYPE_NONE, 0);
		return -1;
	}

	if (startJsonObject(b) < 0) goto fail;
	if (addJsonNumber(b, "timezone", tz_min / 60) < 0) goto fail;
	if (addJsonString(b, "source", "SYSLOG") < 0) goto fail;
	if (startJsonArrayKey(b, "items") < 0) goto fail;

	for (i = 0; i < (int)n && total < 10000; i++) {    /* oldest -> newest */
		MTENTRY *e = arr[i];
		const char *dat;
		int len, off, mlen, jl;
		char msg[256], jn[16], ts[40];

		if (!e || esecs[i] == 0 || esecs[i] < lo || esecs[i] > hi) continue;

		dat = (const char *)e->mtentdat;
		len = (int)e->mtentlen;

		off = (len > MTT_MSG_OFF) ? MTT_MSG_OFF : 0;
		while (off < len && dat[off] == ' ') off++;
		mlen = rstrip_len(dat + off, len - off);
		if (mlen > (int)sizeof(msg) - 1) mlen = (int)sizeof(msg) - 1;
		if (mlen < 0) mlen = 0;
		memcpy(msg, dat + off, mlen); msg[mlen] = '\0';

		jl = MTT_SRC_LEN;
		if (MTT_SRC_OFF + jl > len) jl = len - MTT_SRC_OFF;
		if (jl < 0) jl = 0;
		if (jl > (int)sizeof(jn) - 1) jl = (int)sizeof(jn) - 1;
		memcpy(jn, dat + MTT_SRC_OFF, jl); jn[jl] = '\0';
		while (jl > 0 && jn[jl-1] == ' ') jn[--jl] = '\0';

		fmt_gmt_time(ts, sizeof(ts), esecs[i]);
		snprintf(numbuf, sizeof(numbuf), "%lu000", (unsigned long)esecs[i]);

		if (startJsonObject(b) < 0) goto fail;
		if (addJsonStringEsc(b, "message", msg) < 0) goto fail;
		if (addJsonString(b, "jobName", jn) < 0) goto fail;
		if (addJsonString(b, "system", sysname) < 0) goto fail;
		if (addJsonString(b, "type", "HARDCOPY") < 0) goto fail;
		if (addJsonString(b, "time", ts) < 0) goto fail;
		if (addJsonRaw(b, "timestamp", numbuf) < 0) goto fail;
		if (endJsonObject(b) < 0) goto fail;
		total++;
	}
	if (endArray(b) < 0) goto fail;

	/* "totalitems" (lower-case) -- the Zowe zos-logs SDK reads resp.totalitems
	 * for its summary line; camelCase leaves the %s placeholders unfilled. */
	if (addJsonNumber(b, "totalitems", total) < 0) goto fail;
	snprintf(numbuf, sizeof(numbuf), "%lu000", (unsigned long)(fwd ? hi : lo));
	if (addJsonRaw(b, "nextTimestamp", numbuf) < 0) goto fail;
	if (endJsonObject(b) < 0) goto fail;

	free(esecs);
	if (cmtt) cmtt_free(&cmtt);
	rc = sendJSONResponse(session, HTTP_STATUS_OK, b);
	freeJsonBuilder(b);
	return rc;

fail:
	free(esecs);
	if (cmtt) cmtt_free(&cmtt);
	freeJsonBuilder(b);
	return -1;
}
