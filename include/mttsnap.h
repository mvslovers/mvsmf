#ifndef MTTSNAP_H
#define MTTSNAP_H

/**
 * @file mttsnap.h
 * @brief Taking a snapshot of the Master Trace Table, and counting in it.
 *
 * The console endpoints read the MTT through a copy: cmtt_new() copies the
 * table, cmtt_get_array() indexes the copy. The copy is the largest allocation
 * on the path, so it is the one that fails first on a degraded address space,
 * and a failed copy is NOT an empty table (#251, #407):
 *
 *   - an empty table still gives an array, with no entries in it;
 *   - no array means the table could not be read at all.
 *
 * Folding the second into the first made the console API answer wrongly rather
 * than just emptily: a detection baseline of 0 turns every message that was
 * already in the table into a "new" match, and a cursor stored without the
 * echo's second re-anchors on the newest echo of the command (#214 reopened).
 * So the two are told apart by MTT_SNAP_FAILED, a negative count no real
 * count can be.
 *
 * Free of project headers on purpose, apart from the MVS ones below:
 * test/host/tstmtsn.c supplies MTENTRY, CMTT, Session and the cmtt_* calls
 * itself and #includes src/mttsnap.c, so the real code runs on the host.
 */

#ifdef __MVS__
#include <mvs/mtt.h>
#include "router.h"
#endif

#include <stddef.h>

/* The snapshot could not be taken. Returned in place of a count of lines. */
#define MTT_SNAP_FAILED  (-1)

/* Column layout of a formatted MTT line (see /zosmf/test?fn=mtt output):
 *   "0000  9.24.38 STC  320  IEE136I ..."
 *    flags^   time^    jobtype+num^    message^
 * Offsets are first-cut and tuned against live data.                         */
#define MTT_SRC_OFF    14         /* jobtype+number field ("STC  320")        */
#define MTT_SRC_LEN    8
#define MTT_MSG_OFF    24         /* message text start                       */

/* An MTT entry is one console line; nothing in the record bounds it for us.  */
#define MTT_ENTRY_MAX  256

/* The length of an entry's data, clamped to 0..MTT_ENTRY_MAX (#176). */
int mtt_len(const MTENTRY *e);

/* The length of s without trailing blanks. */
int rstrip_len(const char *s, int len);

/* Copy the table. On success returns 0 with *cmtt the handle to cmtt_free(),
 * *arr the entries and *n their number (0 for an empty table). On failure
 * returns MTT_SNAP_FAILED with nothing to free. */
int mtt_snap_open(Session *session, CMTT **cmtt, MTENTRY ***arr, unsigned *n);

/* Count the entries whose upper-cased text contains keyword_upper; copy the
 * newest match's message text, right-stripped, into latest (empty if none).
 * Returns the count, or MTT_SNAP_FAILED when the snapshot could not be taken --
 * which is not a count of 0. */
int mtt_detect_count(Session *session, const char *keyword_upper,
                     char *latest, size_t lsz);

#endif /* MTTSNAP_H */
