#ifndef LISTFAIL_H
#define LISTFAIL_H

/*
 * What a NULL from __listds() or __listpd() means (#360).
 *
 * Both return NULL for an empty result and for a failure, and errno is the
 * only thing that tells them apart (libc370 2.0.0 and later): errno is cleared
 * on entry, so it is 0 unless something set it.
 *
 *   NULL, errno 0        nothing matched - an empty level, a member that is
 *                        not there
 *   NULL, errno ENOMEM   the list could not be built; the partial one is
 *                        already freed. Says nothing about the data set.
 *   NULL, other errno    __listpd() could not open or read the directory
 *                        (fopen()'s errno, or EIO)
 *
 * errno is only meaningful on NULL: a list that came back keeps whatever
 * errno an earlier call left, and must not read as a failure.
 *
 * Read errno straight after the call and pass it in; anything in between
 * (a WTO, a DEQ) may overwrite it.
 */

#define LIST_FOUND	0	/* a list came back */
#define LIST_EMPTY	1	/* NULL, errno 0 */
#define LIST_NOSTOR	2	/* NULL, ENOMEM */
#define LIST_FAILED	3	/* NULL, any other errno */

int list_outcome(const void *list, int err);

#endif /* LISTFAIL_H */
