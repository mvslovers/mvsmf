#include <limits.h>
#include <stdlib.h>
#include <string.h>

#include "jclines.h"

/*
 * JCL line table growth. See jclines.h for the shape of the table and the
 * failure contract; issue #220 for why the failure contract matters.
 *
 * Lives in its own translation unit so test/host/tstjcln.c can pull in this
 * source with a fault-injecting realloc and exercise the real function --
 * jobsapi.c itself cannot compile on the host.
 */

/* Bytes per line slot: an 80-byte card image plus its NUL terminator. The
 * callers in jobsapi.c size their initial calloc() with the same stride. */
#define LINE_STRIDE 81

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'grow_lines_arrays'");
#endif
int
grow_lines_arrays(char ***lines_p, char **lines_buf_p, int *capacity_p, int required)
{
	int    old_cap;
	int    new_cap;
	char  *new_buf;
	char **new_lines;
	int    i;

	old_cap = *capacity_p;
	if (required <= old_cap) {
		return 0;
	}

	new_cap = old_cap;
	while (new_cap < required) {
		if (new_cap > INT_MAX / 2) {
			return -1;      /* doubling would overflow the int capacity */
		}
		new_cap *= 2;
	}

	/*
	 * Order matters, and it is the fix for #220.
	 *
	 * The pointer array is grown FIRST because that realloc cannot invalidate
	 * lines_buf: if it fails, nothing has been touched and every out-param is
	 * still exactly what the caller passed in.
	 *
	 * The buffer is grown SECOND. A failing realloc leaves its original block
	 * intact, so entries [0, old_cap) of new_lines -- copied over by the
	 * successful realloc above -- still address live storage. new_lines must
	 * nevertheless be handed back, because the old array was freed by that
	 * realloc; but *capacity_p and *lines_buf_p stay untouched, so the caller
	 * still sees the same capacity over the same buffer. The only residue is
	 * an over-allocated pointer array, released by the caller's normal free().
	 *
	 * Growing the buffer first (as this did before) cannot offer that: by the
	 * time the second realloc fails the old buffer is already gone, and every
	 * entry in the caller's pointer array dangles.
	 */
	new_lines = (char **)realloc(*lines_p, (size_t)new_cap * sizeof(char *));
	if (!new_lines) {
		return -1;
	}

	new_buf = (char *)realloc(*lines_buf_p, (size_t)new_cap * LINE_STRIDE);
	if (!new_buf) {
		*lines_p = new_lines;
		return -1;
	}
	memset(new_buf + (size_t)old_cap * LINE_STRIDE, 0,
		   (size_t)(new_cap - old_cap) * LINE_STRIDE);

	for (i = 0; i < new_cap; i++) {
		new_lines[i] = new_buf + (i * LINE_STRIDE);
	}

	*lines_buf_p = new_buf;
	*lines_p     = new_lines;
	*capacity_p  = new_cap;
	return 0;
}
