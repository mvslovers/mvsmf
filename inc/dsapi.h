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

#include "router.h"

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

#endif // DSAPI_H
