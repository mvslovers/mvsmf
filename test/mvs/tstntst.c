/*
 * tstntst.c - unit tests for the persistent name/value store (src/ntstore.c).
 *
 * MVS-only: the store uses __getm / lock / STCK (MVS services), so this runs
 * via `make test-mvs`.  Covers set/get roundtrip, upsert, miss, delete, and
 * LRU eviction with last-access touch (issue #143 acceptance 1-5).
 */
#include <string.h>
#include <mbtcheck.h>

#include "mvssupa.h"   /* __getm */
#include "ntstore.h"

/* build a distinct 16-byte key "KEYnnnn" (zero-padded) */
static void mkname(char name[MVSMF_KVS_NAMELEN], int i)
{
	memset(name, 0, MVSMF_KVS_NAMELEN);
	name[0] = 'K';
	name[1] = 'E';
	name[2] = 'Y';
	name[3] = (char)('0' + (i / 1000) % 10);
	name[4] = (char)('0' + (i / 100) % 10);
	name[5] = (char)('0' + (i / 10) % 10);
	name[6] = (char)('0' + i % 10);
}

int main(void)
{
	NT_STORE *s;
	char name[MVSMF_KVS_NAMELEN];
	char nm[MVSMF_KVS_NAMELEN];
	char buf[MVSMF_KVS_VALMAX];
	unsigned outlen = 0;
	int i;

	printf("=== ntstore tests ===\n");

	s = (NT_STORE *)__getm(sizeof(NT_STORE));
	CHECK(s != 0, "getmain store block");
	if (!s) {
		return mbt_test_summary("TSTNTST");
	}

	nt_store_init(s);
	CHECK(memcmp(s->eye, MVSMF_KVS_EYE, 8) == 0, "store eyecatcher stamped");
	CHECK_EQ((int)s->nslots, MVSMF_KVS_SLOTS, "nslots");

	/* 1. set -> get roundtrip */
	mkname(name, 1);
	CHECK_EQ(nt_set(s, name, "hello", 6), 0, "nt_set ok");
	CHECK_EQ(nt_get(s, name, buf, sizeof(buf), &outlen), 0, "nt_get hit");
	CHECK_EQ((int)outlen, 6, "value length");
	CHECK(strcmp(buf, "hello") == 0, "value roundtrip");

	/* 2. upsert overwrites in place */
	CHECK_EQ(nt_set(s, name, "world!", 7), 0, "nt_set overwrite");
	nt_get(s, name, buf, sizeof(buf), &outlen);
	CHECK(strcmp(buf, "world!") == 0, "upsert overwrote value");

	/* 3. miss -> 4 */
	mkname(nm, 5);
	CHECK_EQ(nt_get(s, nm, buf, sizeof(buf), &outlen), 4, "nt_get miss -> 4");

	/* 4. delete (also empties the store before the eviction test) */
	CHECK_EQ(nt_del(s, name), 0, "nt_del hit");
	CHECK_EQ(nt_get(s, name, buf, sizeof(buf), &outlen), 4, "get after del -> 4");
	CHECK_EQ(nt_del(s, name), 4, "nt_del miss -> 4");

	/* 5. fill all slots, keep the first young, add a 33rd -> LRU evicts the
	 *    oldest *untouched* slot, not the touched one. */
	for (i = 0; i < MVSMF_KVS_SLOTS; i++) {
		mkname(nm, 200 + i);
		nt_set(s, nm, "v", 2);
	}
	mkname(nm, 200);                     /* touch the first-inserted key */
	nt_get(s, nm, buf, sizeof(buf), &outlen);
	mkname(nm, 999);                     /* 33rd key -> one eviction */
	nt_set(s, nm, "new", 4);

	mkname(nm, 999);
	CHECK_EQ(nt_get(s, nm, buf, sizeof(buf), &outlen), 0,
	         "new key present after eviction");
	mkname(nm, 200);
	CHECK_EQ(nt_get(s, nm, buf, sizeof(buf), &outlen), 0,
	         "touched key survives eviction");
	mkname(nm, 201);
	CHECK_EQ(nt_get(s, nm, buf, sizeof(buf), &outlen), 4,
	         "LRU (oldest untouched) evicted");

	return mbt_test_summary("TSTNTST");
}
