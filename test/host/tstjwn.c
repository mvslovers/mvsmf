/*
 * tstjwn.c - #440: who may see, read and purge which job on the JES2 spool.
 *
 * The policy decides on four inputs and every wrong answer is silent: a
 * foreign job that is let through reads like a feature, and one that is
 * hidden by mistake reads like an empty spool.  So each rule of the model has
 * a case here, and the ones that guard against leaks have a case for the
 * input that looks harmless:
 *
 *   - an own job is allowed without asking RACF, on the whole userid
 *     (MIKE1 is not MIKE10) and never when the owner is empty
 *   - a foreign job follows the RACF answer: 4 (no profile) and 8 (NONE)
 *     hide it, 0 shows it, a purge asks for UPDATE on top, any other
 *     return code and a missing ACEE show nothing
 *   - a component outside A-Z 0-9 $ # @ or longer than 8 hides the job, and
 *     RACF is never asked about an entity that would make the question a
 *     different one (a dot in a job name moves the owner)
 *   - the owner filter: "*" needs READ on "..", a foreign userid needs READ
 *     on "X..", and neither is a prefix match
 *   - what goes to the client is printable: anything else becomes '?'
 *
 * This test drives the REAL implementation: src/jwn.c is #included below.
 * RACF is a stub that answers like RAKF 2.0.0 does -- profiles are compared on
 * the first eight characters of the entity -- so the 8-character cache key
 * is checked against the rule it stands for.
 *
 * Runs on host via `mbt test`.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <mbtcheck.h>

#include "../../src/jwn.c"

static char msg[200];

/* ---- the RACF stub --------------------------------------------------- */

#define ACC_NONE   1
#define ACC_READ   2
#define ACC_UPDATE 3
#define ACC_RC12   4        /* the profile answers with an unusable code */

typedef struct prof {
	const char *key;        /* up to 8 characters, compared as a prefix  */
	int         access;
} PROF;

typedef struct stub {
	const PROF *prof;
	int         nprof;
	int         calls;
	char        last[JWN_ENTSZ + 8];
} STUB;

static int
stub_auth(void *arg, const char *entity, int want_update)
{
	STUB *s = (STUB *)arg;
	int i;
	char k8[JWN_KEYLEN + 1];

	s->calls++;
	snprintf(s->last, sizeof(s->last), "%s", entity);
	snprintf(k8, sizeof(k8), "%.8s", entity);

	for (i = 0; i < s->nprof; i++) {
		size_t l = strlen(s->prof[i].key);

		if (strncmp(k8, s->prof[i].key, l) != 0)
			continue;
		switch (s->prof[i].access) {
		case ACC_NONE:   return 8;
		case ACC_READ:   return want_update ? 8 : 0;
		case ACC_UPDATE: return 0;
		default:         return 12;
		}
	}
	return 4;
}

static void
ctx_set(JWN_CTX *c, STUB *s, const char *user, JWN_CACHE *cache)
{
	memset(c, 0, sizeof(*c));
	c->acee_present = 1;
	c->user = user;
	c->auth_fn = stub_auth;
	c->auth_arg = s;
	c->cache = cache;
}

static int
decide(const JWN_CTX *c, int op, const char *owner, const char *jn,
       const char *id, JWN_RES *res)
{
	return jwn_check(c, op, owner, jn, id, res);
}

/* ---- components, entity, probe -------------------------------------- */

