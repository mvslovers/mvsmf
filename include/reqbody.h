#ifndef REQBODY_H
#define REQBODY_H

#include <stddef.h>

/**
 * @file reqbody.h
 * @brief Reading a request body into one buffer (issue #412).
 *
 * A body with a Content-Length is allocated once, at its exact size. It used
 * to start at 4 KB and double: a 72 KB body asked for one contiguous 128 KB
 * block while the 64 KB one was still held, so a region with no 128 KB hole
 * failed a body it had room for -- 69 KB went through and 72 KB did not.
 *
 * A failure that is the server's, not the request's, is drained: the rest of
 * the body is read and thrown away before the caller answers. Closing a socket
 * with unread data makes TCP send a reset, and the reset takes the answer with
 * it, so the client saw "connection closed without response" where a 500 had
 * been sent.
 *
 * ====================================================================
 * The reader lives here, apart from common.c, so the host test can drive
 * the real one. Its services -- the socket read, the allocator, the
 * console report and the chunk-size translation -- are injected through
 * BODY_OPS, so this TU is portable C with no httpd session headers.
 * common.c supplies the real ops; the test supplies scripted ones (see
 * test/host/tstbody.c).
 * ====================================================================
 */

/** @brief The body was read; *content holds it, NUL-terminated. */
#define REQBODY_OK          0

/**
 * @brief The request's fault: no Content-Length and not chunked, a malformed
 *        length, or a client that stopped sending. Answer 400.
 */
#define REQBODY_BAD         (-1)

/**
 * @brief No storage for the body. The body has been drained (as far as the
 *        client sent it), so an answer reaches the client. Answer 500.
 */
#define REQBODY_NOMEM       (-2)

/**
 * @brief The declared length can never be held: it is at least the whole
 *        24-bit address space. Nothing was read. Answer 413.
 */
#define REQBODY_TOO_LARGE   (-3)

/**
 * @brief The smallest length answered REQBODY_TOO_LARGE: 16 MB, all of 24-bit
 *        storage. Anything below it is attempted and fails, if it fails, as
 *        REQBODY_NOMEM -- the storage decides, not a guess at a limit.
 */
#define REQBODY_MAX         0x01000000UL

/**
 * @brief The services the reader needs.
 *
 * Every member is required. The instance is read-only -- keep it
 * `static const` in the caller, since MVSMF is link-edited RENT and a
 * writable static would S0C4.
 */
typedef struct body_ops {
	/**
	 * Read up to @p len bytes into @p buf, waiting for a slow client.
	 * Returns the number read (fewer only when the client closed), or
	 * <= 0 when nothing more will come.
	 */
	int   (*recv)(void *ctx, char *buf, int len);

	/** malloc(): the body buffer the caller later free()s. */
	void *(*alloc)(void *ctx, size_t size);

	/** realloc(), for a chunked body. */
	void *(*resize)(void *ctx, void *ptr, size_t size);

	/** free(). */
	void  (*release)(void *ctx, void *ptr);

	/** Report a failed allocation to the operator, once per request. */
	void  (*nomem)(void *ctx);

	/** Translate a chunk-size line, as received, to the native code page. */
	void  (*atoe)(void *ctx, char *buf, int len);
} BODY_OPS;

/**
 * @brief Read the whole request body.
 *
 * @param ctx            Opaque context handed to every op.
 * @param ops            Service table; must be fully populated.
 * @param content_length The Content-Length header value, or NULL.
 * @param chunked        Non-zero for Transfer-Encoding: chunked, which wins
 *                       over a Content-Length.
 * @param content        Out: the body, NUL-terminated; NULL on failure.
 * @param content_size   Out: its length, without the NUL.
 * @return REQBODY_OK, or one of the negative REQBODY_* codes.
 */
int read_body(void *ctx, const BODY_OPS *ops, const char *content_length,
	int chunked, char **content, size_t *content_size) asm("RBD0001");

#endif /* REQBODY_H */
