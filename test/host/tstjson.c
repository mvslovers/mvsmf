/*
 * tstjson.c - #215: every control character in a JSON string must be escaped.
 *
 * RFC 8259 allows no character below U+0020 inside a string. addJsonStringEsc()
 * and addJsonArrayString() used to escape " \ CR LF TAB and let the other
 * control characters through raw, so one stray byte in a message (the Master
 * Trace Table is full of them) made the whole response unparseable.
 *
 * "Below U+0020" is meant for the character as it leaves the builder, and the
 * builder runs in the execution character set: ASCII here, EBCDIC on MVS, where
 * the response is translated only afterwards. So nothing in this test names an
 * ASCII code. The control characters are the byte values below ' ' (0x20 in
 * ASCII, 0x40 in EBCDIC), the short forms are the character literals '\b' '\f'
 * '\n' '\r' '\t', and the checks hold in both worlds, so `mbt test --mvs`
 * runs the same file. U+0000 cannot be tested: a C string ends at it.
 *
 * The checker below is a strict reader of one JSON string, not a substring
 * search. It rejects a raw control character and any escape JSON does not
 * define, and it decodes what it accepts so the result can be compared with
 * the input. The checker is itself checked against hand-written strings first,
 * because a checker that accepts everything proves nothing.
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

/* Read one JSON string starting at its opening quote. Returns the position
   after the closing quote, or NULL if the string is not valid JSON. The
   decoded bytes go to out (NUL terminated). \uXXXX is taken as the byte value,
   which is how the builder writes it: only U+00XX is ever produced. */
