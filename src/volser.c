#include <string.h>

#include "volser.h"

/* Spelled out rather than asked of isalnum(): the EBCDIC letters have gaps, and
   a national character is a volume serial character only in this set. */
#define VOLSER_CHARS	"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789$#@"

static char
volser_upper(char ch)
{
	if (ch >= 'a' && ch <= 'i') return (char) (ch - 'a' + 'A');
	if (ch >= 'j' && ch <= 'r') return (char) (ch - 'j' + 'J');
	if (ch >= 's' && ch <= 'z') return (char) (ch - 's' + 'S');
	return ch;
}

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'volser_normalize'");
#endif
int
volser_normalize(const char *value, char *out, size_t size)
{
	char	folded[VOLSER_SIZE];
	size_t	n;
	size_t	i;

	if (!value || !out || size < VOLSER_SIZE) {
		return -1;
	}

	n = strlen(value);
	if (n == 0 || n > VOLSER_LEN) {
		return -1;
	}

	for (i = 0; i < n; i++) {
		folded[i] = volser_upper(value[i]);
		if (strchr(VOLSER_CHARS, folded[i]) == NULL) {
			return -1;
		}
	}
	folded[n] = '\0';

	memcpy(out, folded, n + 1);
	return 0;
}

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'volser_verdict'");
#endif
int
volser_verdict(const char *requested, int located, const char *cat_volser)
{
	char	want[VOLSER_SIZE];
	char	padded[VOLSER_LEN];
	size_t	n;

	if (volser_normalize(requested, want, sizeof(want)) != 0) {
		return VOLSER_BAD;
	}

	if (!located || !cat_volser) {
		return VOLSER_NOT_CATALOGED;
	}

	n = strlen(want);
	memset(padded, ' ', sizeof(padded));
	memcpy(padded, want, n);

	return memcmp(padded, cat_volser, VOLSER_LEN) == 0
		? VOLSER_ON_VOLUME : VOLSER_OTHER_VOLUME;
}
