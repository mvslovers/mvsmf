/*
 * tstbody.c - #412 regression: a request body is allocated once, at its size,
 * and a failure the server caused still reaches the client.
 *
 * read_request_content() started a Content-Length body at 4 KB and doubled
 * it: 4, 8, 16, 32, 64, 128 KB. A 72 KB body needed one contiguous 128 KB
 * block while the 64 KB one was still held, so a fragmented region failed it
 * -- measured, 69 KB went through and 72 KB did not. And when it failed, the
 * handler's 400 was lost: about 70 KB of the body was still unread, and
 * closing a socket with unread data makes TCP send a reset. The client saw
 * "connection closed without response".
 *
 * ====================================================================
 * This test drives the REAL reader: src/reqbody.c is #included below.
 * common.c cannot compile on the host (it pulls in the httpd session
 * headers), which is why the reader lives in its own TU with its
 * services injected through BODY_OPS.
 * ====================================================================
 *
 * Runs on host via `mbt test`.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <mbtcheck.h>

#include "../../src/reqbody.c"

static char msg[160];

/*
 * A client and an allocator in one. The client is a byte stream read from
 * the front; the allocator records every request and fails the fail_at-th one
 * (0-based, across alloc and resize; -1 = never).
 */
struct env {
	const char *data;
	size_t      len;
	size_t      pos;          /* bytes the reader consumed */

	int         fail_at;
	int         calls;        /* alloc + resize calls */
	int         allocs;
	int         resizes;
	int         nomems;       /* nomem() reports */
	size_t      largest;      /* largest single request */
	long        live;         /* blocks currently held */
};

static int
op_recv(void *ctx, char *buf, int len)
{
	struct env *e = (struct env *)ctx;
	size_t n = e->len - e->pos;

	if ((size_t)len < n) {
		n = (size_t)len;
	}
	memcpy(buf, e->data + e->pos, n);
	e->pos += n;
	return (int)n;
}

static void *
op_alloc(void *ctx, size_t size)
{
	struct env *e = (struct env *)ctx;
	void *p;

	if (e->calls++ == e->fail_at) {
		return NULL;
	}
	e->allocs++;
	if (size > e->largest) {
		e->largest = size;
	}
	p = malloc(size);
	if (p) {
		e->live++;
	}
	return p;
}

static void *
op_resize(void *ctx, void *ptr, size_t size)
{
	struct env *e = (struct env *)ctx;

	if (e->calls++ == e->fail_at) {
		return NULL;
	}
	e->resizes++;
	if (size > e->largest) {
		e->largest = size;
	}
	return realloc(ptr, size);
}

static void
op_release(void *ctx, void *ptr)
{
	struct env *e = (struct env *)ctx;

	if (ptr) {
		e->live--;
	}
	free(ptr);
}

static void
op_nomem(void *ctx)
{
	((struct env *)ctx)->nomems++;
}

static void
op_atoe(void *ctx, char *buf, int len)
{
	(void)ctx;      /* the host is ASCII: the line is native already */
	(void)buf;
	(void)len;
}

static const BODY_OPS ops = {
	op_recv, op_alloc, op_resize, op_release, op_nomem, op_atoe
};

static void
env_init(struct env *e, const char *data, size_t len)
{
	memset(e, 0, sizeof(*e));
	e->data = data;
	e->len = len;
	e->fail_at = -1;
}

static void
done(struct env *e, char *content)
{
	if (content) {
		op_release(e, content);
	}
}

#define BIG 73728       /* 72 KB: the size that failed in #412 */

static char big[BIG];

/* --- Content-Length ------------------------------------------------------ */

