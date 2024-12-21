#ifndef JOBSAPI_ERR_H
#define JOBSAPI_ERR_H

// Job API Categories
#define CATEGORY_VSAM					 3  // VSAM error
#define CATEGORY_SERVICE				 6  // Service error
#define CATEGORY_UNEXPECTED				 7  // Unexpected error
#define CATEGORY_CIM					 9  // Common Information Model (CIM) error

// Reason codes for Category 3 (VSAM error)
#define REASON_INCORRECT_JES_VSAM_HANDLE 1  // Incorrect JesVsam handle
#define REASON_VSAM_GET_FAILED			 0  // JesVsam get failed

// Error messages for Category 3 (VSAM error)
#define ERR_MSG_INCORRECT_JES_VSAM_HANDLE 	"Incorrect JesVsam handle"
#define ERR_MSG_VSAM_GET_FAILED				"JesVsam get failed"

// Reason codes for Category 6 (Service error)
#define REASON_INVALID_INTRDR_MODE		 1  // Invalid internal reader mode
#define REASON_INVALID_INTRDR_PARAMS	 2  // Invalid internal reader parameters
#define REASON_MISSING_CONTENT			 3  // Missing required content
#define REASON_INVALID_QUERY			 4  // Invalid query parameter
#define REASON_INVALID_UPDATE			 5  // Invalid update request
#define REASON_INVALID_JOB_UPDATE		 6  // Invalid job update request
#define REASON_NO_MATCH_METHOD			 7  // No matching method
#define REASON_POST_NOT_SUPPORTED		 8  // POST not supported
#define REASON_RECORD_TOO_LONG			 9  // Record too long
#define REASON_JOB_NOT_FOUND			10  // Job not found
#define REASON_INVALID_RECORD_RANGE		11  // Invalid record range
#define REASON_NO_SPOOL_FILE			12  // Spool file not found
#define REASON_NOT_A_JOB				13  // Input not recognized as job
#define REASON_UNSUPPORTED_ENCODING		14  // Unsupported encoding
#define REASON_DD_NOT_SUPPORTED			15  // DD names not supported
#define REASON_DATASET_NOT_FOUND		16  // Dataset not found
#define REASON_INVALID_JOB_START		17  // Invalid job start
#define REASON_INVALID_PATH				18  // Invalid path
#define REASON_INVALID_READER_MODE		19  // Invalid reader mode
#define REASON_NOT_IMPLEMENTED			20  // Service not implemented
#define REASON_SELF_PURGE				50  // Self purge
#define REASON_STC_PURGE				51  // STC purge

// Reason codes for Category 7 (Server error)
#define REASON_SERVER_ERROR				0  // Server error

// Error messages for Category 6
#define ERR_MSG_INVALID_INTRDR_MODE		"Incorrect Internal Reader mode: %s. Must be one of TEXT | RECORD | BINARY"
#define ERR_MSG_INVALID_INTRDR_PARAMS	"Incorrect Internal Reader parameters: %s. Fixed records are required for binary mode"
#define ERR_MSG_MISSING_CONTENT			"Request does not contain '%s' content"
#define ERR_MSG_INVALID_QUERY			"Value of %s query parameter is not valid"
#define ERR_MSG_INVALID_UPDATE			"Update request is not 'cancel'"
#define ERR_MSG_INVALID_JOB_UPDATE		"Request does not contain a valid job update request"
#define ERR_MSG_NO_MATCH_METHOD			"No match for method %s and pathInfo='%s'"
#define ERR_MSG_POST_NOT_SUPPORTED		"POST requests not supported"
#define ERR_MSG_RECORD_TOO_LONG			"Job submission error. Record length %d too long for JCL submission, maxlen=%d"
#define ERR_MSG_JOB_NOT_FOUND			"No job found for reference: '%s(%s)'"
#define ERR_MSG_INVALID_RECORD_RANGE	"Record range '%s' is not valid for spool file record request"
#define ERR_MSG_NO_SPOOL_FILE			"Job '%s' does not contain spool file id %d"
#define ERR_MSG_NOT_A_JOB				"Job input was not recognized by system as a job"
#define ERR_MSG_UNSUPPORTED_ENCODING	"Unsupported encoding: %s"
#define ERR_MSG_DD_NOT_SUPPORTED		"DD names are not supported for submit input"
#define ERR_MSG_DATASET_NOT_FOUND		"Data set not found"
#define ERR_MSG_INVALID_JOB_START		"Submit input data does not start with a slash"
#define ERR_MSG_INVALID_PATH			"Submit input filename must be absolute path: %s"
#define ERR_MSG_INVALID_READER_MODE		"Internal reader mode must be RECORD for data set submission: %s"
#define ERR_MSG_NOT_IMPLEMENTED			"Service not implemented: %s"
#define ERR_MSG_SELF_PURGE				"Purge of HTTPD STC is not allowed"
#define ERR_MSG_STC_PURGE				"Purge of a STC or a TSO useris not allowed"

// Category 7 error messages
#define ERR_MSG_SERVER_ERROR			"Server error occurred"

// Category 9 error messages
#define ERR_MSG_INVALID_JOBNAME			"Incorrect jobname: \"%s\""
#define ERR_MSG_INVALID_JOBID			"Incorrect jobid: \"%s\""
#define ERR_MSG_INVALID_JES_TYPE		"Incorrect JES type"
#define ERR_MSG_INVALID_JOB_CLASS		"Incorrect job class: \"%s\""

#endif // JOBSAPI_ERR_H 
