#ifndef JOBSAPI_H
#define JOBSAPI_H

/**
 * @file jobsapi.h
 * @brief z/OSMF Jobs REST API implementation for MVS 3.8j
 *
 * Implements the z/OSMF Jobs REST interface API endpoints.
 * Provides job management functionality including submission, status query,
 * output retrieval, and job control operations.
 */

#include "router.h"

/**
 * @brief Lists jobs according to specified filters
 *
 * Returns a list of jobs matching the query parameters. Supports filtering by
 * owner, prefix, status and jobid. System jobs (SYSLOG, INIT) are excluded.
 *
 * @param session Current session context
 * @return 0 on success, negative value on error
 */
int jobListHandler(Session *session) asm("JAPI0001");

/**
 * @brief Lists spool files for a specific job
 *
 * Returns information about all spool files (DDs) associated with the specified job.
 * JESINTXT files are excluded from the results.
 *
 * @param session Current session context
 * @return 0 on success, negative value on error
 */
int jobFilesHandler(Session *session) asm("JAPI0002");

/**
 * @brief Retrieves content of a specific spool file
 *
 * Returns the content of the specified spool file (DD) for a job.
 * Supports pagination and content filtering.
 *
 * @param session Current session context
 * @return 0 on success, negative value on error
 */
int jobRecordsHandler(Session *session) asm("JAPI0003");

/**
 * @brief Submits a new job
 *
 * Submits JCL for execution. Supports both inline JCL and JCL from datasets.
 * Returns job information upon successful submission.
 *
 * @param session Current session context
 * @return 0 on success, negative value on error
 */
int jobSubmitHandler(Session *session) asm("JAPI0004");

/**
 * @brief Retrieves status information for a specific job
 *
 * Returns detailed status information for the specified job including
 * phase, return codes and other execution details.
 *
 * @param session Current session context
 * @return 0 on success, negative value on error
 */
int jobStatusHandler(Session *session) asm("JAPI0005");

/**
 * @brief Purges a completed job from the system
 *
 * Removes a job and all its associated spool files from the system.
 * Only completed jobs can be purged. Self-purge is not allowed.
 *
 * @param session Current session context
 * @return 0 on success, negative value on error
 */
int jobPurgeHandler(Session *session) asm("JAPI0006");

/**
 * @brief Cancels a running job
 *
 * Cancels execution of a running job. Only jobs in execution
 * can be cancelled. Self-cancel is not allowed.
 *
 * @param session Current session context
 * @return 0 on success, negative value on error
 */
int jobCancelHandler(Session *session) asm("JAPI0007");

#endif // JOBSAPI_H