static void
test_exact_size(void)
{
	struct env e;
	char *content = NULL;
	size_t size = 0;
	int rc;

	env_init(&e, big, BIG);
	rc = read_body(&e, &ops, "73728", 0, &content, &size);

	CHECK_EQ(rc, REQBODY_OK, "72 KB body is read");
	CHECK_EQ((long)size, (long)BIG, "all of it");
	CHECK(content && memcmp(content, big, BIG) == 0, "byte for byte");
	CHECK(content && content[BIG] == '\0', "and NUL-terminated");

	snprintf(msg, sizeof(msg), "one allocation (got %d) and no resize (got %d)",
		e.allocs, e.resizes);
	CHECK(e.allocs == 1 && e.resizes == 0, msg);
	snprintf(msg, sizeof(msg),
		"largest request is the body + 1 = %d, never 128 KB (got %lu)",
		BIG + 1, (unsigned long)e.largest);
	CHECK(e.largest == BIG + 1, msg);

	done(&e, content);
	CHECK_EQ(e.live, 0L, "nothing leaked");
}

static void
test_nomem_drains(void)
{
	struct env e;
	char *content = (char *)1;
	size_t size = 0;
	int rc;

	env_init(&e, big, BIG);
	e.fail_at = 0;
	rc = read_body(&e, &ops, "73728", 0, &content, &size);

	CHECK_EQ(rc, REQBODY_NOMEM, "no storage is NOMEM, not the request's fault");
	CHECK(content == NULL, "no buffer handed out");
	snprintf(msg, sizeof(msg),
		"the body is drained, so the answer is not reset away (%lu of %d)",
		(unsigned long)e.pos, BIG);
	CHECK(e.pos == BIG, msg);
	CHECK_EQ(e.nomems, 1, "reported to the operator once");
	CHECK_EQ(e.live, 0L, "nothing leaked");
}

static void
test_too_large(void)
{
	struct env e;
	char *content = NULL;
	size_t size = 0;

	env_init(&e, big, BIG);
	CHECK_EQ(read_body(&e, &ops, "16777216", 0, &content, &size),
		REQBODY_TOO_LARGE, "16 MB cannot be held in 24-bit storage");
	CHECK(e.pos == 0 && e.calls == 0, "nothing read, nothing allocated");

	env_init(&e, big, BIG);
	CHECK_EQ(read_body(&e, &ops, "99999999999999999999999", 0, &content, &size),
		REQBODY_TOO_LARGE, "a length past ULONG_MAX does not wrap");
	CHECK(e.calls == 0, "and allocates nothing");

	env_init(&e, big, BIG);
#ifdef __MVS__
	/* No region holds 16 MB below the line: the request is made and the
	   storage refuses it, which is the point of the length check. */
	CHECK_EQ(read_body(&e, &ops, "16777215", 0, &content, &size),
		REQBODY_NOMEM, "16 MB - 1 is attempted, and 24-bit storage refuses");
	CHECK(e.calls == 1 && e.nomems == 1,
		"the storage decides, not a limit below 16 MB");
#else
	CHECK_EQ(read_body(&e, &ops, "16777215", 0, &content, &size),
		REQBODY_BAD, "16 MB - 1 is attempted, and the client sent less");
	CHECK(e.allocs == 1 && e.largest == 16777216UL,
		"the storage decides, not a limit below 16 MB");
#endif
	done(&e, content);
	CHECK_EQ(e.live, 0L, "nothing leaked");
}

static void
test_bad_length(void)
{
	static const char *const bad[] = { "", "12a", "-5", "0x10", " " };
	struct env e;
	char *content = NULL;
	size_t size = 0;
	unsigned i;

	for (i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
		env_init(&e, big, BIG);
		snprintf(msg, sizeof(msg), "Content-Length \"%s\" is BAD", bad[i]);
		CHECK_EQ(read_body(&e, &ops, bad[i], 0, &content, &size),
			REQBODY_BAD, msg);
		CHECK(e.calls == 0, "and allocates nothing");
	}

	env_init(&e, "hello", 5);
	CHECK_EQ(read_body(&e, &ops, " 5 ", 0, &content, &size), REQBODY_OK,
		"blanks around the digits are allowed");
	CHECK(content && strcmp(content, "hello") == 0, "and the body is read");
	done(&e, content);

	env_init(&e, big, BIG);
	CHECK_EQ(read_body(&e, &ops, NULL, 0, &content, &size), REQBODY_BAD,
		"no length and not chunked is BAD");
}

