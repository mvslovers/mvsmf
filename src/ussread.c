/*
 * ussread.c - the read-translate-send loop of the USS file GET (issue #423).
 *
 * See include/ussread.h for why this is its own TU.
 *
 * Portable C on purpose: no httpd headers, no libufs, no statics. The host
 * test #includes it (test/host/tstussrd.c) so the loop it drives is the one
 * that runs on MVS, not a copy of it.
 */

#include "ussread.h"

#ifdef __MVS__
__asm__("\n&FUNC    SETC 'uss_stream_file'");
#endif
int
uss_stream_file(void *ctx, const USS_READ_OPS *ops,
	unsigned char *buf, unsigned bufsz, int *read_rc)
{
	unsigned n;

	*read_rc = 0;

	while ((n = ops->read(ctx, buf, bufsz)) > 0) {
		if (ops->xlate) {
			ops->xlate(ctx, buf, n);
		}
		if (ops->send(ctx, buf, (int)n) < 0) {
			return -1;
		}
	}

	// ufs_fread() returns 0 for a failed read exactly as it does at the end
	// of the file; only the handle's error state tells them apart. Looking
	// is not optional: the status is long gone, so a short body that ends
	// cleanly is the one outcome the client cannot tell from a whole file.
	*read_rc = ops->failed(ctx);
	if (*read_rc != 0) {
		return -1;
	}

	return 0;
}
