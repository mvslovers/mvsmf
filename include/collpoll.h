#ifndef COLLPOLL_H
#define COLLPOLL_H

/**
 * @file collpoll.h
 * @brief One poll of the console collect endpoint.
 *
 * A collect poll answers an error, never an empty block, when it cannot do its
 * work: the client stops on an empty answer and takes the block for finished,
 * so the lines still to come are lost (#251, #407, #475). Two things can fail
 * before there is an answer, the response buffer and the copy of the Master
 * Trace Table, and both are COLLECT_POLL_FAILED here.
 *
 * Its own translation unit so test/host/tstcolpl.c can drive the real function;
 * consapi.c cannot compile on the host. Like mttsnap.h it keeps the MVS
 * headers out when the test defines MTTSNAP_FAKES.
 */

#include "mttsnap.h"

#include <stddef.h>

/* The poll could not be made: *resp is not set and *delivered is unchanged. */
#define COLLECT_POLL_FAILED  (-1)

/* The correlator collect_poll() asks for the lines of a block; consapi.c's
 * correlate_once(). Returns MTT_SNAP_FAILED when it had no snapshot. */
typedef int (*collect_corr_fn)(Session *session, const char *cmd_upper,
                               char *out, size_t outsz, unsigned skip,
                               unsigned *total, int want_secs,
                               int *echo_secs_out);

/* Allocate cap bytes for the response, correlate the block of cmd_upper and
 * move *delivered forward to the lines now in the block. On success returns 0
 * with *resp the NUL-terminated lines beyond the old *delivered, which the
 * caller frees. On failure returns COLLECT_POLL_FAILED with nothing to free;
 * *delivered is as it was, so the same poll can be made again. */
int collect_poll(Session *session, collect_corr_fn corr, const char *cmd_upper,
                 int echo_secs, size_t cap, unsigned *delivered,
                 char **resp)                               asm("MFCOLPOL");

#endif /* COLLPOLL_H */
