/*
 * jobreq.c - which request a PUT on a job makes (#417).
 *
 * See include/jobreq.h. Deliberately free of MVS services: jobsapi.c cannot
 * compile on the host, so this lives in its own TU and test/host/tstjreq.c
 * drives the real code.
 */

#include <stddef.h>
#include <string.h>

#include "jobreq.h"

/* Whitespace is anything up to and including the blank: in ASCII and in
   EBCDIC alike every control character sorts below it, so the same test holds
   for a body translated from the wire without naming CR, LF or TAB. */
static const char *
skip_ws(const char *p)
{
	while (*p && (unsigned char)*p <= (unsigned char)' ') {
		p++;
	}
	return p;
}

/* p is at the opening quote. Returns the position after the closing quote,
   or NULL when the string never ends. start/len describe the raw contents. */
static const char *
scan_string(const char *p, const char **start, size_t *len)
{
	const char *s = p + 1;

	p = s;
	while (*p && *p != '"') {
		if (*p == '\\') {
			p++;
			if (!*p) {
				return NULL;
			}
		}
		p++;
	}
	if (*p != '"') {
		return NULL;
	}
	*start = s;
	*len = (size_t)(p - s);
	return p + 1;
}

/* p is at the first character of a value that is not a string at the top
   level of the object. Skips it, brackets and strings inside it included, up
   to the ',' or '}' that ends it. NULL when the body ends first. */
static const char *
skip_value(const char *p)
{
	int depth = 0;

	while (*p) {
		if (*p == '"') {
			const char *s;
			size_t n;

			p = scan_string(p, &s, &n);
			if (!p) {
				return NULL;
			}
			continue;
		}
		if (*p == '{' || *p == '[') {
			depth++;
		} else if (*p == '}' || *p == ']') {
			if (depth == 0) {
				return *p == '}' ? p : NULL;
			}
			depth--;
		} else if (*p == ',' && depth == 0) {
			return p;
		}
		p++;
	}
	return NULL;
}

#ifdef __MVS__
__asm__("\n&FUNC    SETC 'jobreq_parse'");
#endif
int
jobreq_parse(const char *body)
{
	const char *p;
	int found = JOBREQ_NONE;

	if (!body) {
		return JOBREQ_NONE;
	}

	p = skip_ws(body);
	if (*p != '{') {
		return JOBREQ_NONE;
	}
	p = skip_ws(p + 1);

	while (*p != '}') {
		const char *key;
		size_t klen;
		int is_request;
		int this = JOBREQ_UNKNOWN;

		if (*p != '"') {
			return JOBREQ_NONE;
		}
		p = scan_string(p, &key, &klen);
		if (!p) {
			return JOBREQ_NONE;
		}
		is_request = klen == 7 && memcmp(key, "request", 7) == 0;

		p = skip_ws(p);
		if (*p != ':') {
			return JOBREQ_NONE;
		}
		p = skip_ws(p + 1);

		if (*p == '"') {
			const char *val;
			size_t vlen;

			p = scan_string(p, &val, &vlen);
			if (!p) {
				return JOBREQ_NONE;
			}
			if (vlen == 6 && memcmp(val, "cancel", 6) == 0) {
				this = JOBREQ_CANCEL;
			} else if (vlen == 4 && memcmp(val, "hold", 4) == 0) {
				this = JOBREQ_HOLD;
			} else if (vlen == 7 && memcmp(val, "release", 7) == 0) {
				this = JOBREQ_RELEASE;
			}
		} else {
			p = skip_value(p);
			if (!p) {
				return JOBREQ_NONE;
			}
		}
		if (is_request) {
			found = this;
		}

		p = skip_ws(p);
		if (*p == ',') {
			p = skip_ws(p + 1);
		} else if (*p != '}') {
			return JOBREQ_NONE;
		}
	}

	return found;
}
