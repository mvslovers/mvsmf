#include <stdio.h>

#include "infoapi.h"

// private function prototypes
static void createInfoResponse(char *buffer, 
                        const char *zosmf_saf_realm,
                        const char *zosmf_port,
                        const char *zosmf_full_version,
                        const char *api_version,
                        const char *zos_version,
                        const char *zosmf_version,
                        const char *zosmf_hostname);

//
// public functions
//

int infoHandler(HTTPR *httpr) 
{
	int rc = 0;
        
	char buffer[4096];

	createInfoResponse(buffer, 
					   "SAFRealm",
					   "1080",
					   "V1R0M0",
					   "1",
					   "MV3 3.8j",
					   "1.0",
					   "drnbrx3a.neunetz.it");

	http_printf(httpr->httpc, "HTTP/1.1 200 OK\r\n");
	http_printf(httpr->httpc, "Content-Type: application/json\r\n");
	http_printf(httpr->httpc, "Content-Length: %d\r\n", strlen(buffer));
	http_printf(httpr->httpc, "\r\n");
	http_printf(httpr->httpc, "%s", buffer);

	return rc;
}

//
// private functions
//

static 
void createInfoResponse(char *buffer, 
                        const char *zosmf_saf_realm,
                        const char *zosmf_port,
                        const char *zosmf_full_version,
                        const char *api_version,
                        const char *zos_version,
                        const char *zosmf_version,
                        const char *zosmf_hostname) {
    
    // Use sprintf to build the JSON string in buffer
    sprintf(buffer,
            "{\n"
            "  \"zosmf_saf_realm\": \"%s\",\n"
            "  \"zosmf_port\": \"%s\",\n"
            "  \"zosmf_full_version\": \"%s\",\n"
            "  \"api_version\": \"%s\",\n"
            "  \"zos_version\": \"%s\",\n"
            "  \"zosmf_version\": \"%s\",\n"
            "  \"zosmf_hostname\": \"%s\"\n"
            "}",
            zosmf_saf_realm, zosmf_port, zosmf_full_version,
            api_version, zos_version, zosmf_version, zosmf_hostname);
}

