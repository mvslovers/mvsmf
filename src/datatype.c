#include <ctype.h>
#include <string.h>

#include "datatype.h"

/* Does the len bytes at s spell word, ignoring case? word is a literal, so
   its length bounds the comparison and s needs no terminator inside len. */
static int
token_is(const char *s, size_t len, const char *word)
{
	size_t i;

	if (len != strlen(word)) {
		return 0;
	}
	for (i = 0; i < len; i++) {
		if (toupper((unsigned char)s[i]) != toupper((unsigned char)word[i])) {
			return 0;
		}
	}
	return 1;
}

/* The names the reference accepts for the two tables libhttpd has. Measured:
   "IBM-037", "037", "IBM-1047" and "1047" are answered, "IBM-37" and "CP037"
   are refused -- so no spelling beyond these four is invented here. */
static int
encoding_of(const char *s, size_t len)
{
	if (token_is(s, len, "IBM-037") || token_is(s, len, "037")) {
		return FILE_ENC_IBM037;
	}
	if (token_is(s, len, "IBM-1047") || token_is(s, len, "1047")) {
		return FILE_ENC_IBM1047;
	}
	return -1;
}

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'parse_data_type'");
#endif
int
parse_data_type(const char *value, int *data_type, int *encoding)
{
	static const char key[] = "fileEncoding=";
	const size_t keylen = sizeof(key) - 1;
	const char *p;
	size_t len;

	*data_type = DATA_TYPE_TEXT;
	*encoding = FILE_ENC_DEFAULT;

	if (!value) {
		return 0;
	}

	len = strcspn(value, ";");
	if (token_is(value, len, "binary")) {
		*data_type = DATA_TYPE_BINARY;
	} else if (token_is(value, len, "record")) {
		*data_type = DATA_TYPE_RECORD;
	}

	/* binary and record move bytes untranslated, so an encoding means
	   nothing to them -- the reference does not even validate it. */
	if (*data_type != DATA_TYPE_TEXT) {
		return 0;
	}

	for (p = value + len; *p == ';'; p += len) {
		p++;
		len = strcspn(p, ";");

		/* No blank trimming: "text; fileEncoding=X" is not recognised by the
		   reference either, and it answers that with the default. */
		if (len < keylen || !token_is(p, keylen, key)) {
			continue;
		}
		if (len == keylen) {
			/* "fileEncoding=" with no value is the default as well. */
			continue;
		}

		*encoding = encoding_of(p + keylen, len - keylen);
		if (*encoding < 0) {
			*encoding = FILE_ENC_DEFAULT;
			return -1;
		}
		return 0;
	}

	return 0;
}