static void
test_components(void)
{
	char out[JWN_ENTSZ];

	printf("\n--- #440: name parts ---\n");

	CHECK_EQ(jwn_component_ok("JOB00001"), 1, "JOB00001 is a name part");
	CHECK_EQ(jwn_component_ok("A$#@9"), 1, "national characters are allowed");
	CHECK_EQ(jwn_component_ok("ABCDEFGH"), 1, "eight characters are allowed");
	CHECK_EQ(jwn_component_ok("ABCDEFGHI"), 0, "nine characters are not");
	CHECK_EQ(jwn_component_ok(""), 0, "an empty part is not a part");
	CHECK_EQ(jwn_component_ok(NULL), 0, "NULL is not a part");
	CHECK_EQ(jwn_component_ok("lower"), 0, "lower case is not a part");
	CHECK_EQ(jwn_component_ok("A.B"), 0, "a dot would move the owner");
	CHECK_EQ(jwn_component_ok("A*"), 0, "a wildcard is not a part");
	CHECK_EQ(jwn_component_ok("A B"), 0, "a blank is not a part");
	CHECK_EQ(jwn_component_ok("A\n"), 0, "a control character is not a part");
	CHECK_EQ(jwn_component_ok("A%B"), 0, "a percent is not a part");

	CHECK_EQ(jwn_entity(out, sizeof(out), "TSTA", "MYJOB", "JOB00012"), 19,
		 "entity length");
	CHECK(strcmp(out, "TSTA.MYJOB.JOB00012") == 0, "entity is owner.job.id");
	CHECK_EQ(jwn_entity(out, sizeof(out), "ABCDEFGH", "ABCDEFGH", "ABCDEFGH"),
		 26, "the longest entity fits");
	CHECK_EQ(jwn_entity(out, 26, "ABCDEFGH", "ABCDEFGH", "ABCDEFGH"), -1,
		 "a buffer without room for the NUL is refused");
	CHECK_EQ(jwn_entity(out, sizeof(out), "", "MYJOB", "JOB1"), 11,
		 "an empty owner gives .job.id");
	CHECK_EQ(jwn_entity(out, sizeof(out), "TSTA", "MY.JOB", "JOB1"), -1,
		 "a dot in the job name is refused");
	CHECK_EQ(jwn_entity(out, sizeof(out), "TSTA", "MYJOB", "JOB*"), -1,
		 "a wildcard in the job id is refused");
	CHECK_EQ(jwn_entity(out, sizeof(out), "TST A", "MYJOB", "JOB1"), -1,
		 "a blank in the owner is refused");
	CHECK_EQ(jwn_entity(out, sizeof(out), "TSTA", "", "JOB1"), -1,
		 "an empty job name is refused");
	CHECK_EQ(jwn_entity(out, sizeof(out), "TSTA", "MYJOB", ""), -1,
		 "an empty job id is refused");
	CHECK_EQ(jwn_entity(out, sizeof(out), "TSTA", NULL, "JOB1"), -1,
		 "NULL is refused");

	CHECK_EQ(jwn_probe(out, sizeof(out), "TSTB"), 6, "probe length");
	CHECK(strcmp(out, "TSTB..") == 0, "probe for a userid is X..");
	CHECK_EQ(jwn_probe(out, sizeof(out), ""), 2, "probe for any owner");
	CHECK(strcmp(out, "..") == 0, "probe for any owner is ..");
	CHECK_EQ(jwn_probe(out, sizeof(out), "T*"), -1, "no wildcard in a probe");
	CHECK_EQ(jwn_probe(out, 3, "AB"), -1, "a small buffer is refused");
}

/* ---- own jobs -------------------------------------------------------- */

