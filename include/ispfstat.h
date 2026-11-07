#ifndef ISPFSTAT_H
#define ISPFSTAT_H

/**
 * @file ispfstat.h
 * @brief ISPF statistics in a PDS directory entry (issue #573).
 *
 * z/OSMF reports them per member when the member list is asked for with
 * `X-IBM-Attributes: base`. They live in the user data of the directory entry:
 *
 *      0      version, binary
 *      1      modification level, binary
 *      2      flags, 0x80 = last edited under SCLM
 *      3      seconds of the last change, packed
 *      4      century of the creation date, 0 = 19xx, 1 = 20xx
 *      5..7   creation date, packed yyddd + sign
 *      8      century of the change date
 *      9..11  change date, packed yyddd + sign
 *      12..13 hour and minute of the last change, packed
 *      14..15 current number of records
 *      16..17 initial number of records
 *      18..19 number of modified records
 *      20..27 userid of the last change, blank padded, EBCDIC
 *      28..29 reserved
 *
 * 30 bytes, 15 halfwords. The user data of a load module, or of a member some
 * other tool stowed, has other contents and often the same length, so the
 * layout is not trusted: every packed field is checked and a member that does
 * not pass has no statistics -- it is listed with its name only, which is what
 * z/OSMF does for a member without them.
 *
 * Not covered: the extended form ISPF writes for a member of more than 65535
 * records (a longer user data field). Those members have no statistics here.
 */

/** @brief The user data length of the statistics, in bytes. */
#define ISPF_STATS_LEN		30

/** @brief What a directory entry's statistics say, ready to be written out. */
typedef struct ispfstats {
	unsigned	vers;
	unsigned	mod;
	unsigned	cnorc;		/* current number of records */
	unsigned	inorc;		/* initial number of records */
	unsigned	mnorc;		/* modified records */
	char		c4date[11];	/* "yyyy/mm/dd" */
	char		m4date[11];
	char		mtime[6];	/* "hh:mm" */
	char		msec[3];	/* "ss" */
	unsigned char	user[8];	/* as stored: EBCDIC, trailing blanks cut */
	unsigned	userlen;
	int		sclm;		/* non-zero: last edited under SCLM */
} ISPFSTATS;

/**
 * Read the statistics out of one directory entry.
 *
 * @param entry   the entry, from the first name byte
 * @param size    its length: 12 bytes plus the user data, as the directory
 *                walk computed it. The function never reads past it.
 * @param out     filled only when the answer is 1
 *
 * @return 1 if the entry carries ISPF statistics, 0 if it does not (no user
 *         data, a different length, a TTR list, or a field that is no packed
 *         number or no date).
 *
 * The digit strings are in the native character set of the build -- EBCDIC on
 * MVS -- so http_printf() translates them like any other formatted output.
 * `user` is raw EBCDIC and goes through jsonEscapeBytes() as a member name
 * does.
 */
int ispf_stats_parse(const unsigned char *entry, unsigned size,
                     ISPFSTATS *out)					asm("MFISPFST");

/**
 * Does an X-IBM-Attributes header ask for the base attributes?
 *
 * @param value   the header value, or NULL when it was not sent
 * @return 1 for `base`, with or without a `,total` suffix, in any case; 0 for
 *         anything else, `member` and an unknown word included.
 */
int ispf_wants_base(const char *value)					asm("MFISPBAS");

#endif /* ISPFSTAT_H */
