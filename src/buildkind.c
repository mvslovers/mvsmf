#include <string.h>

#include "buildkind.h"

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'build_is_dev'");
#endif
int
build_is_dev(const char *version)
{
	const char *suffix = "-dev";
	size_t len;
	size_t slen = 4;

	if (!version) {
		return 0;
	}

	len = strlen(version);
	if (len < slen) {
		return 0;
	}

	return strcmp(version + len - slen, suffix) == 0;
}
