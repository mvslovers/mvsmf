/*
 * tstjson.c - #215: every control character in a JSON string must be escaped.
 *             #473: and \u00XX must name the character the client will see.
 *
 * RFC 8259 allows no character below U+0020 inside a string. addJsonStringEsc()
 * and addJsonArrayString() used to escape " \ CR LF TAB and let the other
 * control characters through raw, so one stray byte in a message (the Master
 * Trace Table is full of them) made the whole response unparseable.
 *
 * #473: the builder runs in the host character set, and the response is
 * translated to ASCII only afterwards (http_etoa()). A \u00XX written from the
 * host byte names the wrong code point on MVS: EBCDIC TAB (0x05) was written
 * as \u0005, while the client's character is the TAB (U+0009) it translates
 * to. The builder therefore takes the table the response will be translated with, and decides
 * on the translated byte.
 *
 * So the test does what the server does. It translates the finished document
 * with the same table (xl[], below) and reads the result with a strict JSON
 * reader. That reader works on the bytes the client receives, which is the one
 * place where numeric ASCII values are right and not a mistake. xl[] is a
 * model, not CP037: it maps the printable ASCII characters (found through
 * string literals, so it holds on an EBCDIC host too) and the five short-form
 * characters to their ASCII values, and carries a few EBCDIC-style entries
 * that make host byte and code point differ (0x05 -> TAB, 0x04 -> U+009C ...).
 * Every other byte maps to itself. The builder's logic is driven by the table
 * alone, so the checks hold on either host and `mbt test --mvs` runs the same
 * file. U+0000 cannot be tested: a C string ends at it.
 *
 * The reader is itself checked against hand-written strings first, because a
 * checker that accepts everything proves nothing.
 *
 * The TU #includes src/json.c, so it drives the real builder.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <mbtcheck.h>

#include "../../src/json.c"

#define CTRL_MAX	((unsigned) ' ')

static char msg[160];
static unsigned char xl[256];

static void
init_table(void)
{
	static const char printable[] =
		" !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ"
		"[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
	unsigned i;

	for (i = 0; i < 256; i++) xl[i] = (unsigned char) i;
	for (i = 0; printable[i] != '\0'; i++) {
		xl[(unsigned char) printable[i]] = (unsigned char) (0x20 + i);
	}
	xl[(unsigned char) '\b'] = 0x08;
	xl[(unsigned char) '\t'] = 0x09;
	xl[(unsigned char) '\n'] = 0x0A;
	xl[(unsigned char) '\f'] = 0x0C;
	xl[(unsigned char) '\r'] = 0x0D;

	/* EBCDIC style: host byte and translated code point differ. None of
	   these host bytes is a character the strings below spell out. */
	xl[0x05] = 0x09;	/* EBCDIC TAB            */
	xl[0x15] = 0x0A;	/* EBCDIC NEL -> LF      */
	xl[0x16] = 0x08;	/* EBCDIC BS             */
	xl[0x04] = 0x9C;	/* C1 control            */
	xl[0x06] = 0x86;	/* C1 control            */
	xl[0x7E] = 0x1A;	/* printable here, SUB there */
}

/* what http_etoa() does to a response */
static void
translate(char *s)
{
	for (; *s != '\0'; s++) *s = (char) xl[(unsigned char) *s];
}

static void
translate_copy(char *dst, const char *src)
{
	strcpy(dst, src);
	translate(dst);
}

static int
hexval(char c)
{
	static const char lower[] = "0123456789abcdef";
	static const char upper[] = "0123456789ABCDEF";
	const char *p;

	if (c != '\0' && (p = strchr(lower, c)) != NULL) return (int) (p - lower);
	if (c != '\0' && (p = strchr(upper, c)) != NULL) return (int) (p - upper);
	return -1;
}

/* Read one JSON string, as the client receives it, starting at its opening
   quote. Returns the position after the closing quote, or NULL if the string
   is not valid JSON. The decoded code points go to out (NUL terminated);
   \uXXXX is taken as that code point, and only U+00XX is ever produced. A raw
   control character is refused: below U+0020, and U+007F..U+009F as well,
   which the builder writes as an escape rather than as a lone byte that is no
   UTF-8. */
