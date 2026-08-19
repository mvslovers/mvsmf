#ifndef DSAPI_ERR_H
#define DSAPI_ERR_H

/**
 * @file dsapi_err.h
 * @brief Dataset REST API error reason codes and messages
 *
 * Service-specific reason codes for z/OSMF Dataset REST interface.
 */

#include "zosmferr.h"

// Reason codes for Category 6 (Service error)
#define REASON_PDS_NOT_SEQUENTIAL		1	// Dataset is PDS, not sequential
#define REASON_DATASET_ALLOC_FAILED		2	// Dataset allocation failed
#define REASON_INVALID_ALLOC_PARAMS		3	// Invalid or missing allocation parameters
#define REASON_DATASET_NOT_FOUND		4	// Dataset not found
#define REASON_MEMBER_NOT_FOUND			5	// PDS member not found
#define REASON_INVALID_RENAME_REQUEST	6	// Unsupported or malformed control request
#define REASON_RENAME_TARGET_EXISTS		7	// Rename target already exists
#define REASON_RENAME_FAILED			8	// Rename operation failed
#define REASON_PATTERN_TOO_LONG			9	// Member pattern longer than the handler accepts
#define REASON_ETAG_MISMATCH			10	// If-Match precondition failed (issue #152)

/* Dynamic allocation failure -- the reference's own report, measured (#317).
 *
 * A real z/OSMF answers a POST that fails to allocate with
 *
 *   500 {"category":8,"rc":900,"reason":7,"message":"Dynamic allocation Error"}
 *
 * and it answers EXACTLY that whether the caller lacked authority for the name
 * or asked for more space than exists -- byte for byte, both measured. So these
 * are not category 6 reason codes and do not belong in the block above: they are
 * one complete report, and the four values travel together.
 *
 * Do not make the two cases distinguishable here. mvsMF can tell them apart
 * (__dsalcf() answers RC=4 for the denial and RC=12 for the space failure) and
 * deliberately does not pass that on, because the reference does not. That is
 * the same rule that made #228 ADD a distinct body for a read denial: there the
 * reference draws the line, here it does not.
 *
 * rc 900 is not a typo and not a SAF code. z/OSMF's `rc` is not always the
 * 0/4/8/12 the rest of this file uses -- copy the measured value.
 */
#define CATEGORY_DYNALLOC			8
#define RC_DYNALLOC_ERROR			900
#define REASON_DYNALLOC_ERROR			7
#define ERR_MSG_DYNALLOC_ERROR			"Dynamic allocation Error"

// Error messages for Category 6
#define ERR_MSG_PDS_NOT_SEQUENTIAL		"Dataset is a partitioned dataset (PDS). Use /ds/{dataset-name}({member-name}) to access members"
#define ERR_MSG_DATASET_ALLOC_FAILED	"Dataset allocation failed"
#define ERR_MSG_INVALID_ALLOC_PARAMS	"Invalid or missing allocation parameters"
#define ERR_MSG_DATASET_NOT_FOUND	"Dataset not found"
#define ERR_MSG_MEMBER_NOT_FOUND	"PDS member not found"
#define ERR_MSG_INVALID_RENAME_REQUEST	"Unsupported request; only 'rename' is supported"
#define ERR_MSG_RENAME_TARGET_EXISTS	"Rename target already exists"
#define ERR_MSG_RENAME_FAILED		"Rename operation failed"
#define ERR_MSG_PATTERN_TOO_LONG	"Member pattern is too long"
#define ERR_MSG_ETAG_MISMATCH		"The resource was modified since the supplied ETag was created"

#endif // DSAPI_ERR_H
