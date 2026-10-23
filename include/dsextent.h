#ifndef DSEXTENT_H
#define DSEXTENT_H

/*
 * Tracks allocated to a data set, from its extents (#370).
 *
 * A format-1 DSCB holds three extents. A fourth and every later one live in
 * the format-3 DSCB that DS1PTRDS points to: four extents behind the key, a
 * format id of X'F3', nine more, and the pointer to the next format-3 DSCB.
 * Summing the format-1 extents alone is right up to three extents and short
 * from the fourth on -- 660 tracks reported for a data set of 750.
 *
 * The functions here work on the raw bytes of the DSCBs, so they run on the
 * host as well; dsapi.c reads the DSCBs and supplies the reader.
 */

#define DSX_EXTENT_LEN	10	/* flag, seq, lower CCHH, upper CCHH */
#define DSX_F1_EXTENTS	3	/* extents in the format-1 DSCB */
#define DSX_PTR_LEN	5	/* CCHHR */

/* The format-3 DSCB as OBTAIN (SEEK) returns it: the 4-byte key X'03030303'
   first, so the offsets are those of struct dscb3. */
#define DSX_F3_LEN	140
#define DSX_F3_EXT4_OFF	4	/* extents 4-7 */
#define DSX_F3_EXT4_CNT	4
#define DSX_F3_FMTID_OFF 44
#define DSX_F3_FMTID	0xF3
#define DSX_F3_EXT9_OFF	45	/* extents 8-16 */
#define DSX_F3_EXT9_CNT	9
#define DSX_F3_PTR_OFF	135

/* A non-VSAM data set has 16 extents at most, which is one format-3 DSCB.
   The bound only keeps a damaged chain from looping. */
#define DSX_MAX_F3	4

#define DSX_OK		0
#define DSX_ERR_READ	1	/* the reader failed */
#define DSX_ERR_CHAIN	2	/* NOEPV says more extents than the chain holds */
#define DSX_ERR_FORMAT	3	/* the DSCB pointed to is not a format-3 DSCB */

/* Reads the DSCB at cchhr into area (DSX_F3_LEN bytes); 0 on success. */
typedef int (*DSX_READ3)(const unsigned char cchhr[DSX_PTR_LEN],
			 unsigned char area[DSX_F3_LEN], void *ctx);

/* Tracks of one extent; tpc is the tracks per cylinder of the volume. */
unsigned extent_tracks(const unsigned char *extent, unsigned tpc);

/* Sum the noepv extents of a data set into *trks. f1ext is the 30 bytes of
   extents in the format-1 DSCB, f1ptr its DS1PTRDS. On anything but DSX_OK
   *trks is left alone: a partial sum is a wrong size. */
int dscb_alloc_tracks(const unsigned char *f1ext, const unsigned char *f1ptr,
		      unsigned noepv, unsigned tpc,
		      DSX_READ3 read3, void *ctx, unsigned *trks);

#endif
