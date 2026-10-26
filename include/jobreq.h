#ifndef JOBREQ_H
#define JOBREQ_H

/**
 * @file jobreq.h
 * @brief The "request" member of a PUT /zosmf/restjobs/jobs/{name}/{id} body (#417).
 *
 * z/OSMF takes one route for every update of a job and tells them apart by
 * the body: {"request":"cancel"}, "hold" or "release", with an optional
 * "version". This reads the one member the dispatch needs.
 *
 * Free of MVS services so test/host/tstjreq.c drives the real code. The body
 * has to be in the execution character set already (translated from the wire
 * with the jobs codepage), since the comparisons use character literals.
 */

#define JOBREQ_NONE		0	/**< no object, damaged JSON, or no "request" member */
#define JOBREQ_UNKNOWN	1	/**< "request" is there but is none of the three */
#define JOBREQ_CANCEL	2
#define JOBREQ_HOLD		3
#define JOBREQ_RELEASE	4

/**
 * @brief Finds which request a PUT body makes
 *
 * Only a member of the top-level object counts; the word inside a value or a
 * nested object does not. A body that is not exactly one complete JSON object
 * (truncated, a comma before the closing brace, anything but white space after
 * it) is JOBREQ_NONE, so a damaged body can never be taken for a cancel. The
 * value is compared whole and case-sensitively.
 *
 * @param body NUL-terminated request body, may be NULL
 * @return one of the JOBREQ_* codes
 */
int jobreq_parse(const char *body);

#endif /* JOBREQ_H */