static const char *
read_json_string(const char *s, char *out, size_t outsz)
{
	size_t o = 0;

	if (*s != 0x22) return NULL;
	s++;

	while (*s != 0x22) {
		unsigned char c = (unsigned char) *s;
		int h1, h2, h3, h4;

		if (c == '\0') return NULL;		/* unterminated */
		if (c < CTRL_MAX) return NULL;		/* raw control character */
		if (c >= 0x7F && c <= 0x9F) return NULL;
		if (o + 1 >= outsz) return NULL;

		if (c != 0x5C) {
			out[o++] = (char) c;
			s++;
			continue;
		}

		s++;
		switch ((unsigned char) *s) {
		case 0x22: out[o++] = 0x22; s++; break;
		case 0x5C: out[o++] = 0x5C; s++; break;
		case 0x2F: out[o++] = 0x2F; s++; break;
		case 0x62: out[o++] = 0x08; s++; break;		/* b */
		case 0x66: out[o++] = 0x0C; s++; break;		/* f */
		case 0x6E: out[o++] = 0x0A; s++; break;		/* n */
		case 0x72: out[o++] = 0x0D; s++; break;		/* r */
		case 0x74: out[o++] = 0x09; s++; break;		/* t */
		case 0x75:					/* u */
			h1 = hexval(s[1]);
			h2 = h1 < 0 ? -1 : hexval(s[2]);
			h3 = h2 < 0 ? -1 : hexval(s[3]);
			h4 = h3 < 0 ? -1 : hexval(s[4]);
			if (h4 < 0) return NULL;
			if (h1 != 0 || h2 != 0) return NULL;	/* only U+00XX is written */
			out[o++] = (char) (h3 * 16 + h4);
			s += 5;
			break;
		default:
			return NULL;				/* not an escape JSON defines */
		}
	}

	out[o] = '\0';
	return s + 1;
}

/* {"k":"<value>"} through addJsonStringEsc(), translated, read back. 1 if it is
   valid JSON, 0 if not; the decoded value (code points) is left in out. */
static int
roundtrip_object(const char *value, char *out, size_t outsz)
{
	JsonBuilder *b = createJsonBuilder(xl);
	char *doc;
	const char *p;
	int ok = 0;

	if (!b) return 0;
	if (startJsonObject(b) < 0) goto done;
	if (addJsonStringEsc(b, "k", value) < 0) goto done;
	if (endJsonObject(b) < 0) goto done;
	doc = getJsonString(b);
	if (!doc) goto done;
	translate(doc);

	if (strncmp(doc, "{\"k\":", 5) == 0 &&
	    (p = read_json_string(doc + 5, out, outsz)) != NULL &&
	    p[0] == xl[(unsigned char) '}'] && p[1] == '\0') {
		ok = 1;
	}
	free(doc);
done:
	freeJsonBuilder(b);
	return ok;
}

/* ["<value>"] through addJsonArrayString(), translated, read back. */
static int
roundtrip_array(const char *value, char *out, size_t outsz)
{
	JsonBuilder *b = createJsonBuilder(xl);
	char *doc;
	const char *p;
	int ok = 0;

	if (!b) return 0;
	if (startArray(b) < 0) goto done;
	if (addJsonArrayString(b, value) < 0) goto done;
	if (endArray(b) < 0) goto done;
	doc = getJsonString(b);
	if (!doc) goto done;
	translate(doc);

	if (doc[0] == xl[(unsigned char) '[']) {
		p = read_json_string(doc + 1, out, outsz);
		if (p != NULL && p[0] == xl[(unsigned char) ']'] && p[1] == '\0') {
			ok = 1;
		}
	}
	free(doc);
done:
	freeJsonBuilder(b);
	return ok;
}

/* The exact text addJsonStringEsc() produced for value, as the client gets it
   (translated), for the short and long forms. */