static void
test_mine(void)
{
	STUB s;
	JWN_CTX c;
	JWN_RES r;

	printf("\n--- #440: own jobs ---\n");

	memset(&s, 0, sizeof(s));
	s.nprof = 0;
	ctx_set(&c, &s, "TSTA", NULL);

	CHECK_EQ(jwn_mine("TSTA", "TSTA"), 1, "same userid is mine");
	CHECK_EQ(jwn_mine("MIKE1", "MIKE10"), 0, "MIKE1 is not MIKE10");
	CHECK_EQ(jwn_mine("MIKE10", "MIKE1"), 0, "MIKE10 is not MIKE1");
	CHECK_EQ(jwn_mine("tsta", "TSTA"), 0, "case differs: not mine");
	CHECK_EQ(jwn_mine("", "TSTA"), 0, "no owner is nobody's");
	CHECK_EQ(jwn_mine("", ""), 0, "no owner is not mine even for no user");
	CHECK_EQ(jwn_mine("TSTA", ""), 0, "no user owns nothing");
	CHECK_EQ(jwn_mine("TSTA ", "TSTA"), 0, "a padded owner is not mine");
	CHECK_EQ(jwn_mine(NULL, "TSTA"), 0, "NULL owner is not mine");

	/* No profile at all, as on a system without the setup: still mine. */
	CHECK_EQ(decide(&c, JWN_OP_LIST, "TSTA", "MYJOB", "JOB1", &r), JWN_ALLOW,
		 "own job is listed with no profile");
	CHECK_EQ(r.reason, JWN_R_OWN, "reason is OWN");
	CHECK_EQ(r.racf_calls, 0, "RACF is not asked for an own job");
	CHECK_EQ(s.calls, 0, "the stub saw no call");
	CHECK_EQ(decide(&c, JWN_OP_PURGE, "TSTA", "MYJOB", "JOB1", &r),
		 JWN_ALLOW, "own job is purged with no profile");
	CHECK_EQ(decide(&c, JWN_OP_READ, "TSTA", "A.B", "J*", &r), JWN_ALLOW,
		 "an own job with an odd name needs no entity");
	CHECK_EQ(r.elen, 0, "no entity was built");

	/* Even a profile that says NONE for the owner does not matter. */
	{
		static const PROF p[] = { { "TSTA", ACC_NONE } };

		s.prof = p;
		s.nprof = 1;
		CHECK_EQ(decide(&c, JWN_OP_PURGE, "TSTA", "MYJOB", "JOB1", &r),
			 JWN_ALLOW, "UACC(NONE) does not hide an own job");
		CHECK_EQ(s.calls, 0, "and RACF is still not asked");
	}
}

/* ---- foreign jobs ---------------------------------------------------- */

static void
test_foreign(void)
{
	static const PROF p[] = {
		{ "TSTB.",    ACC_READ },
		{ "TSTC.",    ACC_UPDATE },
		{ "TSTD.",    ACC_NONE },
		{ "TSTE.",    ACC_RC12 },
	};
	STUB s;
	JWN_CTX c;
	JWN_RES r;

	printf("\n--- #440: foreign jobs ---\n");

	memset(&s, 0, sizeof(s));
	s.prof = p;
	s.nprof = 4;
	ctx_set(&c, &s, "TSTA", NULL);

	CHECK_EQ(decide(&c, JWN_OP_LIST, "NOBODY", "JOB", "JOB1", &r), JWN_HIDE,
		 "no profile: hidden");
	CHECK_EQ(r.reason, JWN_R_NOPROFILE, "reason NOPROFILE");
	CHECK_EQ(r.rc, 4, "rc 4 recorded");

	CHECK_EQ(decide(&c, JWN_OP_READ, "TSTD", "JOB", "JOB1", &r), JWN_HIDE,
		 "NONE: hidden");
	CHECK_EQ(r.reason, JWN_R_NONE, "reason NONE");
	CHECK_EQ(r.rc, 8, "rc 8 recorded");

	CHECK_EQ(decide(&c, JWN_OP_LIST, "TSTB", "JOB", "JOB1", &r), JWN_ALLOW,
		 "READ: listed");
	CHECK_EQ(r.level, JWN_LV_READ, "level READ");
	CHECK_EQ(r.racf_calls, 1, "one RACF call for a list entry");
	CHECK(strcmp(s.last, "TSTB.JOB.JOB1") == 0, "the entity asked is exact");
	CHECK_EQ(decide(&c, JWN_OP_READ, "TSTB", "JOB", "JOB1", &r), JWN_ALLOW,
		 "READ: read");
	CHECK_EQ(decide(&c, JWN_OP_PURGE, "TSTB", "JOB", "JOB1", &r),
		 JWN_NOPURGE, "READ: purge refused");
	CHECK_EQ(r.level, JWN_LV_READ, "READ stays READ after the UPDATE ask");
	CHECK_EQ(r.racf_calls, 2, "a purge asks twice");

	CHECK_EQ(decide(&c, JWN_OP_LIST, "TSTC", "JOB", "JOB1", &r), JWN_ALLOW,
		 "UPDATE: listed");
	CHECK_EQ(r.racf_calls, 1, "UPDATE is not asked for a list entry");
	CHECK_EQ(decide(&c, JWN_OP_PURGE, "TSTC", "JOB", "JOB1", &r), JWN_ALLOW,
		 "UPDATE: purge");
	CHECK_EQ(r.level, JWN_LV_UPDATE, "level UPDATE");

	CHECK_EQ(decide(&c, JWN_OP_READ, "TSTE", "JOB", "JOB1", &r), JWN_HIDE,
		 "rc 12: hidden");
	CHECK_EQ(r.reason, JWN_R_ERR_RC, "reason ERR_RC");
	CHECK_EQ(decide(&c, JWN_OP_PURGE, "TSTE", "JOB", "JOB1", &r), JWN_HIDE,
		 "rc 12 on a purge: hidden");

	/* READ on the owner, the purge's UPDATE ask answered with an odd code. */
	{
		static const PROF q[] = { { "TSTF.", ACC_READ } };
		STUB s2;
		JWN_CTX c2;

		memset(&s2, 0, sizeof(s2));
		s2.prof = q;
		s2.nprof = 1;
		ctx_set(&c2, &s2, "TSTA", NULL);
		CHECK_EQ(jwn_level(&c2, "TSTF.JOB.JOB1", 0, &r), JWN_LV_READ,
			 "jwn_level READ");
		CHECK_EQ(jwn_level(&c2, "TSTF.JOB.JOB1", 1, &r), JWN_LV_READ,
			 "jwn_level READ when UPDATE is refused");
	}

	/* An ownerless job is never "mine": it goes through RACF. */
	{
		static const PROF q[] = { { ".", ACC_READ } };
		STUB s2;
		JWN_CTX c2;

		memset(&s2, 0, sizeof(s2));
		s2.prof = q;
		s2.nprof = 1;
		ctx_set(&c2, &s2, "TSTA", NULL);
		CHECK_EQ(decide(&c2, JWN_OP_READ, "", "STC", "STC00001", &r),
			 JWN_ALLOW, "an ownerless job follows its profile");
		CHECK(strcmp(s2.last, ".STC.STC00001") == 0,
		      "with the owner part empty");
		s2.nprof = 0;
		CHECK_EQ(decide(&c2, JWN_OP_READ, "", "STC", "STC00001", &r),
			 JWN_HIDE, "and is hidden without one");
		CHECK_EQ(decide(&c2, JWN_OP_READ, NULL, "STC", "STC00001", &r),
			 JWN_HIDE, "a NULL owner is no owner");
	}
}

