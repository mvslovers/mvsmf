#ifndef TEXTSUM_H
#define TEXTSUM_H

/*
 * Checksums over MVSMF's own loaded code (#425).
 *
 * In #425 the code of a function entry was not what had been linked: on a
 * stand whose STEPLIB is not APF-authorized the module sits in key-8 storage,
 * and a stray store lands in it silently. The first sign was an S0C7 at the
 * damaged entry, by which time the bytes that replaced the code were gone.
 *
 * MVSMF is RENT, so its loaded text must not change for as long as it stays
 * at one load address. /zosmf/test?fn=textsum reports a sum per block of the
 * module; sampled over time, a block whose sum changes at the same load point
 * has been overwritten -- before anything executes it -- and fn=textdump
 * reads the bytes that are there now.
 *
 * The sum is 32-bit FNV-1a: no table, so nothing static in a RENT module,
 * and every byte changes it. It only has to tell "same" from "different"
 * between two samples of the same build; it is not a cryptographic hash.
 */

/* Bytes per reported block. One page: small enough to name the damage,
   large enough that a 400 K module is a hundred sums. */
#define TEXTSUM_BLOCK	4096u

/* The most fn=textdump returns in one call. */
#define TEXTDUMP_MAX	256u

/**
 * 32-bit FNV-1a over len bytes. A length of 0 gives the offset basis,
 * 0x811C9DC5.
 */
unsigned text_sum(const unsigned char *p, unsigned len) asm("TXTSUM");

#endif /* TEXTSUM_H */
