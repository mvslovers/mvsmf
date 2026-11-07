#include <stddef.h>

#include "reclimit.h"

/* See reclimit.h for what each format holds and why. */

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'reclim_spanned'");
#endif
int
reclim_spanned(int recfm)
{
	return (recfm & RECLIM_RECFM_TYPE) == RECLIM_RECFM_V
	    && (recfm & RECLIM_RECFM_S) != 0;
}

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'reclim_content_max'");
#endif
size_t
reclim_content_max(int recfm, size_t eff_lrecl, int is_undefined)
{
	if (is_undefined) {
		return eff_lrecl;
	}

	if ((recfm & RECLIM_RECFM_TYPE) == RECLIM_RECFM_V) {
		size_t overhead = reclim_spanned(recfm) ? 8 : 4;

		return eff_lrecl > overhead ? eff_lrecl - overhead : 0;
	}

	return eff_lrecl;
}

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'reclim_binary_piece'");
#endif
size_t
reclim_binary_piece(int recfm, size_t eff_lrecl, int is_undefined)
{
	if (!is_undefined && reclim_spanned(recfm)) {
		return reclim_content_max(recfm, eff_lrecl, is_undefined);
	}

	return eff_lrecl;
}
