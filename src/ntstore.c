#include <string.h>

#include "ntstore.h"
#include "mvssupa.h"    /* __getclk */
#include "cliblock.h"   /* lock / unlock, LOCK_EXC */

/*
 * Persistent name-keyed store. See ntstore.h.
 *
 * The latch (lock(s, LOCK_EXC)) protects only the per-op slot mutation; it does
 * NOT span a caller's get -> work -> set transaction (that is a documented
 * "one outstanding op per key" contract, see issue #143).
 */

/* TTL window expressed in TOD high-word ticks (each ~1.05 s). ~5 minutes.
 * Comparing the TOD high word avoids 64-bit threshold constants. */
#define KVS_TTL_TICKS   300

static unsigned long long tod_now(void)
{
	unsigned long long t = 0;
	__getclk(&t);
	return t;
}

static int name_eq(const char *a, const char *b)
{
	return memcmp(a, b, MVSMF_KVS_NAMELEN) == 0;
}

static int name_free(const char *n)
{
	int i;
	for (i = 0; i < MVSMF_KVS_NAMELEN; i++) {
		if (n[i]) {
			return 0;
		}
	}
	return 1;
}

static int slot_expired(const NT_SLOT *sl, unsigned long long now)
{
	unsigned now_hi = (unsigned)(now >> 32);
	unsigned acc_hi = (unsigned)(sl->last_access >> 32);
	return (now_hi - acc_hi) >= KVS_TTL_TICKS;
}

__asm__("\n&FUNC	SETC 'nt_store_init'");
void nt_store_init(NT_STORE *s)
{
	if (!s) {
		return;
	}
	memset(s, 0, sizeof(NT_STORE));
	memcpy(s->eye, MVSMF_KVS_EYE, 8);
	s->len    = (unsigned short)sizeof(NT_STORE);
	s->ver    = 1;
	s->nslots = MVSMF_KVS_SLOTS;
}

__asm__("\n&FUNC	SETC 'nt_set'");
int nt_set(NT_STORE *s, const char *name, const void *val, unsigned len)
{
	unsigned i;
	unsigned long long now;
	NT_SLOT *target = (NT_SLOT *)0;

	if (!s || !name) {
		return 8;
	}
	if (len > MVSMF_KVS_VALMAX) {
		len = MVSMF_KVS_VALMAX;          /* clamp oversized values */
	}

	now = tod_now();
	lock(s, LOCK_EXC);

	/* 1. existing name -> overwrite in place */
	for (i = 0; i < s->nslots; i++) {
		if (!name_free(s->slot[i].name) && name_eq(s->slot[i].name, name)) {
			target = &s->slot[i];
			break;
		}
	}

	/* 2. otherwise a free or expired slot */
	if (!target) {
		for (i = 0; i < s->nslots; i++) {
			if (name_free(s->slot[i].name) ||
			    slot_expired(&s->slot[i], now)) {
				target = &s->slot[i];
				break;
			}
		}
	}

	/* 3. otherwise evict the least-recently-accessed slot */
	if (!target) {
		unsigned lru = 0;
		unsigned long long oldest = s->slot[0].last_access;
		for (i = 1; i < s->nslots; i++) {
			if (s->slot[i].last_access < oldest) {
				oldest = s->slot[i].last_access;
				lru = i;
			}
		}
		target = &s->slot[lru];
	}

	memcpy(target->name, name, MVSMF_KVS_NAMELEN);
	if (len) {
		memcpy(target->value, val, len);
	}
	target->val_len     = (unsigned short)len;
	target->last_access = now;

	unlock(s, LOCK_EXC);
	return 0;
}

__asm__("\n&FUNC	SETC 'nt_get'");
int nt_get(NT_STORE *s, const char *name, void *buf, unsigned max,
           unsigned *out_len)
{
	unsigned i;
	unsigned long long now;
	int rc = 4;

	if (!s || !name) {
		return 4;
	}

	now = tod_now();
	lock(s, LOCK_EXC);

	for (i = 0; i < s->nslots; i++) {
		if (name_free(s->slot[i].name)) {
			continue;
		}
		if (slot_expired(&s->slot[i], now)) {
			continue;                    /* expired -> treat as miss */
		}
		if (name_eq(s->slot[i].name, name)) {
			unsigned n = s->slot[i].val_len;
			if (n > max) {
				n = max;
			}
			if (n && buf) {
				memcpy(buf, s->slot[i].value, n);
			}
			if (out_len) {
				*out_len = n;
			}
			s->slot[i].last_access = now; /* touch keeps active keys alive */
			rc = 0;
			break;
		}
	}

	unlock(s, LOCK_EXC);
	return rc;
}

__asm__("\n&FUNC	SETC 'nt_del'");
int nt_del(NT_STORE *s, const char *name)
{
	unsigned i;
	int rc = 4;

	if (!s || !name) {
		return 4;
	}

	lock(s, LOCK_EXC);
	for (i = 0; i < s->nslots; i++) {
		if (!name_free(s->slot[i].name) && name_eq(s->slot[i].name, name)) {
			memset(&s->slot[i], 0, sizeof(NT_SLOT));
			rc = 0;
			break;
		}
	}
	unlock(s, LOCK_EXC);
	return rc;
}
