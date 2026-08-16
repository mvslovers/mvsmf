/*
 * tstetag.c - #152: the ETag stamp and the If-Match precondition.
 *
 * The optimistic-locking protocol only works if two properties hold, and both
 * fail silently rather than loudly when broken:
 *
 *   1. The stamp changes whenever the content changes -- including changes
 *      that keep the byte total identical (a character swapped) and changes
 *      that only move a record boundary (the same bytes re-split). A stamp
 *      that misses a change lets a save overwrite someone else's edit, which
 *      is the exact failure the feature exists to prevent.
 *   2. The stamp is stable: the same records always produce the same value.
 *      An unstable one produces 412 on saves that should have succeeded.
 *
 * If-Match then has to survive what clients actually put on the wire. Zowe
 * echoes the value bare, other clients quote it, a proxy may weaken it to
 * W/"..." or merge several into a list. Every one of those forms means the
 * same thing and must not be read as a mismatch.
 *
 * ====================================================================
 * This test drives the REAL implementation: src/etag.c is #included
 * below, so a later refactor stays covered. dsapi.c itself cannot compile
 * on the host (MVS intrinsics, HLASM labels, live sockets), which is why
 * the stamp lives in its own TU.
 * ====================================================================
 *
 * Runs on host via `make test-host`.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <mbtcheck.h>

#include "../../src/etag.c"

static char msg[160];

/* Stamp a sequence of records, the way dataset_etag() does. */
static void
stamp(char *out, const char *const *recs, int n)
{
	ETAGCTX ctx;
	int i;

	etag_init(&ctx);
	for (i = 0; i < n; i++) {
		etag_update(&ctx, recs[i], strlen(recs[i]));
	}
	etag_final(&ctx, out, ETAG_SIZE);
}

static void
check_match(const char *header, const char *etag, int want)
{
	sprintf(msg, "If-Match: %s %s %s", header,
		want ? "matches" : "does not match", etag);
	CHECK_EQ(etag_matches(header, etag), want, msg);
}

