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

/* Read one JSON string at s (its opening quote). Returns the position after
   the closing quote, or NULL when the string is not valid JSON. Only the
   escapes the builder writes for printable text are accepted. */
static const char *
read_str(const char *s, char *out, size_t outsz)
{
	size_t o = 0;

	if (*s != '"') return NULL;
	s++;

	while (*s != '"') {
		unsigned char c = (unsigned char) *s;

		if (c == '\0') return NULL;			/* unterminated */
		if (c < (unsigned) ' ') return NULL;		/* raw control character */
		if (o + 1 >= outsz) return NULL;

		if (c != '\\') {
			out[o++] = (char) c;
			s++;
			continue;
		}

		s++;
		switch (*s) {
		case '"':  out[o++] = '"';  break;
		case '\\': out[o++] = '\\'; break;
		case '/':  out[o++] = '/';  break;
		default:   return NULL;
		}
		s++;
	}

	out[o] = '\0';
	return s + 1;
}

/* Parse {"rc":N,"category":N,"reason":N,"message":"..."}; the decoded message
   goes to out. 1 if the document is exactly that, 0 if not. */
static int
parse_report(const char *doc, char *out, size_t outsz, int *rc)
{
	const char *p = doc;

	if (strncmp(p, "{\"rc\":", 6) != 0) return 0;
	p += 6;
	*rc = (int) strtol(p, (char **) &p, 10);
	if (strncmp(p, ",\"category\":", 12) != 0) return 0;
	p += 12;
	(void) strtol(p, (char **) &p, 10);
	if (strncmp(p, ",\"reason\":", 10) != 0) return 0;
	p += 10;
	(void) strtol(p, (char **) &p, 10);
	if (strncmp(p, ",\"message\":", 11) != 0) return 0;
	p += 11;
	p = read_str(p, out, outsz);
	if (!p) return 0;
	if (p[0] != '}' || p[1] != '\0') return 0;
	return 1;
}

/* The report for message, as text; NULL if a builder call failed. */
static char *
report_text(const char *message, int *build_rc)
{
	JsonBuilder *b = createJsonBuilder();
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
done:
	freeJsonBuilder(b);
	return doc;
}

/* 1 if the report for message is valid JSON and the message survives. */
static int
report_roundtrips(const char *message)
{
	char *doc, *out;
	int build_rc, rc = 0, ok = 0;

	out = malloc(MSG_MAX + 16);
	if (!out) return 0;

	doc = report_text(message, &build_rc);
	if (doc && build_rc == 0 && parse_report(doc, out, MSG_MAX + 16, &rc) &&
	    rc == 8 && strcmp(out, message) == 0) {
		ok = 1;
	}
	free(doc);
	free(out);
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

	/* 0. The reader itself: known good and known bad documents. */
	{
		int rc;

		CHECK(parse_report("{\"rc\":8,\"category\":6,\"reason\":7,\"message\":\"abc\"}",
		                   tmp, sizeof(tmp), &rc) && strcmp(tmp, "abc") == 0,
		      "reader accepts a report");
		CHECK(!parse_report("{\"rc\":8,\"category\":6,\"reason\":7,\"message\":\"abc",
		                    tmp, sizeof(tmp), &rc),
		      "reader rejects an unterminated message (the #480 shape)");
		CHECK(!parse_report("{\"rc\":8,\"category\":6,\"reason\":7,\"message\":\"a\"b\"}",
		                    tmp, sizeof(tmp), &rc),
		      "reader rejects an unescaped quote");
		CHECK(parse_report("{\"rc\":8,\"category\":6,\"reason\":7,\"message\":\"a\\\"b\"}",
		                   tmp, sizeof(tmp), &rc) && strcmp(tmp, "a\"b") == 0,
		      "reader decodes an escaped quote");
		CHECK(!parse_report("{\"rc\":8,\"category\":6,\"reason\":7,\"message\":\"a\\qb\"}",
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
		JsonBuilder *b = createJsonBuilder();
		char *big = make_msg(5000);
		char *text = NULL;
		size_t len;

		if (b && big && startJsonObject(b) == 0 &&
		    addJsonString(b, "k", big) == 0 &&
		    addJsonNumber(b, "after", 42) == 0 &&
		    endJsonObject(b) == 0) {
			text = getJsonString(b);
		}
		len = text ? strlen(text) : 0;
		CHECK(text != NULL && len > 5000 &&
		      strcmp(text + len - 12, ",\"after\":42}") == 0,
		      "a member after a 5000 character value is intact");
		free(text);
		free(big);
		freeJsonBuilder(b);
	}

	/* 5. Unchanged: NULL is null, ordinary text is written as it was. */
	doc = report_text(NULL, &build_rc);
	CHECK(doc != NULL && build_rc == 0 && strstr(doc, ",\"message\":null}") != NULL,
	      "a NULL message is written as null");
	free(doc);
	doc = report_text("plain", &build_rc);
	CHECK(doc != NULL && strcmp(doc,
	      "{\"rc\":8,\"category\":6,\"reason\":7,\"message\":\"plain\"}") == 0,
	      "ordinary text is written unchanged");
	free(doc);

	return mbt_test_summary("TSTJERR");
}
