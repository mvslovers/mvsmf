#include <string.h>

#include "subdsn.h"

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'sub_dsn'");
#endif
int
submit_dsname(const char *filename, char *dsname, size_t size)
{
	size_t len = strlen(filename);
	size_t n;

	if (len <= 4 || filename[0] != '/' || filename[1] != '/' ||
	    filename[2] != '\'' || filename[len - 1] != '\'') {
		return -1;
	}

	n = len - 4;
	if (n > DSNAME_MAX || n >= size) {
		return -1;
	}

	memcpy(dsname, &filename[3], n);
	dsname[n] = '\0';
	return 0;
}
