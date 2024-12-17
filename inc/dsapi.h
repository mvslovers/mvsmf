#ifndef DSAPI_H
#define DSAPI_H

#include "router.h"

/**
 * @file dsapi.h
 * @brief Dataset API Functions for MVS 3.8j
 *
 * This header file defines the interface for dataset operations
 * in the MVS 3.8j system. It provides functions for listing, reading,
 * and writing datasets and their members.
 */

/**
 * @brief Lists available datasets
 * @param session Pointer to the current session
 * @return 0 on success, negative value on error
 */
int datasetListHandler(Session *session) asm("DAPI0001");

/**
 * @brief Reads the content of a dataset
 * @param session Pointer to the current session
 * @return 0 on success, negative value on error
 */
int datasetGetHandler(Session *session) asm("DAPI0002");

/**
 * @brief Writes data to a dataset
 * @param session Pointer to the current session
 * @return 0 on success, negative value on error
 */
int datasetPutHandler(Session *session) asm("DAPI0003");

/**
 * @brief Lists members of a PDS
 * @param session Pointer to the current session
 * @return 0 on success, negative value on error
 */
int memberListHandler(Session *session) asm("DAPI0010");

/**
 * @brief Reads the content of a PDS member
 * @param session Pointer to the current session
 * @return 0 on success, negative value on error
 */
int memberGetHandler(Session *session) asm("DAPI0011");

/**
 * @brief Writes data to a PDS member
 * @param session Pointer to the current session
 * @return 0 on success, negative value on error
 */
int memberPutHandler(Session *session) asm("DAPI0012");

#endif // DSAPI_H
