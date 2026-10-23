#ifndef BLKPTRK_H
#define BLKPTRK_H

/*
 * Blocks per track of a non-keyed data set, from the geometry in the
 * format-4 DSCB of its volume (#439).
 *
 * The record-count estimate in dsapi.c turns DS1LSTAR (track, block) into a
 * number of records, which needs the blocks that fit on one track. How that
 * is counted depends on the device, and the DSCB says which way:
 *
 *   DS4DEVFG X'08'  byte overhead (3330, 3340, 3350, 3375): devtk is the track
 *                   capacity in bytes, devov the keyed and devk the
 *                   non-keyed differential, so a block costs
 *                   (devov - devk) + blksz bytes.
 *   DS4DEVFG X'20'  cell arithmetic (3380): devtk is the track length in
 *                   cells of 32 bytes times 32 (1499 cells = 47968), and a
 *                   non-keyed block takes 15 + ceil((blksz + 12) / 32) cells.
 *                   devov and devk are 0 on such a device.
 *
 * Before libc370 2.24.0 corrected struct dscb4, __dscbv() handed dsapi.c
 * shifted values and the answer was always "unknown"; with correct fields the
 * byte formula alone gives too many blocks on a 3380.
 */

#define DS4DEVFG_BYTES	0x08
#define DS4DEVFG_CELLS	0x20

/* Blocks that fit on one track, or 0 when the device is not one this knows
   (a 3390 has its own cell formula; nothing here guesses it). */
unsigned blocks_per_track(unsigned devtk, unsigned devov, unsigned devk,
			  unsigned devfg, unsigned blksz);

/*
 * Device type of a volume, from DS4DEVTK of its format-4 DSCB (#443): the
 * track capacity identifies the device, the tracks per cylinder do not (a
 * 3380 and a 3390 both have 15). DS4DEVTK is the usable bytes per track plus
 * the per-block overhead (a 3390: 56664 + 2122 = 58786). 3350 (19254), 3380
 * (47968) and 3390 (58786) are measured; 3330 (13165) and 3375 (36000) are
 * the values libc370's tstdscb4 lists for those devices, not measured here.
 */
#define DEVICE_UNKNOWN	"????"

/* "3330", "3350", "3375", "3380" or "3390"; DEVICE_UNKNOWN for anything else,
   0 (the DSCB could not be read) included. Never a guess. */
const char *device_name(unsigned devtk);

#endif
