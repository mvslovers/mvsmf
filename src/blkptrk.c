#include "blkptrk.h"

#define CELL_BYTES	32u
#define CELLS_3380	1499u
#define DEVTK_3380	(CELLS_3380 * CELL_BYTES)
#define CELLS_BLOCK_FIX	15u
#define CELLS_DATA_FIX	12u

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'blks_per_trk'");
#endif
unsigned
blocks_per_track(unsigned devtk, unsigned devov, unsigned devk,
		 unsigned devfg, unsigned blksz)
{
	unsigned overhead;
	unsigned cells;

	if (blksz == 0) return 0;

	if (devfg & DS4DEVFG_CELLS) {
		/* only the 3380 geometry is known; anything else is "unknown" */
		if (devtk != DEVTK_3380) return 0;
		cells = CELLS_BLOCK_FIX
		      + (blksz + CELLS_DATA_FIX + CELL_BYTES - 1) / CELL_BYTES;
		return CELLS_3380 / cells;
	}

	if (devov < devk) return 0;
	overhead = devov - devk;
	if (devtk <= overhead) return 0;
	return (devtk - overhead) / (overhead + blksz);
}