static char *
object_text(const char *value)
{
	JsonBuilder *b = createJsonBuilder(xl);
	char *doc = NULL;

	if (!b) return NULL;
	if (startJsonObject(b) == 0 && addJsonStringEsc(b, "k", value) == 0 &&
	    endJsonObject(b) == 0) {
		doc = getJsonString(b);
		if (doc) translate(doc);
	}
	freeJsonBuilder(b);
	return doc;
}

/* "k":"<body>" as the client sees it, with body written in ASCII; the body
   of the string is what is compared. */
static int
body_is(const char *value, const char *ascii_body)
{
	char *text = object_text(value);
	char want[64];
	int ok;

	snprintf(want, sizeof(want), "{\"k\":\"%s\"}", ascii_body);
	translate(want);
	ok = text != NULL && strcmp(text, want) == 0;
	free(text);
	return ok;
}

/* 0. The checker itself: known good and known bad strings, given in
   host spelling and run through the table like a response. */
static void
test_checker(void)
{
	char tmp[32];
	char src[32];
	unsigned char raw[5];

	translate_copy(src, "\"abc\"");
	CHECK(read_json_string(src, tmp, sizeof(tmp)) != NULL,
	      "checker accepts a plain string");
	translate_copy(src, "\"a\\u0001b\"");
	CHECK(read_json_string(src, tmp, sizeof(tmp)) != NULL,
	      "checker accepts \\u0001");
	translate_copy(src, "\"a\\qb\"");
	CHECK(read_json_string(src, tmp, sizeof(tmp)) == NULL,
	      "checker rejects \\q");
	translate_copy(src, "\"a\\u00zzb\"");
	CHECK(read_json_string(src, tmp, sizeof(tmp)) == NULL,
	      "checker rejects a short \\u escape");
	translate_copy(src, "\"abc");
	CHECK(read_json_string(src, tmp, sizeof(tmp)) == NULL,
	      "checker rejects an unterminated string");
	raw[0] = 0x22; raw[1] = 0x61; raw[2] = 0x01; raw[3] = 0x22; raw[4] = 0;
	CHECK(read_json_string((const char *) raw, tmp, sizeof(tmp)) == NULL,
	      "checker rejects a raw U+0001");
	raw[2] = 0x1F;
	CHECK(read_json_string((const char *) raw, tmp, sizeof(tmp)) == NULL,
	      "checker rejects the last control character");
	raw[2] = 0x7F;
	CHECK(read_json_string((const char *) raw, tmp, sizeof(tmp)) == NULL,
	      "checker rejects a raw U+007F");
	raw[2] = 0x85;
	CHECK(read_json_string((const char *) raw, tmp, sizeof(tmp)) == NULL,
	      "checker rejects a raw U+0085");
	raw[2] = 0xE9;
	CHECK(read_json_string((const char *) raw, tmp, sizeof(tmp)) != NULL,
	      "checker accepts a raw byte above U+009F");
}

/* 1. Every byte, on its own, in both builders: valid JSON after the
   translation, and the client decodes exactly the character the table
   gives for it. */
static void
test_every_byte(void)
{
	char in[8];
	char out[8192];
	char want[8192];

	for (unsigned c = 1; c < 256; c++) {
		in[0] = 'a'; in[1] = (char) c; in[2] = 'b'; in[3] = '\0';
		translate_copy(want, in);

		memset(out, 'x', sizeof(out));
		snprintf(msg, sizeof(msg), "addJsonStringEsc: 0x%02X yields valid JSON", c);
		CHECK(roundtrip_object(in, out, sizeof(out)), msg);
		snprintf(msg, sizeof(msg), "addJsonStringEsc: 0x%02X decodes to U+%04X", c, xl[c]);
		CHECK(strcmp(out, want) == 0, msg);

		memset(out, 'x', sizeof(out));
		snprintf(msg, sizeof(msg), "addJsonArrayString: 0x%02X yields valid JSON", c);
		CHECK(roundtrip_array(in, out, sizeof(out)), msg);
		snprintf(msg, sizeof(msg), "addJsonArrayString: 0x%02X decodes to U+%04X", c, xl[c]);
		CHECK(strcmp(out, want) == 0, msg);
	}
}

