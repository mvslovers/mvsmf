#include <stdlib.h>
#include <string.h>

#include "hostparse.h"

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'parse_host_name'");
#endif
int
parse_host_name(const char *value, char *outHost, size_t outSize)
{
	const char *colon;
	size_t hostLen;

	if (!value || !outHost || outSize == 0) {
		return -1;
	}

	colon = strchr(value, ':');
	hostLen = colon ? (size_t)(colon - value) : strlen(value);

	/* No name at all -- ":8080", or the ":::garbage:::" a broken client sends.
	   This used to return 0 with an empty string, which looked like success,
	   so the caller's fallback to the default host never ran and the client
	   got "zosmf_hostname":"" (issue #260). */
	if (hostLen == 0) {
		return -3;
	}

	if (hostLen >= outSize) {
		return -2;
	}

	strncpy(outHost, value, hostLen);
	outHost[hostLen] = '\0';

	return 0;
}

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'parse_port_string'");
#endif
int
parse_port_string(const char *value, char *outPort, size_t outSize)
{
	const char *colon;
	const char *portStr;

	if (!value || !outPort || outSize == 0) {
		return -1;
	}

	/* No port, or a colon with nothing behind it: not an error, the scheme
	   implies the port (RFC 7230 5.4). The caller supplies the default. */
	colon = strchr(value, ':');
	if (!colon) {
		outPort[0] = '\0';
		return 0;
	}

	portStr = colon + 1;
	if (*portStr == '\0') {
		outPort[0] = '\0';
		return 0;
	}

	if (strlen(portStr) + 1 > outSize) {
		return -2;
	}

	strncpy(outPort, portStr, outSize - 1);
	outPort[outSize - 1] = '\0';

	return 0;
}

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'validate_port'");
#endif
int
validate_port(const char *port)
{
	const char *p;
	long value;

	if (!port || !*port) {
		return -1;
	}

	for (p = port; *p; p++) {
		if (*p < '0' || *p > '9') {
			return -1;
		}
	}

	value = atol(port);
	if (value < 1 || value > 65535) {
		return -1;
	}

	return 0;
}
