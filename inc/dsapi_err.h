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

// Error messages for Category 6
#define ERR_MSG_PDS_NOT_SEQUENTIAL		"Dataset is a partitioned dataset (PDS). Use /ds/{dataset-name}({member-name}) to access members"
#define ERR_MSG_DATASET_ALLOC_FAILED	"Dataset allocation failed"
#define ERR_MSG_INVALID_ALLOC_PARAMS	"Invalid or missing allocation parameters"
#define ERR_MSG_DATASET_NOT_FOUND	"Dataset not found"
#define ERR_MSG_MEMBER_NOT_FOUND	"PDS member not found"

#endif // DSAPI_ERR_H
