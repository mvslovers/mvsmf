#include <string.h>

#include "reqpath.h"

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'request_path_copy'");
#endif
int
request_path_copy(const char *raw, char *out, size_t outSize)
{
	if (!raw || !out || outSize == 0) {
		return -1;
	}

	strncpy(out, raw, outSize - 1);
	out[outSize - 1] = '\0';
	return 0;
}
