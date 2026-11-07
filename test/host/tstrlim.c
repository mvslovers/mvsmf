/*
 * tstrlim.c - #578: how many data bytes one record of a data set holds.
 *
 * A record of a spanned data set (RECFM=VBS, or VB with BLKSIZE < LRECL+4)
 * holds LRECL-8 bytes, not LRECL-4: libc370's write routine adds the RDW to
 * the record length and then four more before it compares with LRECL, and
 * abends U0002 above it. The write handlers assumed LRECL-4 for every
 * RECFM=V, so a text line of 248..251 bytes on VBS 255/6233 abended the PUT,
 * left the data set empty and answered 500; binary mode cut its pieces at
 * LRECL and failed on every full one.
 *
 * The TU #includes src/reclimit.c, so the real functions the handlers call are
 * what is tested. The RECFM bytes are DCB values: F 0x80, V 0x40, U 0xC0,
 * B 0x10, S 0x08, ASA 0x04, machine 0x02.
 *
 * Runs on host via `mbt test`.
 */
#include <stdio.h>
#include <stddef.h>

#include <mbtcheck.h>

#include "../../src/reclimit.c"

#define F	0x80
#define FB	0x90
#define FBS	0x98	/* standard blocks: S means something else on F */
#define V	0x40
#define VB	0x50
#define VS	0x48
#define VBS	0x58
#define VBA	0x54
#define VBSA	0x5C
#define U	0xC0

int main(void)
{
	printf("=== TSTRLIM: #578 data bytes in one record ===\n");

	/* which formats are spanned */
	CHECK_EQ(reclim_spanned(VBS), 1, "spanned: VBS");
	CHECK_EQ(reclim_spanned(VS), 1, "spanned: VS");
	CHECK_EQ(reclim_spanned(VBSA), 1, "spanned: VBS with ASA control characters");
	CHECK_EQ(reclim_spanned(VB), 0, "not spanned: VB");
	CHECK_EQ(reclim_spanned(V), 0, "not spanned: V");
	CHECK_EQ(reclim_spanned(VBA), 0, "not spanned: VBA");
	CHECK_EQ(reclim_spanned(FBS), 0, "not spanned: FBS, S is standard blocks there");
	CHECK_EQ(reclim_spanned(FB), 0, "not spanned: FB");
	CHECK_EQ(reclim_spanned(U | 0x08), 0, "not spanned: U");

	/* the measured case: VBS, LRECL 255, BLKSIZE 6233 -- 247 is written, 248
	   abended */
	CHECK_EQ(reclim_content_max(VBS, 255, 0), 247, "VBS 255: a line holds 247 bytes");
	CHECK_EQ(reclim_binary_piece(VBS, 255, 0), 247, "VBS 255: binary pieces of 247");
	CHECK_EQ(reclim_content_max(VS, 255, 0), 247, "VS 255: a line holds 247 bytes");
	CHECK_EQ(reclim_binary_piece(VS, 255, 0), 247, "VS 255: binary pieces of 247");

	/* RECFM=V without spanning is as it was: LRECL-4 for a line, LRECL pieces */
	CHECK_EQ(reclim_content_max(VB, 84, 0), 80, "VB 84: a line holds 80 bytes");
	CHECK_EQ(reclim_binary_piece(VB, 84, 0), 84, "VB 84: binary pieces of 84, as before");
	CHECK_EQ(reclim_content_max(V, 255, 0), 251, "V 255: a line holds 251 bytes");
	CHECK_EQ(reclim_binary_piece(V, 255, 0), 255, "V 255: binary pieces of 255, as before");

	/* F and U */
	CHECK_EQ(reclim_content_max(FB, 80, 0), 80, "FB 80: a line holds 80 bytes");
	CHECK_EQ(reclim_binary_piece(FB, 80, 0), 80, "FB 80: binary pieces of 80");
	CHECK_EQ(reclim_content_max(FBS, 80, 0), 80, "FBS 80: not shortened");
	CHECK_EQ(reclim_binary_piece(FBS, 80, 0), 80, "FBS 80: binary pieces of 80");
	CHECK_EQ(reclim_content_max(U, 6233, 1), 6233, "U: the block size");
	CHECK_EQ(reclim_binary_piece(U, 6233, 1), 6233, "U: binary pieces of the block size");

	/* the smallest LRECLs: no room for a byte is 0, which the handlers refuse */
	CHECK_EQ(reclim_content_max(VBS, 9, 0), 1, "VBS 9: one byte");
	CHECK_EQ(reclim_content_max(VBS, 8, 0), 0, "VBS 8: no room");
	CHECK_EQ(reclim_content_max(VBS, 0, 0), 0, "VBS 0: no room, no wrap");
	CHECK_EQ(reclim_binary_piece(VBS, 8, 0), 0, "VBS 8: no binary piece");
	CHECK_EQ(reclim_binary_piece(VBS, 0, 0), 0, "VBS 0: no binary piece, no wrap");
	CHECK_EQ(reclim_content_max(VB, 5, 0), 1, "VB 5: one byte");
	CHECK_EQ(reclim_content_max(VB, 4, 0), 0, "VB 4: no room");
	CHECK_EQ(reclim_content_max(VB, 0, 0), 0, "VB 0: no room, no wrap");

	/* a piece never exceeds what a line holds on a spanned data set, which is
	   what keeps libc370's write from abending */
	CHECK(reclim_binary_piece(VBS, 6233, 0) == reclim_content_max(VBS, 6233, 0),
	      "VBS: a binary piece is a full record");

	return mbt_test_summary("TSTRLIM");
}
