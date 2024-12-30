#include <clibstr.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "httpd.h"
#include "json.h"
#include "common.h"

static int send_data(Session *session, char *buf);

char* 
getPathParam(Session *session, const char *name) 
{
	char env_name[ENV_NAME_SIZE];
	
	if (!session || !name) {
		return NULL;
	}

	(void) snprintf(env_name, sizeof(env_name), "HTTP_%s", name);
	char *env = (char *) http_get_env(session->httpc, (const UCHAR *) env_name);
	if (!env) {
		return NULL;
	}

	return env;
}

char *
getQueryParam(Session *session, const char *name)
{
    char env_name[ENV_NAME_SIZE];
    
    if (!session || !name) {
        return NULL;
    }

    (void) snprintf(env_name, sizeof(env_name), "QUERY_%s", name);
    char *env = (char *) http_get_env(session->httpc, (const UCHAR *) env_name);
    if (!env) {
        return NULL;
    }

    return env;
}

char *
getHeaderParam(Session *session, const char *name)
{
    char env_name[ENV_NAME_SIZE];
    
    if (!session || !name) {
        return NULL;
    }

    (void) snprintf(env_name, sizeof(env_name), "HTTP_%s", name);
    char *env = (char *) http_get_env(session->httpc, (const UCHAR *) env_name);
    if (!env) {
        return NULL;
    }

    return env;
}

int
sendDefaultHeaders(Session *session, int status, const char *content_type)
{
    int irc = 0;
	
	irc = http_resp(session->httpc, status);
    if (irc < 0) {
        goto quit;
    }
    
    irc = http_printf(session->httpc, "Content-Type: %s\r\n", content_type);
    if (irc < 0) {
        goto quit;
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

    irc = sendDefaultHeaders(session, status, HTTP_CONTENT_TYPE_JSON);
    if (irc < 0) {
        goto quit;
    }

	irc = send_data(session, json_str);

quit:
    // Cleanup
    if (json_str) {
        free(json_str);
    }
    
    return irc;
}

int 
sendErrorResponse(Session *session, int status, int category, int rc, int reason, 
                   const char *message, const char **details, int details_count) 
{
    int irc = 0;

    JsonBuilder *builder = createJsonBuilder();
    
	if (!builder) {
        rc = -1;
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
        // TODO (MIG): Implement array support in JsonBuilder when needed
        // For now, we only add the first detail as a string
        irc = addJsonString(builder, "details", details[0]);
        if (irc < 0) {
            goto quit;
        }
    }

    irc = endJsonObject(builder);
    if (irc < 0) {
        goto quit;
    }

    sendJSONResponse(session, status, builder);
        
quit:

    // Cleanup
    if (builder) {
        freeJsonBuilder(builder);
    }

    return irc;
} 

__asm__("\n&FUNC    SETC 'send_data'");
static int 
send_data(Session *session, char *buf)
{
    int		rc      = 0;
    
	size_t  len     = strlen(buf);
    size_t	pos     = 0;

    http_etoa(buf, len);

    for(pos=0; pos < len; pos+=rc) {
        rc = http_send(session->httpc, &buf[pos], len-pos);
        if (rc<0) {
			goto quit; /* socket error */
		}
    }

    rc = 0; /* success */

quit:
    return rc;
}
