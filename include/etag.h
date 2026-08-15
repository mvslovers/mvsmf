#ifndef ETAG_H
#define ETAG_H

/**
 * @file etag.h
 * @brief ETag computation and If-Match parsing (issue #152)
 *
 * An ETag is an opaque version stamp over the content of a data set or a
 * PDS member. It exists for one purpose: to let a client detect that the
 * resource changed between its read and its write, so a save cannot silently
 * discard someone else's edit ("lost update").
 *
 * The value is a CRC32 over the raw record stream plus the total byte count,
 * rendered as 16 hex digits. Deliberately *not* a hash of the bytes sent to
 * the client: those depend on X-IBM-Data-Type and on the trailing-blank
 * stripping the text path applies, so a client reading text and writing
 * binary would collide with itself. Hashing the records instead keeps one
 * stamp per resource state, whatever mode it is read in.
 *
 * The CRC is computed table-free. A 1 KB lookup table would be read-only and
 * therefore RENT-safe, but at member sizes the bitwise loop costs nothing and
 * the question does not need asking.
 *
 * Nothing here touches MVS services or the FILE control block, so the module
 * compiles and unit-tests natively (test/host/tstetag.c). The record reading
 * itself lives in dsapi.c, next to the DCB knowledge it needs.
 */

#include <stddef.h>

/** @brief Hex characters in an ETag value, excluding the terminator */
#define ETAG_LEN	16

/** @brief Buffer size required to hold an ETag value */
#define ETAG_SIZE	(ETAG_LEN + 1)

/**
 * @brief Running ETag computation state
 *
 * Plain data, kept by the caller on the stack -- no writable static, which
 * would abend S0C4 in the RENT-linked module.
 */
typedef struct {
	unsigned int crc;	/**< running CRC32, pre-final-inversion */
	unsigned int len;	/**< total bytes folded in so far */
} ETAGCTX;

/**
 * @brief Starts an ETag computation
 *
 * @param ctx Computation state to initialize
 */
void etag_init(ETAGCTX *ctx) asm("ETG0001");

/**
 * @brief Folds one record into a running ETag computation
 *
 * The record length is folded in alongside the data, so record boundaries
 * are part of the stamp: two records "AB" + "C" do not produce the same
 * value as "A" + "BC".
 *
 * @param ctx Computation state
 * @param buf Record data
 * @param len Record length in bytes
 */
void etag_update(ETAGCTX *ctx, const void *buf, size_t len) asm("ETG0002");

/**
 * @brief Renders the finished ETag as a hex string
 *
 * @param ctx Computation state
 * @param out Output buffer, at least ETAG_SIZE bytes
 * @param outlen Size of the output buffer
 * @return 0 on success, -1 if the buffer is too small
 */
int etag_final(const ETAGCTX *ctx, char *out, size_t outlen) asm("ETG0003");

/**
 * @brief Tests an If-Match header value against a computed ETag
 *
 * Accepts what clients actually send: a bare value, a quoted one, a weak
 * validator ("W/" prefix), a comma-separated list of any of those, and the
 * wildcard "*". The comparison is case-insensitive over the hex digits.
 *
 * "*" means "the resource must exist"; existence is the caller's test -- it
 * only has an ETag to pass in if the read succeeded -- so "*" matches here.
 *
 * @param header If-Match header value as received
 * @param etag Currently computed ETag of the resource
 * @return 1 if the precondition holds, 0 if it fails
 */
int etag_matches(const char *header, const char *etag) asm("ETG0004");

/**
 * @brief Tests whether the client asked for an ETag
 *
 * True for X-IBM-Return-Etag: true, case-insensitive. Any other value is
 * treated as "no" -- an ETag costs an extra read pass over the resource, so
 * it is computed only when asked for.
 *
 * @param value X-IBM-Return-Etag header value, or NULL if absent
 * @return 1 if an ETag was requested, 0 otherwise
 */
int etag_requested(const char *value) asm("ETG0005");

#endif // ETAG_H
