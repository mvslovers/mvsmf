#include <ctype.h>
#include <string.h>

#include "mttsnap.h"

/*
 * Master Trace Table snapshot and keyword count, in their own translation unit
 * so test/host/tstmtsn.c can drive the real functions -- consapi.c itself
 * cannot compile on the host. Same arrangement as spoolln.c/tstspln.c.
 *
 * See mttsnap.h for why a failed snapshot has to stay distinct from an empty one.
 */

/* mtentlen is a signed halfword (ieezb806.h) over a flexible mtentdat[], so a
 * bogus or over-read entry presents a negative or absurd length and any use of
 * it as a scan bound walks off the record -- #176.
 *
 * That fix clamped the two consumers known at the time (the echo search and
 * detect_count) and left the rest of consapi.c reading the field raw. The
 * MODIFY correlation in #174 then started processing entries that the source
 * predicate had previously skipped, which turned one of those raw reads into a
 * live S0C4. Every length goes through here now, so there is one place to be
 * right rather than six. Callers still clamp to their own buffer on top. */
#ifdef __MVS__
__asm__("\n&FUNC	SETC 'mtt_len'");
#endif
int mtt_len(const MTENTRY *e)
{
	int len;

	if (!e) return 0;

	len = (int) e->mtentlen;
	if (len < 0) return 0;
	if (len > MTT_ENTRY_MAX) return MTT_ENTRY_MAX;

	return len;
}

/* Trim trailing blanks; return logical length. */
#ifdef __MVS__
__asm__("\n&FUNC	SETC 'rstrip_len'");
#endif
int rstrip_len(const char *s, int len)
{
	while (len > 0 && s[len - 1] == ' ') len--;
	return len;
}

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'mtt_snap_open'");
#endif
int mtt_snap_open(Session *session, CMTT **cmtt, MTENTRY ***arr, unsigned *n)
{
	*arr = (MTENTRY **)0;
	*n   = 0;
	*cmtt = cmtt_new();
	if (*cmtt) *arr = cmtt_get_array(*cmtt);

	/* No array is a failure, never an empty table: cmtt_new() returns NULL
	 * when it cannot copy the table, and cmtt_get_array() returns NULL only
	 * for a NULL handle or table. An empty table still gives an array, with
	 * no entries in it (#251, #407). */
	if (!*arr) {
		if (*cmtt) cmtt_free(cmtt);
		return MTT_SNAP_FAILED;
	}

	*n = array_count(arr);
	return 0;
}

/* seconds-of-day from the "hh.mm.ss" field of a formatted MTT line
 * (right after the 4-char flags field); -1 if it does not parse. */
#ifdef __MVS__
__asm__("\n&FUNC	SETC 'mtt_secs_of_day'");
#endif
int mtt_secs_of_day(const char *dat, int len)
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

/* Does the entry's (uppercased) text contain keyword_upper? */
#ifdef __MVS__
__asm__("\n&FUNC	SETC 'mtt_entry_has'");
#endif
static int mtt_entry_has(const MTENTRY *e, const char *keyword_upper)
{
	char up[200];
	int len = mtt_len(e);
	int k;

	if (len > (int)sizeof(up) - 1) len = sizeof(up) - 1;
	for (k = 0; k < len; k++)
		up[k] = (char)toupper((unsigned char)e->mtentdat[k]);
	up[len] = '\0';
	return strstr(up, keyword_upper) != (char *)0;
}

/* Take the anchor: the second of the newest stamped entry, and the matches
 * carrying exactly that second. The table is listed oldest first. */
#ifdef __MVS__
__asm__("\n&FUNC	SETC 'mtt_detect_anchor'");
#endif
int mtt_detect_anchor(Session *session, const char *keyword_upper,
                      MTT_ANCHOR *anchor)
{
	CMTT *cmtt;
	MTENTRY **arr;
	unsigned n;
	unsigned i;
	int cur = -1;
	unsigned same = 0;

	if (mtt_snap_open(session, &cmtt, &arr, &n) != 0)
		return MTT_SNAP_FAILED;

	for (i = 0; i < n; i++) {
		MTENTRY *e = arr[i];
		int s;
		if (!e) continue;
		s = mtt_secs_of_day(e->mtentdat, mtt_len(e));
		if (s >= 0 && s != cur) {
			cur = s;
			same = 0;
		}
		if (cur >= 0 && mtt_entry_has(e, keyword_upper)) same++;
	}

	anchor->secs = cur;
	anchor->same = same;
	cmtt_free(&cmtt);
	return 0;
}

/* Count the matches newer than the anchor; record the newest one into latest
 * (rstripped, NUL-terminated).
 *
 * "Newer" is the clock only, and the clock carries no date: a stamp is later
 * than the anchor if it is less than half a day ahead of it, modulo 24 hours
 * (the window holds minutes, so midnight is the only wrap that matters). At the
 * anchor's own second a match is new only beyond the ones already counted. */
#ifdef __MVS__
__asm__("\n&FUNC	SETC 'mtt_detect_since'");
#endif
int mtt_detect_since(Session *session, const char *keyword_upper,
                     const MTT_ANCHOR *anchor, char *latest, size_t lsz)
{
	CMTT *cmtt;
	MTENTRY **arr;
	unsigned n;
	unsigned i;
	int cur = -1;
	int count = 0;
	unsigned same = 0;

	if (latest && lsz) latest[0] = '\0';

	if (mtt_snap_open(session, &cmtt, &arr, &n) != 0)
		return MTT_SNAP_FAILED;

	for (i = 0; i < n; i++) {
		MTENTRY *e = arr[i];
		int len, delta, fresh;
		if (!e) continue;
		len = mtt_len(e);
		{
			int s = mtt_secs_of_day(e->mtentdat, len);
			if (s >= 0) cur = s;
		}
		if (cur < 0) continue;                 /* no time known yet: not new */
		if (!mtt_entry_has(e, keyword_upper)) continue;

		if (anchor->secs < 0) {
			fresh = 1;                         /* nothing stamped at the anchor */
		} else {
			delta = (cur - anchor->secs + 86400) % 86400;
			if (delta == 0) {
				same++;
				fresh = same > anchor->same;
			} else {
				fresh = delta < 43200;
			}
		}
		if (!fresh) continue;

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

	cmtt_free(&cmtt);
	return count;
}
