#ifndef SUBDSN_H
#define SUBDSN_H

#include <stddef.h>

/*
 * The data set name out of the "file" member of a job submit request (#477).
 *
 * The request carries //'DSN' (or //'DSN(MEMBER)'); the quotes go, the name
 * stays. The length comes from the request, so the copy must be bounded by
 * the caller's buffer, not by what the client sent.
 *
 * dsname must hold at least DSNAME_MAX + 1 bytes; size is its size.
 *
 * Returns 0 with dsname filled and terminated, or -1 when the text is not of
 * the form //'...' or the name between the quotes is longer than DSNAME_MAX.
 * dsname is untouched on -1.
 */
#define DSNAME_MAX 44

int submit_dsname(const char *filename, char *dsname, size_t size);

#endif