/* 2. The five characters with a short form use it -- named by the code
   point they translate to, so EBCDIC TAB (0x05) gets \t too. */
static void
test_short_forms(void)
{
	char in[8];

	static const struct { char ch; const char *esc; } shorts[] = {
		{ '\b', "\\b" }, { '\f', "\\f" }, { '\n', "\\n" },
		{ '\r', "\\r" }, { '\t', "\\t" },
		{ 0x05, "\\t" }, { 0x15, "\\n" }, { 0x16, "\\b" }
	};

	for (size_t i = 0; i < sizeof(shorts) / sizeof(shorts[0]); i++) {
		in[0] = shorts[i].ch; in[1] = '\0';
		snprintf(msg, sizeof(msg), "short form #%u (0x%02X) is written as %s",
			(unsigned) i, (unsigned) (unsigned char) shorts[i].ch,
			shorts[i].esc);
		CHECK(body_is(in, shorts[i].esc), msg);
	}
}

/* 3. The long form is \u00XX with XX the code point of the translated
   character, not the host byte. */
static void
test_long_forms(void)
{
	char in[8];
	char *text;

	in[0] = 0x01; in[1] = '\0';
	CHECK(body_is(in, "\\u0001"), "0x01 is written as \\u0001");
	in[0] = 0x04;
	CHECK(body_is(in, "\\u009C"), "a byte that translates to U+009C is \\u009C (#473)");
	in[0] = 0x06;
	CHECK(body_is(in, "\\u0086"), "a byte that translates to U+0086 is \\u0086 (#473)");
	in[0] = 0x7E;
	CHECK(body_is(in, "\\u001A"),
	      "a printable host byte that translates to U+001A is \\u001A (#473)");
	in[0] = 0x7F;
	CHECK(body_is(in, "\\u007F"), "U+007F is escaped");
	in[0] = (char) 0x9F;
	CHECK(body_is(in, "\\u009F"), "U+009F is escaped");
	in[0] = (char) 0xE9;
	text = object_text(in);
	CHECK(text != NULL && (unsigned char) text[6] == 0xE9,
	      "a byte above U+009F passes through for the translation (encoding is #234)");
	free(text);
}

/* 4. Quote and backslash are still escaped, ordinary text is untouched. */
static void
test_plain_text(void)
{
	char out[8192];
	char want[8192];

	CHECK(roundtrip_object("say \"hi\" \\ there", out, sizeof(out)) &&
	      (translate_copy(want, "say \"hi\" \\ there"), strcmp(out, want) == 0),
	      "quote and backslash round-trip");
	CHECK(roundtrip_object("IEF403I JOB01234 - STARTED", out, sizeof(out)) &&
	      (translate_copy(want, "IEF403I JOB01234 - STARTED"), strcmp(out, want) == 0),
	      "ordinary text round-trips");
	CHECK(body_is("plain", "plain"), "ordinary text is written unchanged");
	CHECK(body_is("a\"b\\c", "a\\\"b\\\\c"), "quote and backslash use their short form");
}

/* 5. A string past the builder's initial buffer, every control character
   in it, so growth happens in the middle of escapes. */
static void
test_long_string(void)
{
	size_t n = 4000;
	char *big;
	char *dec;

	n = 4000;
	big = malloc(n + 1);
	dec = malloc(n + 1);
	CHECK(big != NULL && dec != NULL, "allocate the long string");
	if (big && dec) {
		char *wide = malloc(n * 6 + 16);
		char *exp = malloc(n + 1);

		for (size_t i = 0; i < n; i++) {
			unsigned k = (unsigned) (i % 40);
			big[i] = (char) (k < CTRL_MAX - 1 ? k + 1 : 'x');
		}
		big[n] = '\0';

		CHECK(wide != NULL && exp != NULL, "allocate the output buffer");
		if (wide && exp) {
			translate_copy(exp, big);
			CHECK(roundtrip_object(big, wide, n * 6 + 16) &&
			      strcmp(wide, exp) == 0,
			      "a long string of control characters round-trips (object)");
			CHECK(roundtrip_array(big, wide, n * 6 + 16) &&
			      strcmp(wide, exp) == 0,
			      "a long string of control characters round-trips (array)");
		}
		free(wide);
		free(exp);
	}
	free(big);
	free(dec);
}