/* ---- closed by default ----------------------------------------------- */

static void
test_closed(void)
{
	static const PROF p[] = { { "", ACC_UPDATE } };   /* RDEF * UACC(UPDATE) */
	STUB s;
	JWN_CTX c;
	JWN_RES r;

	printf("\n--- #440: closed by default ---\n");

	memset(&s, 0, sizeof(s));
	s.prof = p;
	s.nprof = 1;

	ctx_set(&c, &s, "TSTA", NULL);
	c.acee_present = 0;
	CHECK_EQ(decide(&c, JWN_OP_LIST, "TSTA", "JOB", "JOB1", &r), JWN_HIDE,
		 "no ACEE: even the own job is hidden");
	CHECK_EQ(r.reason, JWN_R_NOACEE, "reason NOACEE");
	CHECK_EQ(decide(&c, JWN_OP_LIST, "TSTB", "JOB", "JOB1", &r), JWN_HIDE,
		 "no ACEE: a foreign job is hidden");
	CHECK_EQ(s.calls, 0, "no ACEE: RACF is not asked");

	ctx_set(&c, &s, "", NULL);
	CHECK_EQ(decide(&c, JWN_OP_LIST, "", "JOB", "JOB1", &r), JWN_HIDE,
		 "no userid: nothing is shown, not even an ownerless job");
	ctx_set(&c, &s, NULL, NULL);
	CHECK_EQ(decide(&c, JWN_OP_LIST, "TSTB", "JOB", "JOB1", &r), JWN_HIDE,
		 "NULL userid: nothing is shown");

	ctx_set(&c, &s, "TSTA", NULL);
	c.auth_fn = NULL;
	CHECK_EQ(decide(&c, JWN_OP_LIST, "TSTB", "JOB", "JOB1", &r), JWN_HIDE,
		 "no RACF function: a foreign job is hidden");
	CHECK_EQ(decide(&c, JWN_OP_LIST, "TSTA", "JOB", "JOB1", &r), JWN_ALLOW,
		 "no RACF function: the own job stays");

	CHECK_EQ(jwn_check(NULL, JWN_OP_LIST, "TSTA", "JOB", "JOB1", &r),
		 JWN_HIDE, "NULL context: hidden");
	CHECK_EQ(jwn_check(&c, JWN_OP_LIST, "TSTA", "JOB", "JOB1", NULL),
		 JWN_HIDE, "NULL result: hidden");

	/* bad name parts never reach RACF, however open the class is */
	ctx_set(&c, &s, "TSTA", NULL);
	CHECK_EQ(decide(&c, JWN_OP_LIST, "TSTB", "A.B", "JOB1", &r), JWN_HIDE,
		 "dot in the job name: hidden");
	CHECK_EQ(r.reason, JWN_R_ERR_COMPONENT, "reason ERR_COMPONENT");
	CHECK_EQ(decide(&c, JWN_OP_LIST, "TSTB", "JOB", "JOB1\n", &r), JWN_HIDE,
		 "control character in the job id: hidden");
	CHECK_EQ(decide(&c, JWN_OP_LIST, "TSTB", "JOB", "JOB*", &r), JWN_HIDE,
		 "wildcard in the job id: hidden");
	CHECK_EQ(decide(&c, JWN_OP_LIST, "TSTBTSTBX", "JOB", "JOB1", &r),
		 JWN_HIDE, "nine-character owner: hidden");
	CHECK_EQ(decide(&c, JWN_OP_LIST, "tstb", "JOB", "JOB1", &r), JWN_HIDE,
		 "lower case owner: hidden");
	CHECK_EQ(s.calls, 0, "RACF was not asked about any of them");
}

