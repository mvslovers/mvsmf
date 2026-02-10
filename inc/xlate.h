#ifndef XLATE_H
#define XLATE_H

/**
 * @file xlate.h
 * @brief IBM-1047 ASCII/EBCDIC translation tables and conversion functions
 *
 * Provides mvsMF's own code page translation using IBM-1047, replacing
 * the HTTPD server's built-in tables which use a non-standard mapping
 * (e.g. pipe character '|' is incorrectly translated).
 */

/**
 * @brief ASCII to EBCDIC translation table (IBM-1047)
 *
 * 256-byte lookup table indexed by ASCII code point,
 * returning the corresponding EBCDIC code point.
 */
extern const unsigned char asc2ebc_1047[256] asm("XLT0003");

/**
 * @brief EBCDIC to ASCII translation table (IBM-1047)
 *
 * 256-byte lookup table indexed by EBCDIC code point,
 * returning the corresponding ASCII code point.
 */
extern const unsigned char ebc2asc_1047[256] asm("XLT0004");

/**
 * @brief Converts buffer from ASCII to EBCDIC in-place (IBM-1047)
 *
 * @param buf Buffer to convert
 * @param len Number of bytes to convert
 */
void mvsmf_atoe(unsigned char *buf, int len) asm("XLT0001");

/**
 * @brief Converts buffer from EBCDIC to ASCII in-place (IBM-1047)
 *
 * @param buf Buffer to convert
 * @param len Number of bytes to convert
 */
void mvsmf_etoa(unsigned char *buf, int len) asm("XLT0002");

#endif /* XLATE_H */
