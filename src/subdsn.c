#include <string.h>

#include "subdsn.h"

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'sub_dsn'");
#endif
int
submit_dsname(const char *filename, char *dsname, size_t size)
{
	size_t len = strlen(filename);
	const char *name;
	const char *paren;
	size_t n;
	size_t dsn_len;

	if (len <= 4 || filename[0] != '/' || filename[1] != '/' ||
	    filename[2] != '\'' || filename[len - 1] != '\'') {
		return -1;
	}

	name = &filename[3];
	n = len - 4;
	paren = memchr(name, '(', n);

	if (paren) {
		size_t mem_len;

		dsn_len = (size_t)(paren - name);
		if (name[n - 1] != ')') {
			return -1;
		}
		mem_len = n - dsn_len - 2;
		if (mem_len == 0 || mem_len > MEMBER_MAX) {
			return -1;
		}
	} else {
		dsn_len = n;
	}

	if (dsn_len == 0 || dsn_len > DSNAME_MAX || n >= size) {
		return -1;
	}

	memcpy(dsname, name, n);
	dsname[n] = '\0';
	return 0;
}