/* 6. NULL still means null. */
static void
test_null(void)
{
	char want[64];
	char *text;

	text = object_text(NULL);
	snprintf(want, sizeof(want), "{\"k\":null}");
	translate(want);
	CHECK(text != NULL && strcmp(text, want) == 0,
	      "a NULL value is still null");
	free(text);
}

/* 7. jsonEscapeBytes(), the routine the data set listing escapes member
   names with (#473: the same one the builder uses). With
   JSON_ESC_NONASCII everything that does not translate to printable
   ASCII is a \u00XX escape; the bytes it leaves are the host bytes, for
   the response translation to turn into ASCII. */
static void
test_escape_bytes(void)
{
	char want[64];

	static const unsigned char name1[] = { 'A', 'B', 0x01, 'C' };
	static const unsigned char name2[] = { 'A', 0x05, 0x04, 0xE9, 'B' };
	static const unsigned char name3[] = { 'A', '"', '\\', 'B' };
	static const unsigned char name4[] = { 'A', 0x7E, 'B' };
	char got[64];
	size_t len;

	len = jsonEscapeBytes(got, sizeof(got), name1, sizeof(name1), xl,
	                      JSON_ESC_NONASCII);
	snprintf(want, sizeof(want), "AB\\u0001C");
	CHECK(len == strlen(got) && strcmp(got, want) == 0,
	      "member name: a control byte is \\u0001");

	len = jsonEscapeBytes(got, sizeof(got), name2, sizeof(name2), xl,
	                      JSON_ESC_NONASCII);
	snprintf(want, sizeof(want), "A\\t\\u009C\\u00E9B");
	CHECK(len == strlen(got) && strcmp(got, want) == 0,
	      "member name: a byte is named by its translation, short form kept (#473)");

	len = jsonEscapeBytes(got, sizeof(got), name3, sizeof(name3), xl,
	                      JSON_ESC_NONASCII);
	snprintf(want, sizeof(want), "A\\\"\\\\B");
	CHECK(len == strlen(got) && strcmp(got, want) == 0,
	      "member name: quote and backslash are escaped");

	len = jsonEscapeBytes(got, sizeof(got), name4, sizeof(name4), xl,
	                      JSON_ESC_NONASCII);
	snprintf(want, sizeof(want), "A\\u001AB");
	CHECK(len == strlen(got) && strcmp(got, want) == 0,
	      "member name: a host byte that translates to a control is escaped");

	jsonEscapeBytes(got, sizeof(got), name2, sizeof(name2), xl, 0);
	snprintf(want, sizeof(want), "A\\t\\u009C");
	CHECK(strncmp(got, want, strlen(want)) == 0 &&
	      (unsigned char) got[strlen(want)] == 0xE9,
	      "without JSON_ESC_NONASCII a byte above U+009F stays as it is");

	/* room: stops before the output buffer is exceeded */
	memset(got, 'z', sizeof(got));
	len = jsonEscapeBytes(got, 10, name1, sizeof(name1), xl,
	                      JSON_ESC_NONASCII);
	CHECK(len < 10 && got[len] == '\0' && got[10] == 'z',
	      "jsonEscapeBytes stays inside outlen and terminates");
	CHECK(jsonEscapeBytes(got, 1, name1, sizeof(name1), xl, 0) == 0 &&
	      got[0] == '\0',
	      "an output of one byte holds just the terminator");
}

int
main(void)
{
	init_table();

	test_checker();
	test_every_byte();
	test_short_forms();
	test_long_forms();
	test_plain_text();
	test_long_string();
	test_null();
	test_escape_bytes();

	return mbt_test_summary("TSTJSON");
}