static const char *
read_json_string(const char *s, char *out, size_t outsz)
{
	size_t o = 0;

	if (*s != '"') return NULL;
	s++;

	while (*s != '"') {
		unsigned char c = (unsigned char) *s;
		int h1, h2, h3, h4;

		if (c == '\0') return NULL;		/* unterminated */
		if (c < CTRL_MAX) return NULL;		/* raw control character */
		if (o + 1 >= outsz) return NULL;

		if (c != '\\') {
			out[o++] = (char) c;
			s++;
			continue;
		}

		s++;
		switch (*s) {
		case '"':  out[o++] = '"';  s++; break;
		case '\\': out[o++] = '\\'; s++; break;
		case '/':  out[o++] = '/';  s++; break;
		case 'b':  out[o++] = '\b'; s++; break;
		case 'f':  out[o++] = '\f'; s++; break;
		case 'n':  out[o++] = '\n'; s++; break;
		case 'r':  out[o++] = '\r'; s++; break;
		case 't':  out[o++] = '\t'; s++; break;
		case 'u':
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

/* {"k":"<value>"} through addJsonStringEsc(), read back. 1 if it is valid
   JSON, 0 if not; the decoded value is left in out. */
static int
roundtrip_object(const char *value, char *out, size_t outsz)
{
	JsonBuilder *b = createJsonBuilder();
	char *doc;
	const char *p;
	int ok = 0;

	if (!b) return 0;
	if (startJsonObject(b) < 0) goto done;
	if (addJsonStringEsc(b, "k", value) < 0) goto done;
	if (endJsonObject(b) < 0) goto done;
	doc = getJsonString(b);
	if (!doc) goto done;

	if (strncmp(doc, "{\"k\":", 5) == 0 &&
	    (p = read_json_string(doc + 5, out, outsz)) != NULL &&
	    p[0] == '}' && p[1] == '\0') {
		ok = 1;
	}
	free(doc);
done:
	freeJsonBuilder(b);
	return ok;
}

/* ["<value>"] through addJsonArrayString(), read back. */
static int
roundtrip_array(const char *value, char *out, size_t outsz)
{
	JsonBuilder *b = createJsonBuilder();
	char *doc;
	const char *p;
	int ok = 0;

	if (!b) return 0;
	if (startArray(b) < 0) goto done;
	if (addJsonArrayString(b, value) < 0) goto done;
	if (endArray(b) < 0) goto done;
	doc = getJsonString(b);
	if (!doc) goto done;

	if (doc[0] == '[' &&
	    (p = read_json_string(doc + 1, out, outsz)) != NULL &&
	    p[0] == ']' && p[1] == '\0') {
		ok = 1;
	}
	free(doc);
done:
	freeJsonBuilder(b);
	return ok;
}

/* The exact text addJsonStringEsc() produced for value, for the short forms. */
static char *
object_text(const char *value)
{
	JsonBuilder *b = createJsonBuilder();
	char *doc = NULL;

	if (!b) return NULL;
	if (startJsonObject(b) == 0 && addJsonStringEsc(b, "k", value) == 0 &&
	    endJsonObject(b) == 0) {
		doc = getJsonString(b);
	}
	freeJsonBuilder(b);
	return doc;
}

int
main(void)
{
	char in[8], out[8192], expect[8];
	unsigned c;
	char *big, *dec, *text;
	size_t i, n;

	/* 0. The checker itself: known good and known bad strings. */
	{
		char tmp[32];
		unsigned char raw[5];

		CHECK(read_json_string("\"abc\"", tmp, sizeof(tmp)) != NULL,
		      "checker accepts a plain string");
		CHECK(read_json_string("\"a\\u0001b\"", tmp, sizeof(tmp)) != NULL,
		      "checker accepts \\u0001");
		CHECK(read_json_string("\"a\\qb\"", tmp, sizeof(tmp)) == NULL,
		      "checker rejects \\q");
		CHECK(read_json_string("\"a\\u00zzb\"", tmp, sizeof(tmp)) == NULL,
		      "checker rejects a short \\u escape");
		CHECK(read_json_string("\"abc", tmp, sizeof(tmp)) == NULL,
		      "checker rejects an unterminated string");
		raw[0] = '"'; raw[1] = 'a'; raw[2] = 0x01; raw[3] = '"'; raw[4] = '\0';
		CHECK(read_json_string((const char *) raw, tmp, sizeof(tmp)) == NULL,
		      "checker rejects a raw 0x01");
		raw[2] = (unsigned char) (CTRL_MAX - 1);
		CHECK(read_json_string((const char *) raw, tmp, sizeof(tmp)) == NULL,
		      "checker rejects the last control character");
	}

	/* 1. Every control character, on its own, in both builders. */
	for (c = 1; c < CTRL_MAX; c++) {
		in[0] = 'a'; in[1] = (char) c; in[2] = 'b'; in[3] = '\0';

		memset(out, '?', sizeof(out));
		sprintf(msg, "addJsonStringEsc: 0x%02X yields valid JSON", c);
		CHECK(roundtrip_object(in, out, sizeof(out)), msg);
		sprintf(msg, "addJsonStringEsc: 0x%02X survives the round trip", c);
		CHECK(strcmp(out, in) == 0, msg);

		memset(out, '?', sizeof(out));
		sprintf(msg, "addJsonArrayString: 0x%02X yields valid JSON", c);
		CHECK(roundtrip_array(in, out, sizeof(out)), msg);
		sprintf(msg, "addJsonArrayString: 0x%02X survives the round trip", c);
		CHECK(strcmp(out, in) == 0, msg);
	}

	/* 2. The five characters with a short form use it. */
	{
		static const struct { char ch; const char *esc; } shorts[] = {
			{ '\b', "\\b" }, { '\f', "\\f" }, { '\n', "\\n" },
			{ '\r', "\\r" }, { '\t', "\\t" }
		};

		for (i = 0; i < sizeof(shorts) / sizeof(shorts[0]); i++) {
			in[0] = shorts[i].ch; in[1] = '\0';
			sprintf(expect, "%s", shorts[i].esc);
			text = object_text(in);
			sprintf(msg, "short form #%u is written as %s",
				(unsigned) i, shorts[i].esc);
			CHECK(text != NULL && strncmp(text, "{\"k\":\"", 6) == 0 &&
			      strncmp(text + 6, expect, 2) == 0 && text[8] == '"',
			      msg);
			free(text);
		}
	}

	/* 3. The long form is \u00XX. */
	in[0] = 0x01; in[1] = '\0';
	text = object_text(in);
	CHECK(text != NULL && strcmp(text, "{\"k\":\"\\u0001\"}") == 0,
	      "0x01 is written as \\u0001");
	free(text);

	/* 4. Quote and backslash are still escaped, ordinary text is untouched. */
	CHECK(roundtrip_object("say \"hi\" \\ there", out, sizeof(out)) &&
	      strcmp(out, "say \"hi\" \\ there") == 0,
	      "quote and backslash round-trip");
	CHECK(roundtrip_object("IEF403I JOB01234 - STARTED", out, sizeof(out)) &&
	      strcmp(out, "IEF403I JOB01234 - STARTED") == 0,
	      "ordinary text round-trips");
	text = object_text("plain");
	CHECK(text != NULL && strcmp(text, "{\"k\":\"plain\"}") == 0,
	      "ordinary text is written unchanged");
	free(text);

	/* 5. A string past the builder's initial buffer, every control character
	   in it, so growth happens in the middle of escapes. */
	n = 4000;
	big = malloc(n + 1);
	dec = malloc(n + 1);
	CHECK(big != NULL && dec != NULL, "allocate the long string");
	if (big && dec) {
		char *wide = malloc(n * 6 + 16);

		for (i = 0; i < n; i++) {
			unsigned k = (unsigned) (i % 40);
			big[i] = (char) (k < CTRL_MAX - 1 ? k + 1 : 'x');
		}
		big[n] = '\0';

		CHECK(wide != NULL, "allocate the output buffer");
		if (wide) {
			CHECK(roundtrip_object(big, wide, n * 6 + 16) &&
			      strcmp(wide, big) == 0,
			      "a long string of control characters round-trips (object)");
			CHECK(roundtrip_array(big, wide, n * 6 + 16) &&
			      strcmp(wide, big) == 0,
			      "a long string of control characters round-trips (array)");
			free(wide);
		}
	}
	free(big);
	free(dec);

	/* 6. NULL still means null. */
	text = object_text(NULL);
	CHECK(text != NULL && strcmp(text, "{\"k\":null}") == 0,
	      "a NULL value is still null");
	free(text);

	return mbt_test_summary("TSTJSON");
}
