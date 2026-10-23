#ifndef MTTSNAP_H
#define MTTSNAP_H

/**
 * @file mttsnap.h
 * @brief Taking a snapshot of the Master Trace Table, and finding new matches in it.
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
 * itself and #includes src/mttsnap.c, so the real code runs on the host. It
 * defines MTTSNAP_FAKES to keep the MVS headers out: `mbt test` builds with the
 * host compiler (no __MVS__), `mbt build --all --tests` with cc370 (__MVS__).
 */

#if defined(__MVS__) && !defined(MTTSNAP_FAKES)
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
int mtt_len(const MTENTRY *e)                               asm("MFMTTLEN");

/* The length of s without trailing blanks. */
int rstrip_len(const char *s, int len)                      asm("MFRSTRIP");

/* Copy the table. On success returns 0 with *cmtt the handle to cmtt_free(),
 * *arr the entries and *n their number (0 for an empty table). On failure
 * returns MTT_SNAP_FAILED with nothing to free. */
int mtt_snap_open(Session *session, CMTT **cmtt, MTENTRY ***arr,
                  unsigned *n)                                asm("MFMTTSNP");

/* Seconds-of-day from the "hh.mm.ss" field of a formatted MTT line (right
 * after the 4-character flags field); -1 if the line carries none. */
int mtt_secs_of_day(const char *dat, int len)               asm("MFMTTSOD");

/* A place in the Master Trace Table that survives the table wrapping (#195).
 *
 * The table is a window: the oldest entries leave it as new ones arrive, and
 * the window is bounded in bytes, not in lines. A count of matches taken once
 * and compared later is therefore not a measure of what arrived since -- a
 * burst of other messages pushes earlier matches out and the count falls below
 * the baseline while a fresh match sits in the table.
 *
 * So a detection remembers where the table ended instead: the hh.mm.ss of its
 * newest stamped entry, and how many matches carry exactly that second (the
 * stamp has no finer grain). Only matches stamped later count as new. */
typedef struct mtt_anchor {
	int      secs;     /* seconds-of-day of the newest stamped entry; -1: none */
	unsigned same;     /* matches stamped exactly at secs                      */
} MTT_ANCHOR;

/* Take the anchor for keyword_upper. Returns 0, or MTT_SNAP_FAILED when the
 * snapshot could not be taken -- in which case *anchor is not set. */
int mtt_detect_anchor(Session *session, const char *keyword_upper,
                      MTT_ANCHOR *anchor)                   asm("MFMTTANC");

/* Count the entries whose upper-cased text contains keyword_upper and that are
 * newer than anchor; copy the newest of them, message text only and
 * right-stripped, into latest (empty if none). An entry without a time of its
 * own (a continuation line) takes the time of the entry before it. Returns the
 * count, or MTT_SNAP_FAILED when the snapshot could not be taken -- which is
 * not a count of 0. */
int mtt_detect_since(Session *session, const char *keyword_upper,
                     const MTT_ANCHOR *anchor, char *latest,
                     size_t lsz)                            asm("MFMTTSNC");

#endif /* MTTSNAP_H */
