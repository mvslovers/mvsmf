#include <ctype.h>
#include <string.h>

#include "ispfstat.h"

/*
 * ISPF statistics of a directory entry, in their own translation unit so
 * test/host/tstispf.c can drive the real parser -- dsapi.c cannot compile on
 * the host. Layout and the reasons for the checks: ispfstat.h.
 */

#define ENTRY_FIXED	12	/* name, TTR, indicator byte */
#define IND_TTRS	0x60	/* number of TTRs in the user data */
#define IND_UDATA	0x1F	/* user data length, in halfwords */
#define FLAG_SCLM	0x80

/* A packed byte: two decimal digits. -1 if either nibble is not one. */
static int
bcd2(unsigned char b)
{
	unsigned hi = b >> 4;
	unsigned lo = b & 0x0F;

	if (hi > 9 || lo > 9) return -1;
	return (int)(hi * 10 + lo);
}

static void
put2(char *p, unsigned v)
{
	p[0] = (char) ('0' + (v / 10) % 10);
	p[1] = (char) ('0' + v % 10);
}

/* century byte + packed yyddd(sign) -> "yyyy/mm/dd". 0 if it is no date. */
static int
format_date(unsigned char cent, const unsigned char *d, char *out)
{
	static const unsigned char mdays[12] =
		{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
	int		yy, d1, d3, sign;
	unsigned	year, doy, month, leap;

	if (cent > 1) return 0;

	yy = bcd2(d[0]);
	d1 = bcd2(d[1]);
	d3 = d[2] >> 4;
	sign = d[2] & 0x0F;
	if (yy < 0 || d1 < 0 || d3 > 9 || sign < 0x0A) return 0;

	year = 1900 + 100 * (unsigned) cent + (unsigned) yy;
	doy  = (unsigned) d1 * 10 + (unsigned) d3;
	leap = ((year % 4 == 0 && year % 100 != 0) || year % 400 == 0) ? 1 : 0;

	if (doy < 1 || doy > 365 + leap) return 0;

	for (month = 0; month < 12; month++) {
		unsigned len = mdays[month] + ((month == 1) ? leap : 0);

		if (doy <= len) break;
		doy -= len;
	}

	out[0] = (char) ('0' + year / 1000);
	out[1] = (char) ('0' + (year / 100) % 10);
	out[2] = (char) ('0' + (year / 10) % 10);
	out[3] = (char) ('0' + year % 10);
	out[4] = '/';
	put2(&out[5], month + 1);
	out[7] = '/';
	put2(&out[8], doy);
	out[10] = '\0';
	return 1;
}

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'ispf_stats_parse'");
#endif
int
ispf_stats_parse(const unsigned char *entry, unsigned size, ISPFSTATS *out)
{
	const unsigned char	*u;
	ISPFSTATS		s;
	int			sec, hh, mm;
	unsigned		n;

	if (!entry || !out || size < ENTRY_FIXED + ISPF_STATS_LEN) return 0;

	/* the user data of a load module can hold the same number of bytes, with
	   a TTR list in front */
	if (entry[11] & IND_TTRS) return 0;
	if ((unsigned) (entry[11] & IND_UDATA) * 2 != ISPF_STATS_LEN) return 0;

	u = &entry[ENTRY_FIXED];
	memset(&s, 0, sizeof(s));

	/* binary, 0..99 -- a larger value is somebody else's data */
	if (u[0] > 99 || u[1] > 99) return 0;
	s.vers = u[0];
	s.mod  = u[1];
	s.sclm = (u[2] & FLAG_SCLM) ? 1 : 0;

	sec = bcd2(u[3]);
	hh  = bcd2(u[12]);
	mm  = bcd2(u[13]);
	if (sec < 0 || sec > 59 || hh < 0 || hh > 23 || mm < 0 || mm > 59) return 0;

	if (!format_date(u[4], &u[5], s.c4date)) return 0;
	if (!format_date(u[8], &u[9], s.m4date)) return 0;

	put2(&s.mtime[0], (unsigned) hh);
	s.mtime[2] = ':';
	put2(&s.mtime[3], (unsigned) mm);
	s.mtime[5] = '\0';
	put2(&s.msec[0], (unsigned) sec);
	s.msec[2] = '\0';

	s.cnorc = ((unsigned) u[14] << 8) | u[15];
	s.inorc = ((unsigned) u[16] << 8) | u[17];
	s.mnorc = ((unsigned) u[18] << 8) | u[19];

	/* The blank padding is not part of the name; a NUL is cut the same way.
	   0x40, not ' ': these bytes are EBCDIC whatever the host compiles for. */
	memcpy(s.user, &u[20], sizeof(s.user));
	n = sizeof(s.user);
	while (n > 0 && (s.user[n - 1] == 0x40 || s.user[n - 1] == 0x00)) n--;
	s.userlen = n;

	*out = s;
	return 1;
}

#ifdef __MVS__
__asm__("\n&FUNC	SETC 'ispf_wants_base'");
#endif
int
ispf_wants_base(const char *value)
{
	static const char word[] = "BASE";
	unsigned i;

	if (!value) return 0;

	for (i = 0; i < 4; i++) {
		if (toupper((unsigned char) value[i]) != word[i]) return 0;
	}

	/* ",total" may follow; another letter makes it another word */
	return value[4] == '\0' || value[4] == ',' || value[4] == ' ';
}
