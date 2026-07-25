/*
 * tstmtln.c - #176 regression: a signed-short MTT entry length must never
 * drive a negative / oversized copy length in the console MTT consumers.
 *
 * Root: the Master Trace Table entry length (ieezb806.h:76) is
 *     short   mtentlen;          / * 08 LENGTH OF CALLERS DATA * /
 * a SIGNED halfword. When the cmttget over-read (libc370 cmttget.c:51-64)
 * walks off the table boundary onto EBCDIC message text, the two bytes it
 * reads as the length have the high bit set (letters 0xC1-0xE9, digits
 * 0xF0-0xF9), so (int)mtentlen sign-extends NEGATIVE. The consapi.c consumers
 * clamp only the HIGH side, letting a negative length through:
 *     correlate_once  consapi.c:272  if (len > (int)sizeof(tmp)-1) len = ...
 *     detect_count    consapi.c:417  if (len > (int)sizeof(up) -1) len = ...
 * -> memcpy()/copy loop then receives a negative count (huge as size_t) =
 *    stack over-write. (The log path at consapi.c:1107 also clamps
 *    `if (mlen < 0) mlen = 0` and is immune.)
 *
 * This test pins the INVARIANT the fix must restore: the length reaching the
 * copy is non-negative and within the destination buffer.
 *
 * ====================================================================
 * LIMITATION — READ THIS BEFORE TRUSTING THIS TEST
 * --------------------------------------------------------------------
 * The two helpers below are a hand COPY (a MIRROR) of the clamp in
 * consapi.c. They DO NOT link the real correlate_once()/detect_count()
 * (consapi.c cannot compile on the host: file-scope HLASM asm labels +
 * MVS intrinsics). Consequences:
 *   - This is a RED->GREEN GATE FOR ONE SPECIFIC FIX (the len<0->0
 *     clamp), nothing more.
 *   - It is NOT durable regression protection: a future refactor of
 *     correlate_once()/detect_count() will NOT be caught here, because
 *     this test never executes those functions.
 *   - If you change the clamp in consapi.c, you MUST change the mirror
 *     below by hand or this test silently diverges from reality.
 * The DURABLE version is an MVS integration test that links the real
 * statics via a stubbed cmtt_get_array() and runs under test-mvs;
 * that is the follow-up, not this file.
 * ====================================================================
 *
 * The defect is the SIGN of the 16-bit value, which is layout- and
 * endianness-independent, so a symbolic field set reproduces it on any host.
 * #176.  Runs on host via `make test-host`.
 */
#include <string.h>
#include <mbtcheck.h>

/* Faithful minimal MTENTRY (ieezb806.h:69-80). Only the signed-short length is
 * load-bearing; it is set symbolically, so the target/host offset difference
 * (void *mtentimm is 4 bytes on S/370, 8 on a 64-bit host) does not matter. */
typedef struct {
	char   mtentflg[2];
	char   mtenttag[2];
	void  *mtentimm;
	short  mtentlen;      /* 08 LENGTH OF CALLERS DATA (signed halfword) */
	char   mtentdat[16];
} MTENTRY_T;

/* MIRROR of the length clamp in correlate_once() (consapi.c:270-272). */
static int correlate_once_len(const MTENTRY_T *e)
{
	char tmp[160];
	int len = e ? (int)e->mtentlen : 0;
	if (len > (int)sizeof(tmp) - 1) len = sizeof(tmp) - 1;
	return len;                 /* value handed to memcpy(tmp,...,len) at :273 */
}

/* MIRROR of the length clamp in detect_count() (consapi.c:414-417). */
static int detect_count_len(const MTENTRY_T *e)
{
	char up[200];
	int len = e ? (int)e->mtentlen : 0;
	if (len > (int)sizeof(up) - 1) len = sizeof(up) - 1;
	return len;                 /* loop/index bound up[k]/up[len] at :418-420 */
}

int main(void)
{
	MTENTRY_T e;

	printf("=== TSTMTLN: #176 signed-short mtentlen length clamp ===\n");

	/* 1. well-formed small entry: exact length passes through (regression floor) */
	memset(&e, 0, sizeof(e));
	e.mtentlen = 42;
	CHECK_EQ(correlate_once_len(&e), 42, "well-formed: correlate len == 42");
	CHECK_EQ(detect_count_len(&e), 42, "well-formed: detect len == 42");

	/* 2. large-but-positive entry: high clamp holds, no overflow */
	memset(&e, 0, sizeof(e));
	e.mtentlen = 5000;                       /* > buffers, < 0x7FFF */
	CHECK((size_t)correlate_once_len(&e) <= 159, "high clamp: correlate <= 159");
	CHECK((size_t)detect_count_len(&e)  <= 199, "high clamp: detect <= 199");

	/* 3. bogus/over-read entry: length field overlays EBCDIC text 0xC1C1 ("AA"),
	 *    high bit set -> (short) negative. The copy length MUST stay in bounds. */
	memset(&e, 0, sizeof(e));
	e.mtentlen = (short)0xC1C1;              /* -15935 */
	memcpy(e.mtentdat, "HELLO", 5);
	printf("  (short)0xC1C1 = %d ; correlate=%d ; detect=%d\n",
	       (int)e.mtentlen, correlate_once_len(&e), detect_count_len(&e));

	CHECK(correlate_once_len(&e) >= 0, "bogus: correlate copy length non-negative");
	CHECK((size_t)correlate_once_len(&e) <= 159, "bogus: correlate length within tmp[160]");
	CHECK(detect_count_len(&e) >= 0, "bogus: detect write index non-negative");
	CHECK((size_t)detect_count_len(&e) <= 199, "bogus: detect length within up[200]");

	return mbt_test_summary("TSTMTLN");
}
