#ifndef USSREAD_H
#define USSREAD_H

/**
 * @file ussread.h
 * @brief The read-translate-send loop of the USS file GET (issue #423).
 *
 * ussGetHandler streams a file in fixed-size pieces after the status line is
 * already on the wire. How that loop ENDS is the whole point of this unit: a
 * read that fails part-way stops the loop exactly as the end of the file does,
 * and the only difference is a flag on the file handle that nobody looked at.
 * The reply then ended as a complete-looking 200 with a truncated body.
 *
 * The loop lives here, apart from ussapi.c, so the host test can drive the
 * real one: ussapi.c pulls in the httpd session headers and libufs, neither of
 * which exists on the host. The four services it needs are injected through
 * USS_READ_OPS; ussapi.c supplies the real ones, the test scripted ones (see
 * test/host/tstussrd.c).
 */

/**
 * @brief The services the loop needs.
 *
 * Every member except @c xlate is required. The instance is read-only -- keep
 * it `static const` in the caller, since MVSMF is link-edited RENT and a
 * writable static would S0C4.
 */
typedef struct uss_read_ops {
	/** Read up to @p len bytes; returns the number read, 0 at end or on error. */
	unsigned (*read)(void *ctx, void *buf, unsigned len);

	/** Send @p len bytes; negative when they could not be delivered. */
	int      (*send)(void *ctx, const unsigned char *buf, int len);

	/** Translate @p len bytes in place; NULL for a binary transfer. */
	void     (*xlate)(void *ctx, unsigned char *buf, unsigned len);

	/**
	 * Asked once, when read() has returned 0. Returns 0 when the read stopped
	 * at the end of the file, otherwise the UFSD return code (never 0) of the
	 * failure that stopped it.
	 */
	int      (*failed)(void *ctx);
} USS_READ_OPS;

/**
 * @brief Stream a file to the client, or say why it stopped short.
 *
 * @param ctx      Opaque context handed to every op.
 * @param ops      Service table.
 * @param buf      Work buffer.
 * @param bufsz    Size of @p buf.
 * @param read_rc  Out: 0, or the UFSD return code of a read that failed. A
 *                 caller that sees non-zero must not let the reply end
 *                 cleanly -- the status is gone, the connection is what is
 *                 left to say so (abort_response()).
 * @return 0 when the whole file was sent, -1 when it was not (a send that
 *         failed, or a read that failed -- tell them apart by @p read_rc).
 */
int uss_stream_file(void *ctx, const USS_READ_OPS *ops,
	unsigned char *buf, unsigned bufsz, int *read_rc) asm("USR0001");

#endif /* USSREAD_H */
