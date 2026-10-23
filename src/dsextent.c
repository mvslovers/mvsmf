#include <string.h>

#include "dsextent.h"

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'be16'");
#endif
static unsigned
be16(const unsigned char *p)
{
	return ((unsigned)p[0] << 8) | (unsigned)p[1];
}

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'extent_trks'");
#endif
unsigned
extent_tracks(const unsigned char *extent, unsigned tpc)
{
	const unsigned char *lower = extent + 2;
	const unsigned char *upper = extent + 6;

	return (be16(upper) - be16(lower)) * tpc
	     + (be16(upper + 2) - be16(lower + 2)) + 1;
}

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'ptr_zero'");
#endif
static int
ptr_is_zero(const unsigned char *ptr)
{
	unsigned i;

	for (i = 0; i < DSX_PTR_LEN; i++) {
		if (ptr[i]) return 0;
	}
	return 1;
}

/* Sum up to want extents from count slots at base; returns how many it took. */
#ifdef __MVS__
__asm__("\n&FUNC	SETC 'sum_group'");
#endif
static unsigned
sum_group(const unsigned char *base, unsigned count, unsigned want,
	  unsigned tpc, unsigned *total)
{
	unsigned e;

	for (e = 0; e < count && e < want; e++) {
		*total += extent_tracks(base + e * DSX_EXTENT_LEN, tpc);
	}
	return e;
}

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'dscb_alloc'");
#endif
int
dscb_alloc_tracks(const unsigned char *f1ext, const unsigned char *f1ptr,
		  unsigned noepv, unsigned tpc,
		  DSX_READ3 read3, void *ctx, unsigned *trks)
{
	unsigned char area[DSX_F3_LEN];
	unsigned char ptr[DSX_PTR_LEN];
	unsigned total = 0;
	unsigned left = noepv;
	unsigned hops;

	left -= sum_group(f1ext, DSX_F1_EXTENTS, left, tpc, &total);
	memcpy(ptr, f1ptr, DSX_PTR_LEN);

	for (hops = 0; left > 0; hops++) {
		if (hops >= DSX_MAX_F3 || ptr_is_zero(ptr)) return DSX_ERR_CHAIN;
		if (read3(ptr, area, ctx) != 0) return DSX_ERR_READ;
		if (area[DSX_F3_FMTID_OFF] != DSX_F3_FMTID) return DSX_ERR_FORMAT;

		left -= sum_group(area + DSX_F3_EXT4_OFF, DSX_F3_EXT4_CNT, left,
				  tpc, &total);
		left -= sum_group(area + DSX_F3_EXT9_OFF, DSX_F3_EXT9_CNT, left,
				  tpc, &total);
		memcpy(ptr, area + DSX_F3_PTR_OFF, DSX_PTR_LEN);
	}

	*trks = total;
	return DSX_OK;
}
