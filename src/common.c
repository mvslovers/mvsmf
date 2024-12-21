#include <stdio.h>
#include "common.h"
#include "httpd.h"
#include "cJSON.h"

int 
sendSuccessResponse(Session *session, int status) 
{
    cJSON *response = cJSON_CreateObject();
    char *json_str;
    
    // Add standard success fields
    cJSON_AddNumberToObject(response, "rc", 0);
    
    // Convert to string
    json_str = cJSON_Print(response);
    
    // Send response with status code
    //set_status(session, http_status);
    //set_content_type(session, "application/json");
    //write_response(session, json_str);
    
    // Cleanup
    free(json_str);
    cJSON_Delete(response);
    
    return 0;
}

int 
sendErrorResponse(Session *session, int status, int category, int rc, int reason, 
                   const char *message, const char **details, int details_count) 
{
    int irc = 0;

    cJSON *response = cJSON_CreateObject();
    cJSON *details_array = NULL;
    char *json_str;
    
    // Add standard error fields
    cJSON_AddNumberToObject(response, "rc", rc);
    cJSON_AddNumberToObject(response, "category", category);
    if (reason > 0) {
        cJSON_AddNumberToObject(response, "reason", reason);
    }
    if (message) {
        cJSON_AddStringToObject(response, "message", message);
    }
    
    // Add details array if provided
    if (details && details_count > 0) {
        details_array = cJSON_CreateArray();
        int i = 0;
        for (i = 0; i < details_count; i++) {
            if (details[i]) {
                cJSON_AddItemToArray(details_array, cJSON_CreateString(details[i]));
            }
        }
        cJSON_AddItemToObject(response, "details", details_array);
    }
    
    // Convert to string
    json_str = cJSON_Print(response);
    wtof("MVSMF42D: json_str: %s", json_str);

    // Send response with status code
    if ((irc = http_resp(session->httpc, status)) < 0) goto quit;
    if ((irc = http_printf(session->httpc, "Cache-Control: no-store\r\n")) < 0) goto quit; 
	if ((irc = http_printf(session->httpc, "Content-Type: %s\r\n", "application/json")) < 0) goto quit;
	if ((irc = http_printf(session->httpc, "Access-Control-Allow-Origin: *\r\n")) < 0) goto quit;
	if ((irc = http_printf(session->httpc, "\r\n")) < 0) goto quit;

    if ((irc = http_printf(session->httpc, "%s\n", json_str)) < 0) goto quit;

    
    //write_response(session, json_str);
    
    
quit:
    wtof("MVSMF42D: sendErrorResponse: rc: %d", irc);
    // Cleanup
    free(json_str);
    cJSON_Delete(response);

    return irc;
} 

char* getPathParam(Session *session, const char *param_name) 
{
	char env_name[256];
	
	if (!session || !param_name) {
		return NULL;
	}

	sprintf(env_name, "HTTP_%s", param_name);
	return (char *) http_get_env(session->httpc, (const UCHAR *) env_name);
}