static void
test_short_body(void)
{
	struct env e;
	char *content = NULL;
	size_t size = 0;

	env_init(&e, big, 40);
	CHECK_EQ(read_body(&e, &ops, "100", 0, &content, &size), REQBODY_BAD,
		"a client that stops early is BAD");
	CHECK(content == NULL, "no buffer handed out");
	CHECK_EQ(e.live, 0L, "nothing leaked");
}

static void
test_empty(void)
{
	struct env e;
	char *content = NULL;
	size_t size = 99;

	env_init(&e, "", 0);
	CHECK_EQ(read_body(&e, &ops, "0", 0, &content, &size), REQBODY_OK,
		"an empty body is a body");
	CHECK(content && content[0] == '\0' && size == 0, "empty and terminated");
	done(&e, content);
	CHECK_EQ(e.live, 0L, "nothing leaked");
}

/* --- chunked ------------------------------------------------------------- */

static const char chunked[] = "5\r\nhello\r\n3\r\nabc\r\n0\r\n\r\n";

static void
test_chunked(void)
{
	struct env e;
	char *content = NULL;
	size_t size = 0;

	env_init(&e, chunked, sizeof(chunked) - 1);
	CHECK_EQ(read_body(&e, &ops, "999", 1, &content, &size), REQBODY_OK,
		"chunked wins over a Content-Length");
	CHECK(content && strcmp(content, "helloabc") == 0 && size == 8,
		"chunks are joined");
	CHECK(e.pos == sizeof(chunked) - 1, "the terminating CRLF is read too");
	done(&e, content);
	CHECK_EQ(e.live, 0L, "nothing leaked");
}

static void
test_chunked_nomem_drains(void)
{
	struct env e;
	char *content = (char *)1;
	size_t size = 0;
	int rc;

	env_init(&e, chunked, sizeof(chunked) - 1);
	e.fail_at = 1;          /* the second chunk's storage */
	rc = read_body(&e, &ops, NULL, 1, &content, &size);

	CHECK_EQ(rc, REQBODY_NOMEM, "chunked: no storage is NOMEM");
	CHECK(content == NULL, "no buffer handed out");
	snprintf(msg, sizeof(msg), "the rest of the chunks is drained (%lu of %lu)",
		(unsigned long)e.pos, (unsigned long)(sizeof(chunked) - 1));
	CHECK(e.pos == sizeof(chunked) - 1, msg);
	CHECK_EQ(e.nomems, 1, "reported once");
	CHECK_EQ(e.live, 0L, "nothing leaked");
}

static void
test_chunked_bad(void)
{
	static const char huge[] = "FFFFFFFF\r\n";
	static const char noeol[] = "123456789abcdef";
	struct env e;
	char *content = NULL;
	size_t size = 0;

	env_init(&e, huge, sizeof(huge) - 1);
	CHECK_EQ(read_body(&e, &ops, NULL, 1, &content, &size), REQBODY_TOO_LARGE,
		"a 4 GB chunk is TOO_LARGE, not a negative int");
	CHECK_EQ(e.live, 0L, "nothing leaked");

	env_init(&e, noeol, sizeof(noeol) - 1);
	CHECK_EQ(read_body(&e, &ops, NULL, 1, &content, &size), REQBODY_BAD,
		"a chunk-size line with no CR is BAD");
	CHECK_EQ(e.live, 0L, "nothing leaked");
}

int
main(void)
{
	unsigned i;

	for (i = 0; i < BIG; i++) {
		big[i] = (char)('A' + i % 26);
	}

	test_exact_size();
	test_nomem_drains();
	test_too_large();
	test_bad_length();
	test_short_body();
	test_empty();
	test_chunked();
	test_chunked_nomem_drains();
	test_chunked_bad();

	return mbt_test_summary("TSTBODY");
}
