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

// Error messages for Category 6
#define ERR_MSG_PDS_NOT_SEQUENTIAL		"Dataset is a partitioned dataset (PDS). Use /ds/{dataset-name}({member-name}) to access members"
#define ERR_MSG_DATASET_ALLOC_FAILED	"Dataset allocation failed"
#define ERR_MSG_INVALID_ALLOC_PARAMS	"Invalid or missing allocation parameters"
#define ERR_MSG_DATASET_NOT_FOUND	"Dataset not found"
#define ERR_MSG_MEMBER_NOT_FOUND	"PDS member not found"
#define ERR_MSG_INVALID_RENAME_REQUEST	"Unsupported request; only 'rename' is supported"
#define ERR_MSG_RENAME_TARGET_EXISTS	"Rename target already exists"
#define ERR_MSG_RENAME_FAILED		"Rename operation failed"

#endif // DSAPI_ERR_H
