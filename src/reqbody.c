/*
 * reqbody.c - reading a request body into one buffer (issue #412).
 *
 * See include/reqbody.h for why a Content-Length body is allocated once and
 * why a failure the server caused drains the body before anyone answers.
 *
 * Portable C on purpose: no httpd headers, no MVS services, no statics. The
 * host test #includes it (test/host/tstbody.c) so the reader it drives is the
 * one that runs on MVS, not a copy of it.
 */

#include <stdlib.h>
#include <string.h>

#include "reqbody.h"

/* Chunk-size line: up to 9 hex digits and the CR. A longer line is refused,
   not read past -- that covers chunk extensions too, which no client of
   ours sends. */
#define CHUNK_LINE_MAX  10

/* Drain scratch: on the stack, so a drain needs no storage -- it runs
   precisely when there is none. */
#define DRAIN_BUF       256

/*
 * Parse a Content-Length: decimal digits, blanks allowed around them.
 * Accumulation stops at REQBODY_MAX, so no value can wrap.
 */
#ifdef __MVS__
__asm__("\n&FUNC    SETC 'parse_length'");
#endif
static int
parse_length(const char *s, size_t *out)
{
	unsigned long v = 0;
	int digits = 0;

	while (*s == ' ') {
		s++;
	}
	while (*s >= '0' && *s <= '9') {
		if (v < REQBODY_MAX) {
			v = v * 10 + (unsigned long)(*s - '0');
		}
		digits++;
		s++;
	}
	while (*s == ' ') {
		s++;
	}

	if (digits == 0 || *s != '\0') {
		return REQBODY_BAD;
	}
	if (v >= REQBODY_MAX) {
		return REQBODY_TOO_LARGE;
	}

	*out = (size_t)v;
	return REQBODY_OK;
}

/* Read and discard n bytes. -1 when the client stops before. */
#ifdef __MVS__
__asm__("\n&FUNC    SETC 'drain'");
#endif
static int
drain(void *ctx, const BODY_OPS *ops, size_t n)
{
	char scratch[DRAIN_BUF];

	while (n > 0) {
		int want = n < sizeof(scratch) ? (int)n : (int)sizeof(scratch);
		int got = ops->recv(ctx, scratch, want);

		if (got <= 0) {
			return -1;
		}
		n -= (size_t)got;
	}

	return 0;
}

/* Read exactly n bytes into buf. -1 when the client stops before. */
#ifdef __MVS__
__asm__("\n&FUNC    SETC 'read_exact'");
#endif
static int
read_exact(void *ctx, const BODY_OPS *ops, char *buf, size_t n)
{
	size_t pos = 0;

	while (pos < n) {
		int got = ops->recv(ctx, buf + pos, (int)(n - pos));

		if (got <= 0) {
			return -1;
		}
		pos += (size_t)got;
	}

	return 0;
}

#ifdef __MVS__
__asm__("\n&FUNC    SETC 'read_length'");
#endif
static int
read_length(void *ctx, const BODY_OPS *ops, const char *content_length,
	char **content, size_t *content_size)
{
	size_t len = 0;
	char *buf;
	int rc;

	rc = parse_length(content_length, &len);
	if (rc != REQBODY_OK) {
		return rc;      /* nothing read: a 413 closes the connection */
	}

	/* Once, at its size. Doubling held the old block while asking for one
	   twice its size, so a 72 KB body needed a 128 KB hole (#412). */
	buf = ops->alloc(ctx, len + 1);
	if (!buf) {
		ops->nomem(ctx);
		(void)drain(ctx, ops, len);
		return REQBODY_NOMEM;
	}

	if (read_exact(ctx, ops, buf, len) < 0) {
		ops->release(ctx, buf);
		return REQBODY_BAD;
	}

	buf[len] = '\0';
	*content = buf;
	*content_size = len;
	return REQBODY_OK;
}

/*
 * Chunked: the size is not known up front, so the buffer grows by each chunk,
 * to exactly what it holds. Once storage has failed, the rest of the chunks
 * are still parsed and thrown away, so the answer is not reset away either.
 */
#ifdef __MVS__
__asm__("\n&FUNC    SETC 'read_chunked'");
#endif
static int
read_chunked(void *ctx, const BODY_OPS *ops, char **content,
	size_t *content_size)
{
	char *buf = NULL;
	size_t size = 0;
	int nomem = 0;
	int rc = REQBODY_BAD;

	for (;;) {
		char line[CHUNK_LINE_MAX];
		char crlf[2];
		char *end = NULL;
		unsigned long chunk;
		int i = 0;

		/* Chunk-size line, up to its CR; then the LF. */
		for (;;) {
			if (i >= CHUNK_LINE_MAX - 1 ||
					ops->recv(ctx, line + i, 1) != 1) {
				goto fail;
			}
			if (line[i] == '\r') {
				break;
			}
			i++;
		}
		line[i] = '\0';
		(void)ops->recv(ctx, crlf, 1);

		ops->atoe(ctx, line, i);
		chunk = strtoul(line, &end, 16);
		if (end == line) {
			goto fail;
		}
		if (chunk >= REQBODY_MAX - size) {
			rc = REQBODY_TOO_LARGE;
			goto fail;
		}

		if (chunk == 0) {
			/* The terminating CRLF (RFC 7230 4.1). Left unread, it makes
			   the close reset the connection, which strict clients (Zowe,
			   Node) report as ECONNRESET. Best effort: the body is complete.
			   Trailers are not expected; no client of ours sends them. */
			(void)ops->recv(ctx, crlf, 2);
			break;
		}

		if (!nomem) {
			char *grown = buf
				? ops->resize(ctx, buf, size + chunk + 1)
				: ops->alloc(ctx, size + chunk + 1);

			if (grown) {
				buf = grown;
			} else {
				ops->nomem(ctx);
				ops->release(ctx, buf);
				buf = NULL;
				nomem = 1;
			}
		}

		if (nomem) {
			if (drain(ctx, ops, chunk) < 0) {
				return REQBODY_NOMEM;
			}
		} else {
			if (read_exact(ctx, ops, buf + size, chunk) < 0) {
				goto fail;
			}
			size += chunk;
		}

		/* The CRLF behind the chunk data. */
		if (ops->recv(ctx, crlf, 2) != 2) {
			if (nomem) {
				return REQBODY_NOMEM;
			}
			goto fail;
		}
	}

	if (nomem) {
		return REQBODY_NOMEM;
	}

	if (!buf) {
		buf = ops->alloc(ctx, 1);   /* an empty body is still a body */
		if (!buf) {
			ops->nomem(ctx);
			return REQBODY_NOMEM;
		}
	}

	buf[size] = '\0';
	*content = buf;
	*content_size = size;
	return REQBODY_OK;

fail:
	if (buf) {
		ops->release(ctx, buf);
	}
	return nomem ? REQBODY_NOMEM : rc;
}

#ifdef __MVS__
__asm__("\n&FUNC    SETC 'read_body'");
#endif
int
read_body(void *ctx, const BODY_OPS *ops, const char *content_length,
	int chunked, char **content, size_t *content_size)
{
	*content = NULL;
	*content_size = 0;

	if (chunked) {
		return read_chunked(ctx, ops, content, content_size);
	}
	if (content_length) {
		return read_length(ctx, ops, content_length, content, content_size);
	}

	return REQBODY_BAD;
}
