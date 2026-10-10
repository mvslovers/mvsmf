/*
 * tstdtyp.c - #391 regression: parsing X-IBM-Data-Type.
 *
 * Zowe sends a chosen encoding as `X-IBM-Data-Type: text;fileEncoding=IBM-1047`.
 * The old parser compared the first four bytes against "text" and dropped the
 * rest, so IBM-1047 content (brackets at X'AD'/X'BD') was always translated
 * as CP037 and came out as `Ý` / `¨` (#390). It also compared "binary" and
 * "record" with strcmp, so `BINARY` or `binary;foo=bar` was handled as text.
 *
 * Every expectation below that is not about a bad argument was measured on a
 * real z/OSMF -- see the table in #391. The odd ones are deliberate: a blank
 * after the ';' hides the parameter, and binary ignores even an invalid
 * encoding.
 *
 * ====================================================================
 * This test drives the REAL parser: src/datatype.c is #included below.
 * ====================================================================
 *
 * Runs on host via `mbt test`.
 */
#include <stdio.h>
#include <string.h>

#include <mbtcheck.h>

#include "../../src/datatype.c"

static char msg[200];

static void
check(const char *value, int want_rc, int want_type, int want_enc)
{
	int type = -1;
	int enc = -1;
	int rc;

	rc = parse_data_type(value, &type, &enc);

	sprintf(msg, "\"%s\" returns %d", value ? value : "(null)", want_rc);
	CHECK_EQ(rc, want_rc, msg);
	sprintf(msg, "\"%s\" is type %d", value ? value : "(null)", want_type);
	CHECK_EQ(type, want_type, msg);
	sprintf(msg, "\"%s\" is encoding %d", value ? value : "(null)", want_enc);
	CHECK_EQ(enc, want_enc, msg);
}

int
main(void)
{
	printf("\n--- the plain types, as before ---\n");

	check(NULL,     0, DATA_TYPE_TEXT,   FILE_ENC_DEFAULT);
	check("text",   0, DATA_TYPE_TEXT,   FILE_ENC_DEFAULT);
	check("binary", 0, DATA_TYPE_BINARY, FILE_ENC_DEFAULT);
	check("record", 0, DATA_TYPE_RECORD, FILE_ENC_DEFAULT);
	check("",       0, DATA_TYPE_TEXT,   FILE_ENC_DEFAULT);
	check("bogus",  0, DATA_TYPE_TEXT,   FILE_ENC_DEFAULT);

	printf("\n--- #391: fileEncoding was dropped ---\n");

	check("text;fileEncoding=IBM-1047", 0, DATA_TYPE_TEXT, FILE_ENC_IBM1047);
	check("text;fileEncoding=1047",     0, DATA_TYPE_TEXT, FILE_ENC_IBM1047);
	check("text;fileEncoding=IBM-037",  0, DATA_TYPE_TEXT, FILE_ENC_IBM037);
	check("text;fileEncoding=037",      0, DATA_TYPE_TEXT, FILE_ENC_IBM037);
	check("text;fileEncoding=ibm-1047", 0, DATA_TYPE_TEXT, FILE_ENC_IBM1047);
	check("text;fileencoding=IBM-1047", 0, DATA_TYPE_TEXT, FILE_ENC_IBM1047);
	check("TEXT;fileEncoding=IBM-1047", 0, DATA_TYPE_TEXT, FILE_ENC_IBM1047);
	check("text;fileEncoding=IBM-1047;crlf=true",
	                                    0, DATA_TYPE_TEXT, FILE_ENC_IBM1047);
	check("text;foo=bar;fileEncoding=IBM-1047",
	                                    0, DATA_TYPE_TEXT, FILE_ENC_IBM1047);

	printf("\n--- unsupported encodings fail the request ---\n");

	check("text;fileEncoding=BOGUS",         -1, DATA_TYPE_TEXT, FILE_ENC_DEFAULT);
	check("text;fileEncoding=IBM-37",        -1, DATA_TYPE_TEXT, FILE_ENC_DEFAULT);
	check("text;fileEncoding=CP037",         -1, DATA_TYPE_TEXT, FILE_ENC_DEFAULT);
	check("text;fileEncoding=IBM-1140",      -1, DATA_TYPE_TEXT, FILE_ENC_DEFAULT);
	check("text;fileEncoding=IBM-10470",     -1, DATA_TYPE_TEXT, FILE_ENC_DEFAULT);
	check("text;fileEncoding=IBM-104",       -1, DATA_TYPE_TEXT, FILE_ENC_DEFAULT);
	check("TEXT;fileEncoding=BOGUS",         -1, DATA_TYPE_TEXT, FILE_ENC_DEFAULT);
	check("text;fileencoding=BOGUS",         -1, DATA_TYPE_TEXT, FILE_ENC_DEFAULT);
	check("text;fileEncoding=BOGUS;foo=bar", -1, DATA_TYPE_TEXT, FILE_ENC_DEFAULT);

	printf("\n--- what the reference ignores, measured ---\n");

	check("text; fileEncoding=BOGUS", 0, DATA_TYPE_TEXT, FILE_ENC_DEFAULT);
	check("text;fileEncoding=",       0, DATA_TYPE_TEXT, FILE_ENC_DEFAULT);
	check("text;foo=bar",             0, DATA_TYPE_TEXT, FILE_ENC_DEFAULT);
	check("text;",                    0, DATA_TYPE_TEXT, FILE_ENC_DEFAULT);
	check("text;fileEncoding",        0, DATA_TYPE_TEXT, FILE_ENC_DEFAULT);

	printf("\n--- binary and record: case and parameters ---\n");

	check("BINARY",                    0, DATA_TYPE_BINARY, FILE_ENC_DEFAULT);
	check("binary;foo=bar",            0, DATA_TYPE_BINARY, FILE_ENC_DEFAULT);
	check("Record",                    0, DATA_TYPE_RECORD, FILE_ENC_DEFAULT);
	check("binary;fileEncoding=BOGUS", 0, DATA_TYPE_BINARY, FILE_ENC_DEFAULT);
	check("record;fileEncoding=IBM-1047",
	                                   0, DATA_TYPE_RECORD, FILE_ENC_DEFAULT);

	printf("\n--- the type is the whole token, not a prefix ---\n");

	/* "textual" used to pass the 4-byte prefix test; it is an unknown type
	   now, which still means text -- the observable answer is the same, but
	   "binaryx" must not become binary. */
	check("textual", 0, DATA_TYPE_TEXT, FILE_ENC_DEFAULT);
	check("binaryx", 0, DATA_TYPE_TEXT, FILE_ENC_DEFAULT);

	return mbt_test_summary("TSTDTYP");
}
