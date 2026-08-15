#include <string.h>

#include "hostparse.h"
#include "infoapi.h"
#include "common.h"
#include "json.h"

/** Maximum length of a hostname string */
#define MAX_HOST_NAME_LENGTH 256

/** Maximum length of a port string (max port 65535 = 5 digits + nul) */
#define MAX_PORT_LENGTH 6

/** Default host if the request carries no Host header */
#define DEFAULT_HOST "127.0.0.1"

/** Default port if none specified */
#define DEFAULT_PORT "8080"

//
// private function prototypes
//

static void default_port(Session *session, char *outPort, size_t outSize);

//
// public functions
//

int 
infoHandler(Session *session) 
{
	int rc = RC_SUCCESS;
	
	char hostname[MAX_HOST_NAME_LENGTH] = DEFAULT_HOST;
	char port_str[MAX_PORT_LENGTH] = DEFAULT_PORT;

	JsonBuilder *builder = createJsonBuilder();
	if (!builder) {
		sendDefaultHeaders(session, HTTP_STATUS_INTERNAL_SERVER_ERROR,
					   HTTP_CONTENT_TYPE_NONE, 0);
		rc = RC_ERROR;
		goto quit;
	}

	char *value = getHeaderParam(session, "Host"); // e.g. "example.org:8080"
	if (value) {
		/* A Host header this handler cannot make sense of must not fail the
		   request: /zosmf/info is the unauthenticated liveness probe every
		   client calls first, and it used to answer an odd Host by sending
		   nothing at all and dropping the connection (issue #175). Fall back
		   silently and still answer 200 -- the client sent the header, so the
		   operator has nothing to act on, and a probing client would repeat
		   the message on every poll (issue #201).

		   This fallback is only as good as the parser's honesty about
		   failing: a value with no host name in front of the colon used to
		   come back as success plus an empty string, so this branch never ran
		   and the client got "zosmf_hostname":"" (issue #260). */
		if (parse_host_name(value, hostname, sizeof(hostname)) != 0) {
			strcpy(hostname, DEFAULT_HOST);
		}

		if (parse_port_string(value, port_str, sizeof(port_str)) != 0) {
			port_str[0] = '\0';
		}

		/* An empty port is not an error either: RFC 7230 5.4 lets a Host
		   header omit it, and then the scheme implies it. */
		if (validate_port(port_str) != 0) {
			default_port(session, port_str, sizeof(port_str));
		}
	}

	if (startJsonObject(builder) < 0) {
		rc = RC_ERROR;
		goto quit;
	}

	if (addJsonString(builder, "zosmf_hostname", hostname) < 0 ||
		addJsonString(builder, "zosmf_port", port_str) < 0 ||
		addJsonString(builder, "zosmf_version", VERSION) < 0 ||
		addJsonString(builder, "zosmf_full_version", VERSION) < 0 ||
		addJsonString(builder, "zosmf_saf_realm", "SAFRealm") < 0 ||
		addJsonString(builder, "api_version", "1") < 0 ||
		addJsonString(builder, "zos_version", "MVS 3.8j") < 0) {
		rc = RC_ERROR;
		goto quit;
	}

	if (endJsonObject(builder) < 0) {
		rc = RC_ERROR;
		goto quit;
	}

	if (sendJSONResponse(session, HTTP_STATUS_OK, builder) < 0) {
		rc = RC_ERROR;
		goto quit;
	}

quit:
	if (builder) {
		freeJsonBuilder(builder);
	}

	return rc;
}

//
// private functions
//


/**
 * Determines the port for a Host header that carries none
 *
 * RFC 7230 5.4 lets a Host header omit the port, which the scheme then
 * implies - and most clients do exactly that for the default ports. Behind a
 * TLS-terminating reverse proxy mvsMF only ever sees plain HTTP on its own
 * connection, so the public port has to come from the proxy: X-Forwarded-Port
 * where it is set (the only source that gets a non-default public port such as
 * 8443 right), the scheme's default otherwise.
 *
 * SERVER_PORT is deliberately not consulted: it is the HTTPD's listen port,
 * not the port the client dialled, so self-referential z/OSMF URLs built from
 * it would be wrong.
 *
 * @param session Current session context
 * @param outPort Buffer to store the port, never left empty
 * @param outSize Size of the outPort buffer
 */
__asm__("\n&FUNC	SETC 'default_port'");
static void
default_port(Session *session, char *outPort, size_t outSize)
{
	const char *fwd_port = getHeaderParam(session, "X-Forwarded-Port");

	if (fwd_port && strlen(fwd_port) < outSize && validate_port(fwd_port) == 0) {
		strcpy(outPort, fwd_port);
		return;
	}

	strcpy(outPort, strcmp(getRequestScheme(session), "https") == 0
					? "443" : "80");
}
