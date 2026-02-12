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

// Error messages for Category 6
#define ERR_MSG_PDS_NOT_SEQUENTIAL		"Dataset is a partitioned dataset (PDS). Use /ds/{dataset-name}({member-name}) to access members"

#endif // DSAPI_ERR_H
