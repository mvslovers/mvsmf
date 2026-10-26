/*
 * tstjerr.c - #480: an error report is valid JSON whatever the message holds.
 *
 * addJsonString() formatted its value into a 256-byte temp buffer with
 * snprintf(), so a value of 233 characters or more lost its closing quote
 * (and whatever else did not fit), snprintf() returned the wanted length, not
 * a negative number, and the caller saw success. It also wrote a quote or a
 * backslash in the value as it was, which ends the string early. Either way
 * the 400 body of a submit with a long (or quoted) "file" value could not be
 * parsed by the client.
 *
 * The report below is built the way sendErrorResponse() builds it: rc,
 * category, reason as numbers, then "message" through addJsonString(). The
 * document is read back by a strict reader that accepts exactly that shape and
 * rejects anything JSON does not define; the decoded message must equal the
 * input. The reader is checked against hand-written bad documents first,
 * because one that accepts everything proves nothing.
 *
 * The TU #includes src/json.c, so it drives the real builder.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <mbtcheck.h>

#include "../../src/json.c"

#define MSG_MAX	8192

static char msg[160];
static unsigned char xl[256];

/* host spelling -> ASCII, what http_etoa() does to a response */
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
}

static void
translate(char *s)
{
	for (; *s != '\0'; s++) *s = (char) xl[(unsigned char) *s];
}

/* a malloc'd ASCII copy of a host-spelled string */
static char *
ascii_dup(const char *src)
{
	char *d = malloc(strlen(src) + 1);

	if (d) {
		strcpy(d, src);
		translate(d);
	}
	return d;
}

/* number at s (ASCII digits); *end is the first byte after it */
static int
ascii_num(const char *s, const char **end)
{
	int n = 0;

	while ((unsigned char) *s >= 0x30 && (unsigned char) *s <= 0x39) {
		n = n * 10 + ((unsigned char) *s - 0x30);
		s++;
	}
	*end = s;
	return n;
}

/* 1 if the ASCII text at s starts with the host-spelled literal lit */
static int
ascii_starts(const char *s, const char *lit)
{
	char buf[32];

	strcpy(buf, lit);
	translate(buf);
	return strncmp(s, buf, strlen(buf)) == 0;
}

/* Read one JSON string at s (its opening quote), in ASCII as the client gets
   it. Returns the position after the closing quote, or NULL when the string
   is not valid JSON. Only the escapes the builder writes for printable text
   are accepted. */
static const char *
read_str(const char *s, char *out, size_t outsz)
{
	size_t o = 0;

	if ((unsigned char) *s != 0x22) return NULL;
	s++;

	while ((unsigned char) *s != 0x22) {
		unsigned char c = (unsigned char) *s;

		if (c == '\0') return NULL;			/* unterminated */
		if (c < 0x20) return NULL;			/* raw control character */
		if (o + 1 >= outsz) return NULL;

		if (c != 0x5C) {
			out[o++] = (char) c;
			s++;
			continue;
		}

		s++;
		switch ((unsigned char) *s) {
		case 0x22: out[o++] = 0x22; break;
		case 0x5C: out[o++] = 0x5C; break;
		case 0x2F: out[o++] = 0x2F; break;
		default:   return NULL;
		}
		s++;
	}

	out[o] = '\0';
	return s + 1;
}

/* Parse {"rc":N,"category":N,"reason":N,"message":"..."} (doc in ASCII); the
   decoded message goes to out, in ASCII. 1 if the document is exactly that,
   0 if not. */
static int
parse_report(const char *doc, char *out, size_t outsz, int *rc)
{
	const char *p = doc;

	if (!ascii_starts(p, "{\"rc\":")) return 0;
	p += 6;
	*rc = ascii_num(p, &p);
	if (!ascii_starts(p, ",\"category\":")) return 0;
	p += 12;
	(void) ascii_num(p, &p);
	if (!ascii_starts(p, ",\"reason\":")) return 0;
	p += 10;
	(void) ascii_num(p, &p);
	if (!ascii_starts(p, ",\"message\":")) return 0;
	p += 11;
	p = read_str(p, out, outsz);
	if (!p) return 0;
	if ((unsigned char) p[0] != xl[(unsigned char) '}'] || p[1] != '\0') return 0;
	return 1;
}

/* parse_report() on a host-spelled document, as a response is translated. */
static int
parse_host(const char *hostdoc, char *out, size_t outsz, int *rc)
{
	char *doc = ascii_dup(hostdoc);
	int ok;

	if (!doc) return 0;
	ok = parse_report(doc, out, outsz, rc);
	free(doc);
	return ok;
}

/* 1 if the ASCII text a equals the host-spelled string h. */
static int
ascii_equals(const char *a, const char *h)
{
	char *w = ascii_dup(h);
	int eq = w != NULL && strcmp(a, w) == 0;

	free(w);
	return eq;
}

/* The report for message, as the client receives it (ASCII); NULL if a builder call failed. */
static char *
report_text(const char *message, int *build_rc)
{
	JsonBuilder *b = createJsonBuilder(xl);
	char *doc = NULL;

	*build_rc = -1;
	if (!b) return NULL;
	if (startJsonObject(b) < 0) goto done;
	if (addJsonNumber(b, "rc", 8) < 0) goto done;
	if (addJsonNumber(b, "category", 6) < 0) goto done;
	if (addJsonNumber(b, "reason", 7) < 0) goto done;
	*build_rc = addJsonString(b, "message", message);
	if (*build_rc < 0) goto done;
	if (endJsonObject(b) < 0) { *build_rc = -1; goto done; }
	doc = getJsonString(b);
	if (doc) translate(doc);
done:
	freeJsonBuilder(b);
	return doc;
}

