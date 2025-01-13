#include <clibstr.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "common.h"
#include "httpd.h"
#include "json.h"

//
// private function prototypes
//

static int send_data(Session *session, char *buf);
static char *get_env_param(Session *session, const char *prefix, const char *name);

//
// public functions
//

char *
getQueryParam(Session *session, const char *name)
{
	return get_env_param(session, "QUERY_", name);
}

char *
getPathParam(Session *session, const char *name)
{
	return get_env_param(session, "HTTP_", name);
}

char *
getHeaderParam(Session *session, const char *name)
{
	return get_env_param(session, "HTTP_", name);
}

int 
sendDefaultHeaders(Session *session, int status, const char *content_type,
					   size_t content_length)
{
	int irc = 0;

	irc = http_resp(session->httpc, status);
	if (irc < 0) {
		goto quit;
	}

	if (content_type && (strcmp(HTTP_CONTENT_TYPE_NONE, content_type) != 0)) {
		irc = http_printf(session->httpc, "Content-Type: %s\r\n", content_type);
		if (irc < 0) {
			goto quit;
		}
	}

	if (content_length > 0) {
		irc = http_printf(session->httpc, "Content-Length: %d\r\n", content_length);
		if (irc < 0) {
			goto quit;
		}
	}

  	irc = http_printf(session->httpc, "Cache-Control: no-store\r\n");
  	if (irc < 0) {
		goto quit;
 	}

  	irc = http_printf(session->httpc, "Access-Control-Allow-Origin: *\r\n");
  	if (irc < 0) {
		goto quit;
  	}

  	irc = http_printf(session->httpc, "\r\n");
  	if (irc < 0) {
		goto quit;
  	}

quit:
	return irc;
}

int 
sendJSONResponse(Session *session, int status, JsonBuilder *builder)
{
  	int irc = 0;
  	char *json_str = NULL;

	if (!builder) {
		irc = -1;
		goto quit;
	}

	json_str = getJsonString(builder);
	if (!json_str) {
		irc = -1;
		goto quit;
	}

	irc = sendDefaultHeaders(session, status, HTTP_CONTENT_TYPE_JSON,
							strlen(json_str));
	if (irc < 0) {
		goto quit;
	}

	irc = send_data(session, json_str);

quit:
	if (json_str) {
		free(json_str);
	}

  	return irc;
}

int 
sendErrorResponse(Session *session, int status, int category, int rc,
					  int reason, const char *message, const char **details,
					  int details_count)
{
	int irc = RC_SUCCESS;  

	JsonBuilder *builder = createJsonBuilder();
	if (!builder) {
		goto quit;
	}

	irc = startJsonObject(builder);
	if (irc < 0) {
		goto quit;
	}

	irc = addJsonNumber(builder, "rc", rc);
	if (irc < 0) {
		goto quit;
	}

	irc = addJsonNumber(builder, "category", category);
	if (irc < 0) {
		goto quit;
	}

	irc = addJsonNumber(builder, "reason", reason);
	if (irc < 0) {
		goto quit;
	}

	if (message) {
		irc = addJsonString(builder, "message", message);
		if (irc < 0) {
			goto quit;
		}
	}

	if (details && details_count > 0) {
		irc = addJsonString(builder, "details", details[0]);
		if (irc < 0) {
		goto quit;
		}
	}

	irc = endJsonObject(builder);
	if (irc < 0) {
		goto quit;
	}

	irc = sendJSONResponse(session, status, builder);

quit:
	if (builder) {
		freeJsonBuilder(builder);
	}

	return irc;
}

//
// private functions
//

/**
 * Extracts a parameter from environment variables
 *
 * @param session Current session context
 * @param prefix Prefix for the environment variable name (e.g. "HTTP_" or "QUERY_")
 * @param name Name of the parameter
 * @return Value of the parameter or NULL if not found
 */
__asm__("\n&FUNC    SETC 'get_env_param'");
static char *
get_env_param(Session *session, const char *prefix, const char *name)
{
	char env_name[ENV_NAME_SIZE];

	if (!session || !prefix || !name) {
		return NULL;
	}

	(void)snprintf(env_name, sizeof(env_name), "%s%s", prefix, name);
	return (char *)http_get_env(session->httpc, (const UCHAR *)env_name);
}

/**
 * Sends data to the client
 *
 * @param session Current session context
 * @param buf Buffer containing the data to send
 * @return 0 on success, negative value on error
 */
__asm__("\n&FUNC	SETC 'send_data'");
static int 
send_data(Session *session, char *buf) 
{
	int rc = 0;
	size_t len = strlen(buf);
	size_t pos = 0;

	http_etoa(buf, len);

	for (pos = 0; pos < len; pos += rc) {
		rc = http_send(session->httpc, &buf[pos], len - pos);
		if (rc < 0) {
			goto quit; /* socket error */
		}
	}

	rc = 0; /* success */

quit:
	return rc;
}