int
main(void)
{
	char a[ETAG_SIZE];
	char b[ETAG_SIZE];

	printf("\n--- #152: the stamp is stable and well formed ---\n");
	{
		const char *recs[] = { "HELLO", "WORLD" };

		stamp(a, recs, 2);
		stamp(b, recs, 2);
		CHECK(strcmp(a, b) == 0, "the same records stamp the same twice");
		CHECK_EQ((int) strlen(a), ETAG_LEN, "the stamp is ETAG_LEN chars");
		CHECK(strspn(a, "0123456789ABCDEF") == ETAG_LEN,
			"the stamp is uppercase hex only");
	}

	printf("\n--- #152: any content change must change the stamp ---\n");
	{
		const char *base[]    = { "HELLO", "WORLD" };
		const char *edited[]  = { "HELLO", "WORLE" };  /* same length */
		const char *added[]   = { "HELLO", "WORLD", "!" };
		const char *removed[] = { "HELLO" };
		const char *empty[]   = { "" };

		stamp(a, base, 2);

		stamp(b, edited, 2);
		CHECK(strcmp(a, b) != 0,
			"one byte changed, byte total unchanged, stamp differs");

		stamp(b, added, 3);
		CHECK(strcmp(a, b) != 0, "a record added changes the stamp");

		stamp(b, removed, 1);
		CHECK(strcmp(a, b) != 0, "a record removed changes the stamp");

		stamp(b, empty, 1);
		CHECK(strcmp(a, b) != 0, "an emptied member changes the stamp");
	}

	printf("\n--- #152: record boundaries are part of the stamp ---\n");
	{
		/* The same bytes, split differently. Without the length fold in
		   etag_update() these collide, and a re-blocked data set would
		   pass an If-Match it should have failed. */
		const char *split_a[] = { "AB", "C" };
		const char *split_b[] = { "A", "BC" };

		stamp(a, split_a, 2);
		stamp(b, split_b, 2);
		CHECK(strcmp(a, b) != 0, "AB|C and A|BC do not stamp alike");
	}

	printf("\n--- #264: a byte stream stamps independently of chunking ---\n");
	{
		/* uss_etag() reads a file with a fixed buffer, so the same content
		   arrives as whatever chunks the size and the UFS block layout
		   produce. etag_update_raw() must therefore fold bytes only: if the
		   chunk lengths reached the CRC, one buffer size would stamp a file
		   differently from another, and a client's If-Match would fail
		   against content nobody changed. */
		const char whole[] = "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG";
		size_t     len = sizeof(whole) - 1;
		ETAGCTX    ctx;
		size_t     off;
		size_t     cut[] = { 7, 13, 23 };
		int        i;

		etag_init(&ctx);
		etag_update_raw(&ctx, whole, len);
		etag_final(&ctx, a, sizeof(a));

		etag_init(&ctx);
		off = 0;
		for (i = 0; i < 3 && off < len; i++) {
			size_t n = (cut[i] < len - off) ? cut[i] : len - off;
			etag_update_raw(&ctx, whole + off, n);
			off += n;
		}
		etag_update_raw(&ctx, whole + off, len - off);
		etag_final(&ctx, b, sizeof(b));

		CHECK(strcmp(a, b) == 0,
			"one buffer and 7|13|23|rest stamp the same bytes alike");

		/* Byte-for-byte, though, it must still be a content stamp. */
		etag_init(&ctx);
		etag_update_raw(&ctx, "THE QUICK BROWN FOX JUMPS OVER THE LAZY DO", len - 1);
		etag_final(&ctx, b, sizeof(b));
		CHECK(strcmp(a, b) != 0, "a byte removed changes the stamp");

		etag_init(&ctx);
		etag_update_raw(&ctx, "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOD", len);
		etag_final(&ctx, b, sizeof(b));
		CHECK(strcmp(a, b) != 0, "a byte changed changes the stamp");

		/* The two folds are different definitions on purpose -- mixing them
		   within one computation would silently produce a third. */
		etag_init(&ctx);
		etag_update(&ctx, whole, len);
		etag_final(&ctx, b, sizeof(b));
		CHECK(strcmp(a, b) != 0,
			"the record fold and the raw fold are distinct stamps");
	}

	printf("\n--- #152: an empty resource still stamps ---\n");
	{
		ETAGCTX ctx;

		etag_init(&ctx);
		CHECK_EQ(etag_final(&ctx, a, sizeof(a)), 0,
			"an empty data set produces a stamp, not an error");
		CHECK_EQ((int) strlen(a), ETAG_LEN, "and it is a full-length one");

		/* A buffer that cannot hold the value must be refused rather
		   than filled with a truncated stamp that would never match. */
		CHECK_EQ(etag_final(&ctx, b, ETAG_SIZE - 1), -1,
			"a short output buffer is rejected");
	}

	printf("\n--- #152: If-Match accepts every form clients send ---\n");
	{
		const char *e = "1234567890ABCDEF";

		check_match(e, e, 1);                       /* bare, as Zowe sends */
		check_match("\"1234567890ABCDEF\"", e, 1);  /* quoted, per RFC */
		check_match("W/\"1234567890ABCDEF\"", e, 1);/* weak validator */
		check_match(" 1234567890ABCDEF ", e, 1);    /* padded */
		check_match("1234567890abcdef", e, 1);      /* lower case hex */
		check_match("*", e, 1);                     /* wildcard */

		/* A list: the match may sit anywhere in it. */
		check_match("\"AAAAAAAAAAAAAAAA\", \"1234567890ABCDEF\"", e, 1);
		check_match("\"1234567890ABCDEF\", \"AAAAAAAAAAAAAAAA\"", e, 1);
	}

	printf("\n--- #152: If-Match rejects what it must ---\n");
	{
		const char *e = "1234567890ABCDEF";

		check_match("1234567890ABCDEE", e, 0);   /* last digit differs */
		check_match("AAAAAAAAAAAAAAAA", e, 0);
		check_match("1234567890ABCDE", e, 0);    /* one char short */
		check_match("1234567890ABCDEF0", e, 0);  /* one char long */
		check_match("", e, 0);
		check_match("\"AAAAAAAAAAAAAAAA\", \"BBBBBBBBBBBBBBBB\"", e, 0);

		CHECK_EQ(etag_matches(NULL, e), 0, "a NULL header never matches");
		CHECK_EQ(etag_matches(e, NULL), 0, "a NULL etag never matches");
	}

	printf("\n--- #263: If-None-Match reads the same predicate ---\n");
	{
		const char *e = "1234567890ABCDEF";

		/* One predicate serves both headers: etag_matches() answers "a
		   listed validator matches", which the write path turns into 412
		   and the read path into 304. No inverted variant is needed.

		   RFC 9110 13.1.2 makes that true of the wildcard as well: for
		   If-None-Match, "*" fails the condition when a current
		   representation exists -- and one the caller could stamp does --
		   so "*" answers 304, not 200. The opposite reading ("only if it
		   does not exist") belongs to a conditional create, which this
		   endpoint does not implement. */
		check_match("*", e, 1);
		check_match(e, e, 1);
		check_match("\"AAAAAAAAAAAAAAAA\", \"1234567890ABCDEF\"", e, 1);

		/* A stale validator leaves the condition true: send the body. */
		check_match("AAAAAAAAAAAAAAAA", e, 0);
	}

	printf("\n--- #152: X-IBM-Return-Etag is opt-in ---\n");
	{
		CHECK_EQ(etag_requested("true"), 1, "true asks for an ETag");
		CHECK_EQ(etag_requested("TRUE"), 1, "TRUE asks for an ETag");
		CHECK_EQ(etag_requested(" True "), 1, "padded True asks for one");

		/* Anything else is a no: the stamp costs a full extra read pass
		   over the resource, so it is never computed speculatively. */
		CHECK_EQ(etag_requested(NULL), 0, "an absent header asks for none");
		CHECK_EQ(etag_requested(""), 0, "an empty value asks for none");
		CHECK_EQ(etag_requested("false"), 0, "false asks for none");
		CHECK_EQ(etag_requested("truest"), 0, "a longer word is not true");
		CHECK_EQ(etag_requested("tru"), 0, "a shorter word is not true");
	}

	return mbt_test_summary("TSTETAG");
}
