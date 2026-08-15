/* ETAG.C
** ETag computation and If-Match parsing for the data set API (issue #152)
** and the USS file API (issue #264).
**
** See include/etag.h for what an ETag is for and why it is computed over the
** stored bytes. This file is deliberately free of MVS services and of the
** FILE control block, so it builds and unit-tests on the host as well
** (test/host/tstetag.c).
*/

#include <stdio.h>
#include <string.h>

#include "etag.h"

/* Reflected CRC32 polynomial (IEEE 802.3), the usual 0x04C11DB7 reversed. */
#define ETAG_POLY	0xEDB88320U

/* Fold one byte into the running CRC. Bitwise, no lookup table: at the size
** of a PDS member the eight iterations per byte are not measurable, and a
** table would raise a RENT question that is not worth answering. */
#ifdef __MVS__
__asm__("\n&FUNC	SETC 'etag_byte'");
#endif
static unsigned int
etag_byte(unsigned int crc, unsigned char b)
{
	int k;

	crc ^= (unsigned int) b;
	for (k = 0; k < 8; k++) {
		crc = (crc & 1U) ? ((crc >> 1) ^ ETAG_POLY) : (crc >> 1);
	}

	return crc;
}

/* Uppercase a hex digit. Written as an explicit range test rather than via
** toupper() because the runtime is EBCDIC: 'a'..'f' and 'A'..'F' are each
** contiguous there, which is all this needs, but the full alphabet is not. */
#ifdef __MVS__
__asm__("\n&FUNC	SETC 'etag_fold'");
#endif
static char
etag_fold(char c)
{
	if (c >= 'a' && c <= 'f') {
		return (char) (c - 'a' + 'A');
	}

	return c;
}

void
etag_init(ETAGCTX *ctx)
{
	if (!ctx) {
		return;
	}

	ctx->crc = 0xFFFFFFFFU;
	ctx->len = 0;
}

void
etag_update(ETAGCTX *ctx, const void *buf, size_t len)
{
	const unsigned char	*p = (const unsigned char *) buf;
	unsigned int		 crc;
	unsigned int		 n;
	size_t			 i;

	if (!ctx || !buf) {
		return;
	}

	crc = ctx->crc;

	/* Fold the record length in first, so record boundaries are part of
	   the stamp. Without this a variable-length data set could be
	   re-split into different records and still hash the same. */
	n = (unsigned int) len;
	crc = etag_byte(crc, (unsigned char) ((n >> 24) & 0xFF));
	crc = etag_byte(crc, (unsigned char) ((n >> 16) & 0xFF));
	crc = etag_byte(crc, (unsigned char) ((n >> 8) & 0xFF));
	crc = etag_byte(crc, (unsigned char) (n & 0xFF));

	for (i = 0; i < len; i++) {
		crc = etag_byte(crc, p[i]);
	}

	ctx->crc = crc;
	ctx->len += (unsigned int) len;
}

void
etag_update_raw(ETAGCTX *ctx, const void *buf, size_t len)
{
	const unsigned char	*p = (const unsigned char *) buf;
	unsigned int		 crc;
	size_t			 i;

	if (!ctx || !buf) {
		return;
	}

	crc = ctx->crc;

	/* No length fold, deliberately -- see etag.h. A byte stream has no
	   record boundaries to preserve, and folding the length of each chunk
	   would make the stamp depend on how the reader happened to split the
	   file rather than on its content. The total still reaches the value
	   through ctx->len in etag_final(). */
	for (i = 0; i < len; i++) {
		crc = etag_byte(crc, p[i]);
	}

	ctx->crc = crc;
	ctx->len += (unsigned int) len;
}

int
etag_final(const ETAGCTX *ctx, char *out, size_t outlen)
{
	if (!ctx || !out || outlen < ETAG_SIZE) {
		return -1;
	}

	/* CRC32 and the byte count together. The length alone catches the
	   common "line added or removed" edit even in the vanishing case of a
	   CRC collision. */
	snprintf(out, outlen, "%08X%08X", ctx->crc ^ 0xFFFFFFFFU, ctx->len);

	return 0;
}

int
etag_matches(const char *header, const char *etag)
{
	const char	*p = header;

	if (!header || !etag) {
		return 0;
	}

	/* Comma-separated list of entries, each optionally weak ("W/") and
	   optionally quoted. Any one of them matching satisfies If-Match. */
	while (*p) {
		const char	*val;
		size_t		 i;
		int		 quoted = 0;

		while (*p == ' ' || *p == '\t' || *p == ',') {
			p++;
		}
		if (!*p) {
			break;
		}

		/* "*" is the wildcard: the resource only has to exist, and it
		   does -- the caller computed an ETag for it. */
		if (*p == '*') {
			return 1;
		}

		if (p[0] == 'W' && p[1] == '/') {
			p += 2;
		}
		if (*p == '"') {
			quoted = 1;
			p++;
		}

		val = p;
		while (*p && *p != ',' && *p != '"') {
			p++;
		}

		/* Compare the entry against the computed value. An unquoted
		   entry may carry trailing blanks; walk only as far as the
		   ETag is long and require the remainder to be padding. */
		for (i = 0; i < ETAG_LEN; i++) {
			if (val + i >= p) {
				break;
			}
			if (etag_fold(val[i]) != etag_fold(etag[i])) {
				break;
			}
		}

		if (i == ETAG_LEN) {
			const char *rest = val + ETAG_LEN;
			while (rest < p && (*rest == ' ' || *rest == '\t')) {
				rest++;
			}
			if (rest == p) {
				return 1;
			}
		}

		if (quoted && *p == '"') {
			p++;
		}
		while (*p && *p != ',') {
			p++;
		}
	}

	return 0;
}

int
etag_requested(const char *value)
{
	const char	yes[] = "true";
	size_t		i;

	if (!value) {
		return 0;
	}

	while (*value == ' ' || *value == '\t') {
		value++;
	}

	for (i = 0; i < sizeof(yes) - 1; i++) {
		char c = value[i];
		if (c >= 'A' && c <= 'Z') {
			c = (char) (c - 'A' + 'a');
		}
		if (c != yes[i]) {
			return 0;
		}
	}

	value += sizeof(yes) - 1;
	while (*value == ' ' || *value == '\t') {
		value++;
	}

	return (*value == '\0');
}
