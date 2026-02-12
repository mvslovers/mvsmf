#ifndef ZOSMFERR_H
#define ZOSMFERR_H

/**
 * @file zosmferr.h
 * @brief z/OSMF standard error categories and reason codes
 *
 * Shared error constants used across all API modules.
 * Category and reason code values follow IBM z/OSMF conventions.
 */

// z/OSMF error categories (standard across all services)
#define CATEGORY_VSAM					3	// VSAM error
#define CATEGORY_SERVICE				6	// Service error
#define CATEGORY_UNEXPECTED				7	// Unexpected error
#define CATEGORY_CIM					9	// Common Information Model (CIM) error

// Category 7 reason codes (server errors, common to all services)
#define REASON_SERVER_ERROR				0	// Server error

// Category 7 error messages
#define ERR_MSG_SERVER_ERROR			"Server error occurred"

#endif // ZOSMFERR_H
