#ifndef DATATYPE_H
#define DATATYPE_H

/**
 * @file datatype.h
 * @brief Parsing the `X-IBM-Data-Type` request header.
 *
 * The header selects the transfer mode and, for text, the EBCDIC code page the
 * stored data is in:
 *
 *   X-IBM-Data-Type: text;fileEncoding=IBM-1047
 *
 * That second half is what Zowe sends when a user picks an encoding (#391),
 * and it used to be dropped: the old parser only compared the first four
 * bytes against "text", so IBM-1047 content was always translated as CP037.
 * The same parser compared "binary" and "record" with strcmp, so `BINARY` or
 * `binary;anything` was downloaded as *text* -- translated.
 *
 * The rules below are measured on a real z/OSMF (#391), not taken from the
 * documentation:
 *
 *   - the type is the token before the first ';', case-insensitive;
 *   - parameters follow, separated by ';' with no blank trimming -- a
 *     "text; fileEncoding=X" is not recognised and the default applies;
 *   - the key `fileEncoding=` is case-insensitive, and so is its value;
 *   - an empty value, an absent parameter, and unknown parameters mean the
 *     default;
 *   - binary and record ignore fileEncoding entirely, even an invalid one;
 *   - an encoding the server cannot translate fails the request.
 *
 * Pure string code -- no session, no httpd, no MVS -- so that
 * test/host/tstdtyp.c can drive it on the host. Header values arrive in
 * EBCDIC on MVS; every comparison here is against a character literal and
 * goes through toupper(), so it holds in either character set.
 */

#define DATA_TYPE_TEXT     1
#define DATA_TYPE_BINARY   2
#define DATA_TYPE_RECORD   3

/** No fileEncoding given: the caller's API decides (CP037 for data sets). */
#define FILE_ENC_DEFAULT   0
#define FILE_ENC_IBM037    1
#define FILE_ENC_IBM1047   2

/**
 * Parse an `X-IBM-Data-Type` value.
 *
 * @param value      header value; NULL means the header was absent (text)
 * @param data_type  receives DATA_TYPE_*; an unknown type is text, as before
 * @param encoding   receives FILE_ENC_*; always FILE_ENC_DEFAULT unless the
 *                   type is text and a supported fileEncoding was given
 * @return 0, or -1 if a text request names an encoding that is not
 *         supported. Both outputs are set either way.
 */
int parse_data_type(const char *value, int *data_type, int *encoding)
															asm("MFDTYPRS");

#endif /* DATATYPE_H */
