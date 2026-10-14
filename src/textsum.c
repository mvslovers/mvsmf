#include "textsum.h"

/*
 * 32-bit FNV-1a. See textsum.h for what it is used for (#425).
 */

#define FNV_BASIS	0x811C9DC5u
#define FNV_PRIME	0x01000193u

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'text_sum'");
#endif
unsigned
text_sum(const unsigned char *p, unsigned len)
{
	unsigned h = FNV_BASIS;

	while (len-- > 0) {
		h ^= *p++;
		h *= FNV_PRIME;
	}

	return h & 0xFFFFFFFFu;
}
