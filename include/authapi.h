#ifndef AUTHAPI_H
#define AUTHAPI_H

/**
 * @file authapi.h
 * @brief z/OSMF Authentication service REST API for MVS 3.8j
 *
 * Implements the /zosmf/services/authenticate endpoints used by z/OSMF and
 * Zowe clients for token-based login/logout.
 *
 * httpd already resolves the client credential (Basic on login, LtpaToken2
 * cookie / Bearer on later calls) into httpc->cred before dispatching here.
 * These handlers only READ that resolved state via the HTTPX auth export
 * (http_get_token / http_logout) -- mvsMF owns no credential-store logic.
 *
 * The session token is httpd's opaque CREDTOK, handed back base64-encoded as
 * the z/OSMF LtpaToken2 cookie; clients replay it as-is. See the Auth redesign
 * (mvslovers/httpd docs/auth-redesign.md) and docs/endpoints/auth/.
 */

#include "router.h"

/**
 * @brief Log in to the z/OSMF server and obtain a session token.
 *
 * POST /zosmf/services/authenticate
 *
 * Reads the httpd-resolved credential; on success returns HTTP 200 with a
 * `Set-Cookie: LtpaToken2=<base64(CREDTOK)>` header and the z/OSMF login
 * body `{returnCode,reasonCode,message}`. Bad credentials -> HTTP 401 with
 * the same body shape.
 *
 * @param session Current session context
 * @return 0 on success, negative value on error
 */
int authLoginHandler(Session *session) asm("AAPI0001");

/**
 * @brief Log out of the z/OSMF server, deleting the session token.
 *
 * DELETE /zosmf/services/authenticate
 *
 * Calls http_logout() (httpd credtok_logout) to drop the credential, expires
 * the LtpaToken2 cookie, and returns HTTP 204 (No Content). Idempotent: an
 * absent/expired token still returns 204.
 *
 * @param session Current session context
 * @return 0 on success, negative value on error
 */
int authLogoutHandler(Session *session) asm("AAPI0002");

#endif // AUTHAPI_H