/* ---- cache ----------------------------------------------------------- */

static void
test_cache(void)
{
	static const PROF p[] = {
		{ "TSTB.",    ACC_READ },
		{ "TSTCLONG", ACC_UPDATE },
	};
	STUB s;
	JWN_CTX c;
	JWN_CACHE cache;
	JWN_RES r;
	int i;
	char jn[16];

	printf("\n--- #440: one answer per key and request ---\n");

	memset(&s, 0, sizeof(s));
	s.prof = p;
	s.nprof = 2;
	jwn_cache_init(&cache);
	ctx_set(&c, &s, "TSTA", &cache);

	decide(&c, JWN_OP_LIST, "TSTB", "JOB", "JOB1", &r);
	decide(&c, JWN_OP_LIST, "TSTB", "JOB", "JOB1", &r);
	CHECK_EQ(s.calls, 1, "the same entity is asked once");
	CHECK_EQ(r.racf_calls, 0, "the second answer came from the cache");
	CHECK_EQ(r.rc, 0, "with its rc");
	CHECK_EQ(r.decision, JWN_ALLOW, "and its decision");

	decide(&c, JWN_OP_PURGE, "TSTB", "JOB", "JOB1", &r);
	CHECK_EQ(r.decision, JWN_NOPURGE, "a purge is not answered from a list entry");
	CHECK_EQ(s.calls, 3, "it asks READ and UPDATE");
	decide(&c, JWN_OP_PURGE, "TSTB", "JOB", "JOB1", &r);
	CHECK_EQ(s.calls, 3, "then it is cached too");

	/* RAKF compares eight characters, so TSTCLONG.A and TSTCLONG.B are one
	   profile -- and so one answer. */
	s.calls = 0;
	decide(&c, JWN_OP_LIST, "TSTCLONG", "AAA", "JOB1", &r);
	decide(&c, JWN_OP_LIST, "TSTCLONG", "BBB", "JOB2", &r);
	CHECK_EQ(s.calls, 1, "two jobs of one eight-character owner: one call");

	/* a full cache is still correct, only slower */
	jwn_cache_init(&cache);
	s.calls = 0;
	for (i = 0; i < JWN_CACHEMAX + 4; i++) {
		snprintf(jn, sizeof(jn), "OWN%02d", i);
		decide(&c, JWN_OP_LIST, jn, "JOB", "JOB1", &r);
		CHECK_EQ(r.decision, JWN_HIDE, "an unprotected owner is hidden");
	}
	CHECK_EQ(cache.n, JWN_CACHEMAX, "the cache stops at its size");
	s.calls = 0;
	decide(&c, JWN_OP_LIST, "OWN19", "JOB", "JOB1", &r);
	decide(&c, JWN_OP_LIST, "OWN19", "JOB", "JOB1", &r);
	CHECK_EQ(s.calls, 2, "a key past the cache size is asked each time");

	/* an unusable answer is not remembered */
	{
		static const PROF q[] = { { "TSTE.", ACC_RC12 } };
		STUB s2;
		JWN_CTX c2;
		JWN_CACHE cache2;

		memset(&s2, 0, sizeof(s2));
		s2.prof = q;
		s2.nprof = 1;
		jwn_cache_init(&cache2);
		ctx_set(&c2, &s2, "TSTA", &cache2);
		decide(&c2, JWN_OP_LIST, "TSTE", "JOB", "JOB1", &r);
		decide(&c2, JWN_OP_LIST, "TSTE", "JOB", "JOB1", &r);
		CHECK_EQ(s2.calls, 2, "an error answer is asked again");
		CHECK_EQ(cache2.n, 0, "and not stored");
	}
}

