#ifndef USSAPI_H
#define USSAPI_H

/**
 * @file ussapi.h
 * @brief z/OSMF USS File REST API implementation for MVS 3.8j
 *
 * Implements the z/OSMF USS File REST interface API endpoints.
 * All file operations are performed via libufs against the UFSD
 * filesystem server.
 */

#include "router.h"

/* UFSD return codes (from UFSD subsystem) */
#define UFSD_RC_OK          0   /* Success                */
#define UFSD_RC_NOFILE     28   /* File/dir not found     */
#define UFSD_RC_EXIST      32   /* Already exists         */
#define UFSD_RC_NOTDIR     36   /* Not a directory        */
#define UFSD_RC_ISDIR      40   /* Is a directory         */
#define UFSD_RC_NOSPACE    44   /* No space on device     */
#define UFSD_RC_NOINODES   48   /* No inodes available    */
#define UFSD_RC_IO         52   /* I/O error              */
#define UFSD_RC_BADFD      56   /* Bad file descriptor    */
#define UFSD_RC_NOTEMPTY   60   /* Directory not empty    */
#define UFSD_RC_NAMETOOLONG 64  /* Name too long          */

/**
 * @brief Lists files/directories at a given path
 *
 * GET /zosmf/restfiles/fs?path=/u/user/dir
 *
 * @param session Current session context
 * @return 0 on success, negative value on error
 */
int ussListHandler(Session *session) asm("UAPI0001");

/**
 * @brief Retrieves file content
 *
 * GET /zosmf/restfiles/fs/{*filepath}
 *
 * @param session Current session context
 * @return 0 on success, negative value on error
 */
int ussGetHandler(Session *session) asm("UAPI0002");

/**
 * @brief Writes file content
 *
 * PUT /zosmf/restfiles/fs/{*filepath}
 *
 * @param session Current session context
 * @return 0 on success, negative value on error
 */
int ussPutHandler(Session *session) asm("UAPI0003");

/**
 * @brief Creates a file or directory
 *
 * POST /zosmf/restfiles/fs/{*filepath}
 *
 * @param session Current session context
 * @return 0 on success, negative value on error
 */
int ussCreateHandler(Session *session) asm("UAPI0004");

/**
 * @brief Deletes a file or directory
 *
 * DELETE /zosmf/restfiles/fs/{*filepath}
 *
 * @param session Current session context
 * @return 0 on success, negative value on error
 */
int ussDeleteHandler(Session *session) asm("UAPI0005");

#endif /* USSAPI_H */
