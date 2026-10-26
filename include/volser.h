#ifndef VOLSER_H
#define VOLSER_H

#include <stddef.h>

/**
 * @file volser.h
 * @brief The volume serial of the -({volume-serial}) routes (#336).
 *
 * A request may name the volume a data set is on:
 *
 *   /zosmf/restfiles/ds/-(VOL001)/MY.DATA.SET
 *
 * Until #336 the operand was captured by the router and read by nobody, so a
 * request naming the wrong volume was answered as if it had named the right
 * one. The decision lives here, away from the catalog call, so a host test can
 * drive every case: the handler asks the catalog and passes the answer in.
 *
 * Scope: only a cataloged data set whose catalog entry is on the named volume
 * is served, exactly like the cataloged form. Reaching a data set that the
 * catalog cannot resolve (OBTAIN/OPEN by volume) is not implemented, so it
 * is refused rather than answered from the catalog. A multi-volume entry is
 * compared by its first volume only -- __locate() reports no other.
 */

#define VOLSER_LEN	6		/* a volume serial is at most six characters */
#define VOLSER_SIZE	(VOLSER_LEN + 1)

/**
 * Fold a volume serial from the request into the form the catalog holds:
 * upper case, one to six characters of A-Z 0-9 $ # @, no blanks. The result
 * is NUL-terminated in out (VOLSER_SIZE bytes); out is untouched on failure.
 *
 * @return 0 on success, -1 for a NULL, empty or over-long value, a character
 *         outside the set, or an out that is too small.
 */
int volser_normalize(const char *value, char *out, size_t size)			asm("MFVOLNRM");

#define VOLSER_ON_VOLUME	0	/* catalog entry is on that volume: serve it   */
#define VOLSER_NOT_CATALOGED	1	/* the catalog cannot resolve the name         */
#define VOLSER_OTHER_VOLUME	2	/* cataloged, but not on the requested volume  */
#define VOLSER_BAD		3	/* the requested volume serial is malformed    */

/**
 * Decide whether a request that names a volume may be served as the cataloged
 * form.
 *
 * @param requested  the volume serial from the path, as received
 * @param located    non-zero when the catalog locate succeeded
 * @param cat_volser the volume the catalog entry names: six bytes as
 *                   __locate() returns them, blank padded, NOT terminated;
 *                   ignored when located is 0
 * @return VOLSER_ON_VOLUME only when the entry is on exactly that volume;
 *         VOLSER_BAD for a malformed requested value; otherwise the reason it
 *         may not be served. Never VOLSER_ON_VOLUME for an unlocated name.
 */
int volser_verdict(const char *requested, int located, const char *cat_volser)	asm("MFVOLVRD");

#endif /* VOLSER_H */
