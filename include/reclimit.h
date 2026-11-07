#ifndef RECLIMIT_H
#define RECLIMIT_H

#include <stddef.h>

/**
 * @file reclimit.h
 * @brief How many data bytes one record of a data set holds, for the write
 *        paths in dsapi.c.
 *
 * The answer depends on the record format, and the access method is stricter
 * than the DCB suggests:
 *
 *   - RECFM=F: LRECL.
 *   - RECFM=U: the block size (there is no LRECL).
 *   - RECFM=V: LRECL-4. The RDW is not content.
 *   - RECFM=V, spanned (VBS, or VB with BLKSIZE < LRECL+4, which libc370's
 *     OPEN exit turns into a spanned data set): LRECL-8. libc370's write
 *     routine (@@awrite.asm, WRITEVAT) checks the length of the record plus
 *     its RDW, plus four more, against LRECL, and abends U0002 above it. One
 *     byte more than this and the PUT abends with the data set left empty
 *     (#578).
 *
 * The RECFM byte is the DCB's, as libc370 hands it over in FILE.recfm; the
 * bit values are repeated here so that the host test needs no libc370 header.
 */
#define RECLIM_RECFM_TYPE	0xC0	/* mask for F, V, U                     */
#define RECLIM_RECFM_V		0x40	/* variable                             */
#define RECLIM_RECFM_S		0x08	/* with V: spanned records              */

/** Non-zero for a RECFM=V data set whose records are spanned. */
int reclim_spanned(int recfm)	asm("MFRLSPAN");

/**
 * Usable data bytes in one record: the limit a text line is cut at, and the
 * cap on a RECFM=V record. 0 when the LRECL is too small to hold a byte.
 *
 * eff_lrecl is the LRECL, or the BLKSIZE where RECFM=U leaves LRECL 0.
 */
size_t reclim_content_max(int recfm, size_t eff_lrecl, int is_undefined)
	asm("MFRLCMAX");

/**
 * The size of the pieces a binary upload is cut into, which is also the size
 * the last short piece is padded with zeros to.
 *
 * LRECL for every format but a spanned one: that is how binary has always been
 * cut, and RECFM=V without spanning is not changed here. A spanned data set
 * takes LRECL-8, the most a record holds (see above). 0 when the LRECL is too
 * small to hold a byte.
 */
size_t reclim_binary_piece(int recfm, size_t eff_lrecl, int is_undefined)
	asm("MFRLPIEC");

#endif /* RECLIMIT_H */
