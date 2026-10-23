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

/* Count MTT entries whose (uppercased) text contains keyword_upper; record the
 * newest matching line into latest (rstripped, NUL-terminated). */
#ifdef __MVS__
__asm__("\n&FUNC	SETC 'mtt_detect_count'");
#endif
int mtt_detect_count(Session *session, const char *keyword_upper,
                     char *latest, size_t lsz)
{
	CMTT *cmtt;
	MTENTRY **arr;
	unsigned n;
	unsigned i;
	int count = 0;

	if (latest && lsz) latest[0] = '\0';

	if (mtt_snap_open(session, &cmtt, &arr, &n) != 0)
		return MTT_SNAP_FAILED;

	for (i = 0; i < n; i++) {
		MTENTRY *e = arr[i];
		char up[200];
		int len = mtt_len(e);
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

	cmtt_free(&cmtt);
	return count;
}
