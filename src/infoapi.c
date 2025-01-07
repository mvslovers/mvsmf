#include "infoapi.h"
#include "common.h"
#include "json.h"

/** Maximum length of a hostname string */
#define MAX_HOST_NAME_LENGTH 256

/** Maximum length of a port string */
#define MAX_PORT_LENGTH 5

/** Default port if none specified */
#define DEFAULT_PORT "8080"

//
// private function prototypes
//

static int parse_host_name(const char *value, char *outHost, size_t outSize);
static int parse_port_string(const char *value, char *outPort, size_t outSize);
static int validate_port(const char *port);

//
// public functions
//

int 
infoHandler(Session *session) 
{
	int rc = RC_SUCCESS;
	
	char hostname[MAX_HOST_NAME_LENGTH] = "127.0.0.1";
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
		if (parse_host_name(value, hostname, sizeof(hostname)) != 0) {
			wtof("MVSMF01E Unable to parse host name");
			rc = RC_ERROR;
			goto quit;
		}

		if (parse_port_string(value, port_str, sizeof(port_str)) != 0) {
			wtof("MVSMF02E Unable to parse port");
			rc = RC_ERROR;
			goto quit;
		}

		if (validate_port(port_str) != 0) {
			wtof("MVSMF03E Invalid port number");
			rc = RC_ERROR;
			goto quit;
		}
	}

	if (startJsonObject(builder) < 0) {
		rc = RC_ERROR;
		goto quit;
	}

	if (addJsonString(builder, "zosmf_hostname", hostname) < 0 ||
		addJsonString(builder, "zosmf_port", port_str) < 0 ||
		addJsonString(builder, "zosmf_version", "1.0") < 0 ||
		addJsonString(builder, "zosmf_full_version", "V1R0M0") < 0 ||
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
 * Extracts the hostname from a host:port string
 *
 * @param value Input string in format "hostname:port" or just "hostname"
 * @param outHost Buffer to store the extracted hostname
 * @param outSize Size of the outHost buffer
 * @return 0 on success, -1 if parameters are invalid, -2 if outHost buffer is too small
 */
__asm__("\n&FUNC	SETC 'parse_host_name'");
static int 
parse_host_name(const char *value, char *outHost, size_t outSize)
{
    if (!value || !outHost || outSize == 0) {
        return -1;
    }

    const char *colon = strchr(value, ':');
    size_t hostLen = 0;

    if (colon) {
        hostLen = (size_t)(colon - value);
    } else {
        hostLen = strlen(value);
    }

    if (hostLen >= outSize) {
        return -2; 
    }

    strncpy(outHost, value, hostLen);
    outHost[hostLen] = '\0';

    return 0;
}

/**
 * Extracts the port from a host:port string
 *
 * @param value Input string in format "hostname:port" or just "hostname"
 * @param outPort Buffer to store the extracted port
 * @param outSize Size of the outPort buffer
 * @return 0 on success, -1 if parameters are invalid, -2 if outPort buffer is too small
 *         If no port is specified in the input string, outPort will be empty
 */
__asm__("\n&FUNC	SETC 'parse_port_string'");
static int
parse_port_string(const char *value, char *outPort, size_t outSize)	
{
	if (!value || !outPort || outSize == 0) {
        return -1;
    }

    const char *colon = strchr(value, ':');
    if (!colon) {
        if (outSize > 0) {
            outPort[0] = '\0';
        }
        return 0; 
    }

    const char *portStr = colon + 1;

    if (*portStr == '\0') {
        if (outSize > 0) {
            outPort[0] = '\0';
        }
        return 0;
    }

    size_t needed = strlen(portStr) + 1; /* +1 for null termination */
    if (needed > outSize) {
        return -2; /* outPort buffer too small */
    }

    strncpy(outPort, portStr, outSize - 1);
    outPort[outSize - 1] = '\0';

    return 0;
}

/**
 * Validates a port string
 * Checks if the port is a valid number between 1 and 65535
 *
 * @param port Port string to validate
 * @return 0 if valid, -1 if invalid
 */
__asm__("\n&FUNC	SETC 'validate_port'");
static int
validate_port(const char *port)
{
    if (!port || !*port) {
        return -1;
    }

    // Check if all characters are digits
    const char *p = port;
    while (*p) {
        if (*p < '0' || *p > '9') {
            return -1;
        }
        p++;
    }

    // Convert to number and validate range
    long value = atol(port);
    if (value < 1 || value > 65535) {
        return -1;
    }

    return 0;
}
