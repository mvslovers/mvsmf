#ifndef DSAPI_H
#define DSAPI_H

/**
 * @file dsapi.h
 * @brief z/OSMF Dataset REST API implementation for MVS 3.8j
 *
 * Implements the z/OSMF Dataset REST interface API endpoints.
 * Provides dataset management functionality including listing,
 * reading, writing, and member operations for MVS datasets.
 */

#include <mvs/dslist.h>
#include "router.h"

/** Resource name of the ENQ that serializes __listds() across requests (#436) */
#define DSLIST_LOCK_RNAME "MVSMF.LISTDS"

/**
 * @brief __listds() for one request at a time
 *
 * libc370's __listds() has IDCAMS write LISTC output into a temporary data
 * set named by tmpnam(), whose counter starts again at 1 in every request. Two
 * requests that start in the same second get the same system name,
 * SYSyyddd.Thhmmss.RA000.<job>.TMP00001: one scratches it while the other
 * opens it, S213-04. The ENQ keeps a second request out until the first one
 * has closed its temporary data set. IDCAMS was already one at a time inside
 * __listc(), so this costs no concurrency worth having.
 *
 * Same return and errno as __listds(). The router's recovery releases the ENQ
 * if the call abends (session_cleanup).
 *
 * @param session Current session context
 * @param level   Catalog level, as for __listds()
 * @param filter  Name pattern or NULL, as for __listds()
 */
DSLIST **dslist_locked(Session *session, const char *level, const char *filter)
	asm("DSLSTLK");

/**
 * @brief Lists datasets matching specified criteria
 *
 * Returns a list of datasets based on query parameters.
 * Supports filtering by dataset name pattern, volume serial,
 * and other dataset attributes.
 *
 * @param session Current session context
 * @return 0 on success, negative value on error
 *
 * Error cases:
 * - HTTP 400 if invalid filter parameters
 * - HTTP 500 if VSAM catalog access fails
 */
int datasetListHandler(Session *session) asm("DAPI0001");

/**
 * @brief Retrieves dataset content
 *
 * Returns the content of a sequential dataset or PDS member.
 * Supports both text and binary datasets with appropriate
 * content type handling.
 *
 * @param session Current session context
 * @return 0 on success, negative value on error
 *
 * Error cases:
 * - HTTP 404 if dataset not found
 * - HTTP 500 if dataset access fails
 */
int datasetGetHandler(Session *session) asm("DAPI0002");

/**
 * @brief Updates dataset content
 *
 * Writes data to a sequential dataset or PDS member.
 * Creates the dataset if it doesn't exist and allocation
 * parameters are provided.
 *
 * @param session Current session context
 * @return 0 on success, negative value on error
 *
 * Error cases:
 * - HTTP 400 if invalid content or parameters
 * - HTTP 500 if write operation fails
 */
int datasetPutHandler(Session *session) asm("DAPI0003");

/**
 * @brief Lists members of a partitioned dataset
 *
 * Returns a list of all members in a PDS/PDSE.
 * Includes member statistics if available.
 *
 * @param session Current session context
 * @return 0 on success, negative value on error
 *
 * Error cases:
 * - HTTP 404 if PDS not found
 * - HTTP 500 if directory read fails
 */
int memberListHandler(Session *session) asm("DAPI0010");

/**
 * @brief Retrieves PDS member content
 *
 * Returns the content of a specific PDS/PDSE member.
 * Handles both text and binary member data.
 *
 * @param session Current session context
 * @return 0 on success, negative value on error
 *
 * Error cases:
 * - HTTP 404 if member not found
 * - HTTP 500 if member read fails
 */
int memberGetHandler(Session *session) asm("DAPI0011");

/**
 * @brief Updates PDS member content
 *
 * Writes data to a PDS/PDSE member.
 * Creates the member if it doesn't exist.
 *
 * @param session Current session context
 * @return 0 on success, negative value on error
 *
 * Error cases:
 * - HTTP 400 if invalid content
 * - HTTP 500 if write operation fails
 */
int memberPutHandler(Session *session) asm("DAPI0012");

/**
 * @brief Creates a new dataset with specified allocation parameters
 *
 * Allocates a new dataset using attributes from the JSON request body
 * (dsorg, recfm, lrecl, blksize, space, etc.). Used by Zowe CLI/Explorer
 * before uploading data to ensure correct dataset characteristics.
 *
 * @param session Current session context
 * @return 0 on success, negative value on error
 *
 * Error cases:
 * - HTTP 400 if invalid or missing allocation parameters
 * - HTTP 500 if dataset allocation fails
 */
int datasetCreateHandler(Session *session) asm("DAPI0004");

/**
 * @brief Deletes (uncatalogs and scratches) a dataset
 *
 * Removes a dataset from the system. Checks that the dataset
 * exists before attempting deletion.
 *
 * @param session Current session context
 * @return 0 on success, negative value on error
 *
 * Error cases:
 * - HTTP 404 if dataset not found
 * - HTTP 500 if delete operation fails
 */
int datasetDeleteHandler(Session *session) asm("DAPI0005");

/**
 * @brief Deletes a PDS member
 *
 * Removes a member from a partitioned dataset. Checks that the
 * member exists before attempting deletion.
 *
 * @param session Current session context
 * @return 0 on success, negative value on error
 *
 * Error cases:
 * - HTTP 404 if member not found
 * - HTTP 500 if delete operation fails
 */
int memberDeleteHandler(Session *session) asm("DAPI0013");

#endif // DSAPI_H