/* ---- the owner filter ------------------------------------------------ */

static void
test_filter(void)
{
	char canon[JWN_PRTSZ];
	char out[JWN_PRTSZ + 4];

	printf("\n--- #440: owner filter ---\n");

	CHECK_EQ(jwn_narrows("TSTA", "", canon, sizeof(canon)), JWN_NR_RESET,
		 "empty resets");
	CHECK_EQ(jwn_narrows("TSTA", "TSTA", canon, sizeof(canon)), JWN_NR_OWN,
		 "own userid");
	CHECK_EQ(jwn_narrows("TSTA", "tsta", canon, sizeof(canon)), JWN_NR_OWN,
		 "own userid in lower case");
	CHECK(strcmp(canon, "TSTA") == 0, "is returned in upper case");
	CHECK_EQ(jwn_narrows("TSTA", "*", canon, sizeof(canon)), JWN_NR_ALL,
		 "star is ALL");
	CHECK_EQ(jwn_narrows("TSTA", "tstb", canon, sizeof(canon)), JWN_NR_OTHER,
		 "a foreign userid");
	CHECK(strcmp(canon, "TSTB") == 0, "upper-cased");
	CHECK_EQ(jwn_narrows("TSTA", "TST*", canon, sizeof(canon)), JWN_NR_BAD,
		 "a prefix pattern is not supported");
	CHECK_EQ(canon[0], '\0', "and canon stays empty");
	CHECK_EQ(jwn_narrows("TSTA", "**", canon, sizeof(canon)), JWN_NR_BAD,
		 "two stars are not one");
	CHECK_EQ(jwn_narrows("TSTA", "TSTA ", canon, sizeof(canon)), JWN_NR_BAD,
		 "a trailing blank is not a userid");
	CHECK_EQ(jwn_narrows("TSTA", "A.B", canon, sizeof(canon)), JWN_NR_BAD,
		 "a dot is not a userid");
	CHECK_EQ(jwn_narrows("TSTA", "ABCDEFGHI", canon, sizeof(canon)),
		 JWN_NR_BAD, "nine characters are not a userid");
	CHECK_EQ(jwn_narrows("TSTA", NULL, canon, sizeof(canon)), JWN_NR_BAD,
		 "NULL is bad");
	CHECK_EQ(jwn_narrows("TSTA", "TSTB", canon, 4), JWN_NR_BAD,
		 "a small canon buffer is bad");
	CHECK_EQ(jwn_narrows("", "TSTB", canon, sizeof(canon)), JWN_NR_OTHER,
		 "with no user nothing is own");
	CHECK_EQ(jwn_narrows("TSTA", "TSTA10", canon, sizeof(canon)),
		 JWN_NR_OTHER, "TSTA10 is not TSTA");

	CHECK_EQ(jwn_match("*", "TSTB"), 1, "star shows every owner");
	CHECK_EQ(jwn_match("*", ""), 1, "star shows even an empty owner");
	CHECK_EQ(jwn_match("TSTB", "TSTB"), 1, "exact owner");
	CHECK_EQ(jwn_match("TSTB", "TSTBX"), 0, "no prefix: pattern shorter");
	CHECK_EQ(jwn_match("TSTBX", "TSTB"), 0, "no prefix: owner shorter");
	CHECK_EQ(jwn_match("TST", "TSTB"), 0, "TST does not show TSTB");
	CHECK_EQ(jwn_match("TSTB", ""), 0, "an empty owner is nobody's");
	CHECK_EQ(jwn_match("", "TSTB"), 0, "an empty pattern shows nothing");
	CHECK_EQ(jwn_match("TST*", "TSTB"), 0, "a wildcard is not a pattern");
	CHECK_EQ(jwn_match(NULL, "TSTB"), 0, "NULL pattern shows nothing");

	printf("\n--- #440: output ---\n");

	jwn_printable(out, sizeof(out), "TSTB");
	CHECK(strcmp(out, "TSTB") == 0, "a clean name is copied");
	jwn_printable(out, sizeof(out), "A\"B\\C\n");
	CHECK(strcmp(out, "A?B?C?") == 0, "quote, backslash and newline go");
	jwn_printable(out, sizeof(out), "ABCDEFGHIJ");
	CHECK(strcmp(out, "ABCDEFGH") == 0, "at most eight characters");
	jwn_printable(out, 4, "ABCDEFGH");
	CHECK(strcmp(out, "ABC") == 0, "a short buffer is respected");
	jwn_printable(out, sizeof(out), NULL);
	CHECK(out[0] == '\0', "NULL gives an empty string");
	jwn_printable(out, sizeof(out), "ab");
	CHECK(strcmp(out, "??") == 0, "lower case becomes ?");
}

