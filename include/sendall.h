#ifndef SENDALL_H
#define SENDALL_H

/**
 * @file sendall.h
 * @brief The send loop, and its no-progress policy (issue #298).
 *
 * A send loop written as
 *
 *     for (pos = 0; pos < len; pos += rc)
 *         rc = http_send(httpc, &buf[pos], len - pos);
 *
 * spins forever the moment http_send() returns 0: pos += 0 never reaches len,
 * and the worker issues a send() SVC per turn at 100% CPU. Zero is a legitimate
 * return -- for a non-chunked response httpd's send_raw() reports the bytes it
 * managed this call, which is 0 when the socket send buffer is full
 * (EWOULDBLOCK). It means "no progress, retry", not "error". This is the defect
 * httpd fixed one level down as httpd#199/#201.
 *
 * The policy is the one agreed for the whole ecosystem: on a non-blocking
 * socket the application waits, 100 attempts of 100 ms = 10 s without progress,
 * then abandon. httpd applies it in httpprtv.c and httpsend.c, and the receive
 * side of this file's caller does the same with a different granularity
 * (RAW_RECV_MAX_RETRIES, 200 x 50 ms).
 *
 * ====================================================================
 * The loop lives here, apart from common.c, so the host test can drive
 * the real one. Its four MVS/httpd dependencies -- the send, the pause,
 * the "client is gone or the server is stopping" test and the give-up
 * action -- are injected through SEND_OPS, so this TU is portable C with
 * no httpd session headers. common.c supplies the real ops; the test
 * supplies scripted ones (see test/host/tstsend.c).
 * ====================================================================
 */

/** @brief Consecutive no-progress sends tolerated before giving up. */
#define SEND_STALL_MAX      100

/**
 * @brief Pause between no-progress retries, in .01s units for
 *        cthread_timed_wait() -- 10 = 100 ms.
 *
 * NOTE the unit. httpd spells the same policy SEND_STALL_PAUSE 100000,
 * microseconds for usleep(). Both are 100 ms, and 100 x 100 ms = 10 s is the
 * budget shared by httpd, mvsMF and ftpd.
 */
#define SEND_STALL_PAUSE    10

/**
 * @brief The external services the send loop needs.
 *
 * Every member is required; send_bytes() does not test them for NULL.
 * The instance is read-only -- keep it `static const` in the caller, since
 * MVSMF is link-edited RENT and a writable static would S0C4.
 */
typedef struct send_ops {
	/**
	 * Send up to @p len bytes. Returns the number sent (may be short),
	 * 0 for "no progress, retry later", or negative on a dead socket.
	 */
	int  (*send)(void *ctx, const unsigned char *buf, int len);

	/** Pause one retry interval (SEND_STALL_PAUSE). */
	void (*pause)(void *ctx);

	/**
	 * Non-zero when no further progress is possible at all: the client is
	 * already finished or dead, or the server is quiescing/shutting down.
	 * Polled on every no-progress turn, never cached -- a stopping server
	 * must not sit out the stall budget in each of its workers.
	 */
	int  (*aborted)(void *ctx);

	/**
	 * Called once when the stall budget runs out, with the number of
	 * consecutive no-progress sends. Reports it; the failure itself is the
	 * caller's to act on. Not called for a dead socket or for @c aborted --
	 * those are expected events with nothing for an operator to do.
	 */
	void (*giveup)(void *ctx, int stall);
} SEND_OPS;

/**
 * @brief Send the whole buffer, or fail.
 *
 * Short writes are resumed, no-progress returns are paused and retried within
 * the budget, and the position is never advanced by zero.
 *
 * @param ctx  Opaque context handed to every op.
 * @param ops  Service table; must be fully populated.
 * @param buf  Bytes to send, already in the encoding the client expects.
 * @param len  Number of bytes; <= 0 is success with nothing sent.
 * @return 0 when everything was sent, -1 otherwise.
 */
int send_bytes(void *ctx, const SEND_OPS *ops,
	const unsigned char *buf, int len) asm("SND0001");

#endif /* SENDALL_H */