/* 1 if the report for message is valid JSON and the message survives. */
static int
report_roundtrips(const char *message)
{
	char *doc, *out, *want;
	int build_rc, rc = 0, ok = 0;

	out = malloc(MSG_MAX + 16);
	want = ascii_dup(message);
	if (!out || !want) {
		free(out);
		free(want);
		return 0;
	}

	doc = report_text(message, &build_rc);
	if (doc && build_rc == 0 && parse_report(doc, out, MSG_MAX + 16, &rc) &&
	    rc == 8 && strcmp(out, want) == 0) {
		ok = 1;
	}
	free(doc);
	free(out);
	free(want);
	return ok;
}

/* a message of n characters: "x" repeated, ending in 'E' so a cut shows */
static char *
make_msg(size_t n)
{
	char *s = malloc(n + 1);

	if (!s) return NULL;
	memset(s, 'x', n);
	if (n) s[n - 1] = 'E';
	s[n] = '\0';
	return s;
}

int
main(void)
{
	static const size_t lengths[] = {
		1, 100, 231, 232, 233, 234, 254, 255, 256, 257, 300, 1023, 1024,
		1025, 5000
	};
	size_t i;
	char *m;
	char tmp[64];
	char *doc;
	int build_rc;

	init_table();

	/* 0. The reader itself: known good and known bad documents. */
	{
		int rc;

		CHECK(parse_host("{\"rc\":8,\"category\":6,\"reason\":7,\"message\":\"abc\"}",
		                   tmp, sizeof(tmp), &rc) && ascii_equals(tmp, "abc"),
		      "reader accepts a report");
		CHECK(!parse_host("{\"rc\":8,\"category\":6,\"reason\":7,\"message\":\"abc",
		                    tmp, sizeof(tmp), &rc),
		      "reader rejects an unterminated message (the #480 shape)");
		CHECK(!parse_host("{\"rc\":8,\"category\":6,\"reason\":7,\"message\":\"a\"b\"}",
		                    tmp, sizeof(tmp), &rc),
		      "reader rejects an unescaped quote");
		CHECK(parse_host("{\"rc\":8,\"category\":6,\"reason\":7,\"message\":\"a\\\"b\"}",
		                   tmp, sizeof(tmp), &rc) && ascii_equals(tmp, "a\"b"),
		      "reader decodes an escaped quote");
		CHECK(!parse_host("{\"rc\":8,\"category\":6,\"reason\":7,\"message\":\"a\\qb\"}",
		                    tmp, sizeof(tmp), &rc),
		      "reader rejects an escape JSON does not define");
	}

	/* 1. Messages either side of the old 256-byte limit, and far above it. */
	for (i = 0; i < sizeof(lengths) / sizeof(lengths[0]); i++) {
		m = make_msg(lengths[i]);
		snprintf(msg, sizeof(msg), "message of %u characters is valid JSON",
		         (unsigned) lengths[i]);
		CHECK(m != NULL && report_roundtrips(m), msg);
		free(m);
	}

	/* 2. A quote and a backslash in the value, short and past the limit. */
	CHECK(report_roundtrips("Incorrect jobname: \"A B\""), "a quote in a short message");
	CHECK(report_roundtrips("path C:\\x\\y"), "a backslash in a short message");
	m = make_msg(600);
	if (m) {
		m[10] = '"';
		m[300] = '\\';
		m[590] = '"';
	}
	CHECK(m != NULL && report_roundtrips(m), "quotes and a backslash in a 600 character message");
	free(m);

	/* 3. Cut mid-escape at the old limit: the last character is a quote. */
	m = make_msg(232);
	if (m) m[231] = '"';
	CHECK(m != NULL && report_roundtrips(m), "a quote as the 232nd character");
	free(m);

	/* 4. The value does not swallow what comes after it. */
	{
		JsonBuilder *b = createJsonBuilder(xl);
		char *big = make_msg(5000);
		char *text = NULL;
		size_t len;

		if (b && big && startJsonObject(b) == 0 &&
		    addJsonString(b, "k", big) == 0 &&
		    addJsonNumber(b, "after", 42) == 0 &&
		    endJsonObject(b) == 0) {
			text = getJsonString(b);
			if (text) translate(text);
		}
		len = text ? strlen(text) : 0;
		CHECK(text != NULL && len > 5000 &&
		      ascii_equals(text + len - 12, ",\"after\":42}"),
		      "a member after a 5000 character value is intact");
		free(text);
		free(big);
		freeJsonBuilder(b);
	}

	/* 5. Unchanged: NULL is null, ordinary text is written as it was. */
	doc = report_text(NULL, &build_rc);
	CHECK(doc != NULL && build_rc == 0 && ascii_starts(doc + strlen(doc) - 16, ",\"message\":null}"),
	      "a NULL message is written as null");
	free(doc);
	doc = report_text("plain", &build_rc);
	CHECK(doc != NULL && ascii_equals(doc,
	      "{\"rc\":8,\"category\":6,\"reason\":7,\"message\":\"plain\"}"),
	      "ordinary text is written unchanged");
	free(doc);

	return mbt_test_summary("TSTJERR");
}
