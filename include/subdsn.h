#ifndef SUBDSN_H
#define SUBDSN_H

#include <stddef.h>

/*
 * The data set name out of the "file" member of a job submit request (#477).
 *
 * The request carries the name in quotes after two slashes, as DSN or
 * DSN(MEMBER); the slashes and quotes go, the name stays. The length comes
 * from the request, so the copy is bounded by the caller's buffer, and the
 * two parts are held to their own limits: a data set name is at most 44
 * characters and a member name at most 8, so the whole is at most 54.
 *
 * dsname must hold SUBDSN_SIZE bytes; size is its size.
 *
 * Returns 0 with dsname filled and terminated, or -1 when the text is not
 * quoted after two slashes, the data set name is empty or over 44 characters,
 * or the member is empty, over 8 characters or lacks its closing parenthesis.
 * dsname is untouched on -1.
 */
#define DSNAME_MAX	44
#define MEMBER_MAX	8
#define SUBDSN_SIZE	(DSNAME_MAX + 1 + MEMBER_MAX + 1 + 1)

int submit_dsname(const char *filename, char *dsname, size_t size);

#endif
