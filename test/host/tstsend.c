/*
 * tstsend.c - #298 regression: the send loop must never advance by zero.
 *
 * mvsMF sent every response with
 *
 *     for (pos = 0; pos < len; pos += rc)
 *         rc = http_send(session->httpc, &buf[pos], len - pos);
 *
 * checking only rc < 0. A zero return -- httpd's documented "socket send
 * buffer full, no progress, retry later" -- leaves pos where it was, so the
 * loop never terminates and the worker issues a send() SVC per turn at 100%
 * CPU until the server is restarted. Until the Hercules X'75' fix
 * (mvslovers/hyperion 1a599b0d) a full buffer froze the emulated CPU instead
 * of returning EWOULDBLOCK, which is the only reason this never fired.
 *
 * Every JSON response goes through that loop -- sendJSONResponse() sets
 * Content-Length, so the response is non-chunked, the one mode where
 * http_send() can return 0.
 *
 * ====================================================================
 * This test drives the REAL loop: src/sendall.c is #included below.
 * common.c itself cannot compile on the host (it pulls in the httpd
 * session headers), which is why the loop lives in its own TU with its
 * four MVS/httpd services injected through SEND_OPS.
 * ====================================================================
 *
 * Runs on host via `make test-host`.
 */
#include <stdio.h>
#include <string.h>

#include <mbtcheck.h>

#include "../../src/sendall.c"

static char msg[160];

#define PAYLOAD 64
#define ATTEMPT_CAP 10000   /* far above any legal attempt count */

/*
 * A scripted client. `script` gives the value the n-th send returns, except
 * that a positive entry is capped at the bytes actually left, so a script can
 * say "as much as you like" with a large number. The script's last entry
 * repeats once it runs out, which is how "stalled forever" is expressed.
 */
struct client {
	const int *script;
	int        script_len;
	int        attempts;      /* sends issued */
	int        pauses;        /* pauses taken */
	int        sent;          /* bytes accepted */
	int        aborted;       /* what aborted() reports */
	int        abort_after;   /* start reporting aborted at this attempt */
	int        giveups;       /* giveup() calls */
	int        giveup_stall;  /* stall count it was given */
	unsigned char got[PAYLOAD];
};

static int
op_send(void *ctx, const unsigned char *buf, int len)
{
	struct client *c = (struct client *)ctx;
	int want;

	/* A runaway loop must fail the test, not hang the suite. */
	if (c->attempts >= ATTEMPT_CAP) {
		return -1;
	}

	want = c->script[c->attempts < c->script_len
		? c->attempts : c->script_len - 1];
	c->attempts++;

	if (c->attempts >= c->abort_after) {
		c->aborted = 1;
	}

	if (want <= 0) {
		return want;
	}

	if (want > len) {
		want = len;
	}
	if (c->sent + want > (int)sizeof(c->got)) {
		want = (int)sizeof(c->got) - c->sent;
	}
	memcpy(&c->got[c->sent], buf, want);
	c->sent += want;

	return want;
}

static void
op_pause(void *ctx)
{
	((struct client *)ctx)->pauses++;
}

static int
op_aborted(void *ctx)
{
	return ((struct client *)ctx)->aborted;
}

static void
op_giveup(void *ctx, int stall)
{
	struct client *c = (struct client *)ctx;

	c->giveups++;
	c->giveup_stall = stall;
}

static const SEND_OPS ops = { op_send, op_pause, op_aborted, op_giveup };

/* Run one scripted client over `len` bytes of a known payload. */
static int
run(struct client *c, const int *script, int script_len, int len)
{
	static unsigned char payload[PAYLOAD];
	int i;

	for (i = 0; i < PAYLOAD; i++) {
		payload[i] = (unsigned char)i;
	}

	memset(c, 0, sizeof(*c));
	c->script = script;
	c->script_len = script_len;
	c->abort_after = ATTEMPT_CAP;   /* never, unless the case says so */

	return send_bytes(c, &ops, payload, len);
}

/* The payload the client accepted is the payload it should have accepted. */
static void
check_payload(struct client *c, int len)
{
	int i;

	sprintf(msg, "%d of %d bytes accepted", c->sent, len);
	CHECK_EQ(c->sent, len, msg);

	for (i = 0; i < c->sent; i++) {
		if (c->got[i] != (unsigned char)i) {
			sprintf(msg, "byte %d is 0x%02X, expected 0x%02X",
				i, c->got[i], (unsigned char)i);
			CHECK(0, msg);
			return;
		}
	}
	CHECK(1, "the bytes arrived in order, none dropped or repeated");
}