/* ---- the whole story as one table ------------------------------------ */

static void
test_story(void)
{
	/* RDEF * CL(JESSPOOL) UACC(NONE); PE TSTB.* READ; PE * ID(ADMIN) UPDATE */
	static const PROF p[] = {
		{ "TSTB.",    ACC_READ },
		{ "TSTC.",    ACC_NONE },
		{ "SYSTEM.",  ACC_NONE },
	};
	static const struct {
		const char *user, *owner;
		int op, want;
	} t[] = {
		{ "TSTA", "TSTA",   JWN_OP_PURGE, JWN_ALLOW },
		{ "TSTA", "TSTB",   JWN_OP_READ,  JWN_ALLOW },
		{ "TSTA", "TSTB",   JWN_OP_PURGE, JWN_NOPURGE },
		{ "TSTA", "TSTC",   JWN_OP_READ,  JWN_HIDE },
		{ "TSTA", "SYSTEM", JWN_OP_READ,  JWN_HIDE },
		{ "TSTA", "TSTX",   JWN_OP_READ,  JWN_HIDE },
		{ "TSTB", "TSTA",   JWN_OP_READ,  JWN_HIDE },
		{ "TSTB", "TSTB",   JWN_OP_PURGE, JWN_ALLOW },
	};
	size_t i;

	printf("\n--- #440: a small installation ---\n");

	for (i = 0; i < sizeof(t) / sizeof(t[0]); i++) {
		STUB s;
		JWN_CTX c;
		JWN_RES r;

		memset(&s, 0, sizeof(s));
		s.prof = p;
		s.nprof = 3;
		ctx_set(&c, &s, t[i].user, NULL);
		snprintf(msg, sizeof(msg), "%s on %s's job, op %d", t[i].user, t[i].owner,
			t[i].op);
		CHECK_EQ(decide(&c, t[i].op, t[i].owner, "JOB", "JOB00001", &r),
			 t[i].want, msg);
	}
}

int
main(void)
{
	test_components();
	test_mine();
	test_foreign();
	test_closed();
	test_cache();
	test_filter();
	test_story();

	return mbt_test_summary("TSTJWN");
}
