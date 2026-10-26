#include <errno.h>
#include <stddef.h>

#include "listfail.h"

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'list_outcome'");
#endif
int list_outcome(const void *list, int err)
{
	if (list != NULL) {
		return LIST_FOUND;
	}

	if (err == 0) {
		return LIST_EMPTY;
	}

	if (err == ENOMEM) {
		return LIST_NOSTOR;
	}

	return LIST_FAILED;
}