int
main(void)
{
	struct client c;
	int rc;

	printf("\n--- #298: a zero return must not advance, and must terminate ---\n");
	{
		/* The defect itself: a client that never accepts anything. The old
		   loop spun here forever. */
		const int stalled[] = { 0 };

		rc = run(&c, stalled, 1, PAYLOAD);

		CHECK_EQ(rc, -1, "a client that never drains fails the send");
		CHECK(c.attempts <= SEND_STALL_MAX + 1,
			"the loop gives up inside the budget instead of spinning");
		CHECK_EQ(c.attempts, SEND_STALL_MAX + 1,
			"it spends the whole budget before giving up");
		CHECK_EQ(c.sent, 0, "nothing was sent");
		CHECK_EQ(c.pauses, SEND_STALL_MAX,
			"every no-progress turn paused -- no busy spin");
	}

	printf("\n--- #298: the give-up is reported once, with its count ---\n");
	{
		const int stalled[] = { 0 };

		rc = run(&c, stalled, 1, PAYLOAD);

		CHECK_EQ(rc, -1, "the send failed");
		CHECK_EQ(c.giveups, 1, "MVSMF008W is written exactly once");
		CHECK_EQ(c.giveup_stall, SEND_STALL_MAX + 1,
			"the reported retry count is the one that broke the budget");
	}

	printf("\n--- #298: a short write is resumed, not dropped ---\n");
	{
		/* This is the secondary finding: dsapi.c and ussapi.c used to send
		   a record with a single unchecked call, so a short write lost the
		   remainder. Safe only because those routes happen to be chunked --
		   one Content-Length away from silent truncation. */
		const int dribble[] = { 1, 7, 20, 3, 64 };

		rc = run(&c, dribble, 5, PAYLOAD);

		CHECK_EQ(rc, 0, "a dribbling client still receives everything");
		check_payload(&c, PAYLOAD);
	}

	printf("\n--- #298: progress resets the budget ---\n");
	{
		/* Slow but advancing: SEND_STALL_MAX stalls, one byte, and so on.
		   A budget that did not reset would kill this client at attempt
		   101 even though it is draining. */
		static int slow[2 * SEND_STALL_MAX * 4];
		int i, n = 0;

		for (i = 0; i < 4; i++) {
			int j;
			for (j = 0; j < SEND_STALL_MAX; j++) {
				slow[n++] = 0;
			}
			slow[n++] = 1;
		}
		slow[n - 1] = 1;

		/* four bytes is all this script can deliver, so ask for four */
		rc = run(&c, slow, n, 4);

		CHECK_EQ(rc, 0, "a slow but advancing client is not cut off");
		check_payload(&c, 4);
		CHECK_EQ(c.pauses, 4 * SEND_STALL_MAX,
			"it waited out four full stalls without ever giving up");
	}

	printf("\n--- #298: a dead socket fails at once ---\n");
	{
		const int dead[] = { -1 };

		rc = run(&c, dead, 1, PAYLOAD);

		CHECK_EQ(rc, -1, "a negative return fails the send");
		CHECK_EQ(c.attempts, 1, "no retry -- a dead socket is not retryable");
		CHECK_EQ(c.pauses, 0, "and nothing was waited out");
		CHECK_EQ(c.giveups, 0, "a dead socket is not a stall timeout");
	}

	printf("\n--- #298: a partial send then a dead socket keeps the failure ---\n");
	{
		const int half_then_dead[] = { 32, -1 };

		rc = run(&c, half_then_dead, 2, PAYLOAD);

		CHECK_EQ(rc, -1, "a failure after partial progress still fails");
		CHECK_EQ(c.sent, 32, "the accepted half is not re-sent or rolled back");
	}

	printf("\n--- #298: an already-finished client is not waited for ---\n");
	{
		/* The entry guard. After one send fails the handler's error path
		   comes straight back here through sendErrorResponse(); without
		   this it would pay the whole budget a second time for a peer that
		   is already gone (httpd#203). The same guard covers a quiescing
		   server: P HTTPD waits for its workers, so no worker may sit out
		   10 seconds per response in flight. */
		const int stalled[] = { 0 };

		rc = run(&c, stalled, 1, PAYLOAD);   /* seed the struct */
		CHECK_EQ(rc, -1, "the first send failed as set up");

		memset(&c, 0, sizeof(c));
		c.script = stalled;
		c.script_len = 1;
		c.abort_after = ATTEMPT_CAP;
		c.aborted = 1;

		rc = send_bytes(&c, &ops, (const unsigned char *)"HELLO", 5);

		CHECK_EQ(rc, -1, "a client already at CSTATE_DONE fails the send");
		CHECK_EQ(c.attempts, 0, "and is not even written to");
		CHECK_EQ(c.pauses, 0, "no budget is spent on it");
		CHECK_EQ(c.giveups, 0, "and it is not reported as a stall timeout");
	}

	printf("\n--- #298: a client that goes away mid-stall stops the wait ---\n");
	{
		/* Quiesce arriving while a response is stalled: the loop must
		   notice on the next turn, not finish the 10 seconds first. */
		const int stalled[] = { 0 };

		memset(&c, 0, sizeof(c));
		c.script = stalled;
		c.script_len = 1;
		c.abort_after = 3;     /* aborted() turns true after 3 sends */

		rc = send_bytes(&c, &ops, (const unsigned char *)"HELLO", 5);

		CHECK_EQ(rc, -1, "the send fails");
		CHECK_EQ(c.attempts, 3, "it stops on the turn the client went away");
		CHECK(c.pauses < SEND_STALL_MAX,
			"without sitting out the rest of the budget");
		CHECK_EQ(c.giveups, 0, "an expected shutdown is not reported as a timeout");
	}

	printf("\n--- #298: nothing to send is not a failure ---\n");
	{
		const int any[] = { 64 };

		rc = run(&c, any, 1, 0);

		CHECK_EQ(rc, 0, "a zero-length send succeeds");
		CHECK_EQ(c.attempts, 0, "without touching the socket");
	}

	return mbt_test_summary("TSTSEND");
}
