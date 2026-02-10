#ifndef JOBSAPI_MSG_H
#define JOBSAPI_MSG_H

/**
 * @file jobsapi_msg.h
 * @brief Error messages and reason codes for Jobs API
 *
 * Defines error messages and reason codes used in the Jobs API responses.
 */

/** @brief Error message for server errors */
#define ERR_MSG_SERVER_ERROR "Internal server error occurred"

/** @brief Error message for job not found */
#define ERR_MSG_JOB_NOT_FOUND "Job '%s(%s)' not found"

/** @brief Error message for invalid query parameters */
#define ERR_MSG_INVALID_QUERY "Invalid query parameters"

/** @brief Error message for invalid request content */
#define ERR_MSG_INVALID_REQUEST "Invalid request content or format"

/** @brief Error message for STC purge attempt */
#define ERR_MSG_STC_PURGE "Cannot purge a started task"

/** @brief Error message for incorrect JES VSAM handle */
#define ERR_MSG_INCORRECT_JES_VSAM_HANDLE "Unable to open JES2 checkpoint and spool datasets"

/** @brief Message for job submission */
#define MSG_JOB_SUBMITTED "JOB %s(%s) SUBMITTED"

/** @brief Message for JES error */
#define MSG_JOB_JES_ERROR "Unable to open JES2 checkpoint and spool datasets"

/** @brief Error categories */
#define CATEGORY_SERVICE 6      /**< Service related error */
#define CATEGORY_VSAM 7         /**< VSAM related error */
#define CATEGORY_UNEXPECTED 8   /**< Unexpected error */

/** @brief Error message for missing file field in JSON body */
#define ERR_MSG_MISSING_FILE_FIELD "Missing or invalid 'file' field in request body"

/** @brief Error message for dataset open failure */
#define ERR_MSG_SUBMIT_FILE_OPEN "Cannot open dataset: %s"

/** @brief Error reason codes */
#define REASON_SERVER_ERROR 1           /**< Internal server error */
#define REASON_JOB_NOT_FOUND 2         /**< Job not found */
#define REASON_INVALID_QUERY 3         /**< Invalid query parameters */
#define REASON_INVALID_REQUEST 4       /**< Invalid request content */
#define REASON_STC_PURGE 5            /**< Cannot purge STC */
#define REASON_INCORRECT_JES_VSAM_HANDLE 6  /**< JES VSAM handle error */
#define REASON_MISSING_FILE_FIELD 7    /**< Missing file field in JSON */
#define REASON_SUBMIT_FILE_OPEN 8      /**< Cannot open dataset */

#endif // JOBSAPI_MSG_H
