#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "json.h"

static int append_string(JsonBuilder *builder, const char *str);
static int append_quoted(JsonBuilder *builder, const char *value);
static size_t escape_char(char *out, unsigned char host,
                          const unsigned char *etoa, int flags);

JsonBuilder *
createJsonBuilder(const unsigned char *etoa)
{
    JsonBuilder *builder = calloc(1, sizeof(JsonBuilder));
    if (!builder) {
        return NULL;
    }
    
    builder->buffer = calloc(1, JSON_INITIAL_BUFFER_SIZE);
    if (!builder->buffer) {
        free(builder);
        return NULL;
    }
    
    builder->capacity = JSON_INITIAL_BUFFER_SIZE;
    builder->size = 0;
    builder->is_first = 1;
    if (etoa) {
        memcpy(builder->etoa, etoa, sizeof(builder->etoa));
        builder->has_etoa = 1;
    }

    return builder;
}

void 
freeJsonBuilder(JsonBuilder *builder) 
{
    if (!builder) {
        return;
    }

    if (builder->buffer) {
        free(builder->buffer);
    }

    free(builder);
}

int 
startJsonObject(JsonBuilder *builder) 
{
    if (!builder) {
        return -1;
    }
    
    if (!builder->is_first) {
        if (append_string(builder, ",") < 0) {
            return -1;
        }
    }
    
    if (append_string(builder, "{") < 0) {
        return -1;
    }
    
    builder->is_first = 1;
    return 0;
}

int 
endJsonObject(JsonBuilder *builder) 
{
    if (!builder) {
		return -1;
	}

    if (append_string(builder, "}") < 0) {
		return -1;
	}

    builder->is_first = 0;
    
	return 0;
}

int 
startArray(JsonBuilder *builder) 
{
    if (!builder) {
		return -1;
	}

    return append_string(builder, "[");
}

int
endArray(JsonBuilder *builder)
{
    if (!builder) {
		return -1;
	}

    if (append_string(builder, "]") < 0) {
        return -1;
    }

    /* a value following a closed array needs a separating comma */
    builder->is_first = 0;

    return 0;
}

/* Add "key": <raw> where raw is emitted verbatim (no quoting/escaping).
 * Used for numeric values that do not fit addJsonNumber's int, e.g. a
 * pre-formatted 64-bit UNIX millisecond timestamp. */
int
addJsonRaw(JsonBuilder *builder, const char *key, const char *raw)
{
    if (!builder || !key || !raw) {
        return -1;
    }

    if (!builder->is_first) {
        if (append_string(builder, ",") < 0) {
            return -1;
        }
    }

    if (append_string(builder, "\"") < 0) return -1;
    if (append_string(builder, key) < 0) return -1;
    if (append_string(builder, "\":") < 0) return -1;
    if (append_string(builder, raw) < 0) return -1;

    builder->is_first = 0;

    return 0;
}

/* Open a keyed array: emits "key":[ and primes is_first so the first array
 * element (typically startJsonObject) does not get a leading comma. Close it
 * with endArray(). */
int
startJsonArrayKey(JsonBuilder *builder, const char *key)
{
    if (!builder || !key) {
        return -1;
    }

    if (!builder->is_first) {
        if (append_string(builder, ",") < 0) {
            return -1;
        }
    }

    if (append_string(builder, "\"") < 0) return -1;
    if (append_string(builder, key) < 0) return -1;
    if (append_string(builder, "\":[") < 0) return -1;

    builder->is_first = 1;

    return 0;
}

/* Same as addJsonStringEsc(). It used to format "key":"value" into a 256-byte
 * temp buffer: a value of 254 characters or more lost its closing quote, snprintf()
 * returned the wanted length (not < 0) so the caller saw success, and a quote or
 * backslash in the value was written as it stood (#480). */
int 
addJsonString(JsonBuilder *builder, const char *key, const char *value) 
{
    return addJsonStringEsc(builder, key, value);
}

int
addJsonStringEsc(JsonBuilder *builder, const char *key, const char *value)
{
    if (!builder || !key) {
        return -1;
    }

    if (!builder->is_first) {
        if (append_string(builder, ",") < 0) return -1;
    }
    if (append_string(builder, "\"") < 0) return -1;
    if (append_string(builder, key) < 0) return -1;
    if (append_string(builder, "\":") < 0) return -1;

    if (!value) {
        if (append_string(builder, "null") < 0) return -1;
        builder->is_first = 0;
        return 0;
    }

    if (append_quoted(builder, value) < 0) return -1;

    builder->is_first = 0;
    return 0;
}

int
addJsonArrayString(JsonBuilder *builder, const char *value)
{
    if (!builder) {
        return -1;
    }

    if (!builder->is_first) {
        if (append_string(builder, ",") < 0) return -1;
    }

    if (!value) {
        if (append_string(builder, "null") < 0) return -1;
        builder->is_first = 0;
        return 0;
    }

    if (append_quoted(builder, value) < 0) return -1;

    builder->is_first = 0;
    return 0;
}

int
addJsonBool(JsonBuilder *builder, const char *key, int value)
{
    if (!builder || !key) {
        return -1;
    }
    if (!builder->is_first) {
        if (append_string(builder, ",") < 0) return -1;
    }
    if (append_string(builder, "\"") < 0) return -1;
    if (append_string(builder, key) < 0) return -1;
    if (append_string(builder, "\":") < 0) return -1;
    if (append_string(builder, value ? "true" : "false") < 0) return -1;
    builder->is_first = 0;
    return 0;
}

int
addJsonNumber(JsonBuilder *builder, const char *key, int value)
{
    char temp[JSON_TEMP_BUFFER_SIZE];

    if (!builder || !key) {
		return -1;
	}

    if (!builder->is_first) {
        if (append_string(builder, ",") < 0) {
			return -1;
		}
    }
    
    if ((snprintf(temp, sizeof(temp), "\"%s\":", key)) < 0) {
        return -1;
    }

    if (append_string(builder, temp) < 0) {
		return -1;
	}
    
    if ((snprintf(temp, sizeof(temp), "%d", value)) < 0) {
        return -1;
    }

    if (append_string(builder, temp) < 0) { 
		return -1;
	}
    
    builder->is_first = 0;
    
	return 0;
}

char *
getJsonString(JsonBuilder *builder) 
{
    if (!builder) {
		return NULL;
	}

    return strdup(builder->buffer);
}

// private functions

#ifdef __MVS__
__asm__("\n&FUNC    SETC 'escape_char'");
#endif
/* One character of a JSON string. host is the byte as it stands in the buffer;
 * the decision is on a, the byte the client receives once the response has been
 * translated with etoa (a == host if there is no table). So the numbers below
 * are ASCII values on purpose: 0x22 and 0x5C are the quote and the backslash
 * the parser will see, which is not the mistake the root CLAUDE.md warns of.
 *
 * RFC 8259 forbids every character below U+0020 inside a string. The five with
 * a short form use it; every other control character, U+007F to U+009F
 * included, becomes \u00XX, XX being a and not the host byte (on MVS the host
 * byte is EBCDIC: 0x05 is the TAB U+0009 the client decodes, not U+0005).
 * What stays raw is the host byte itself, for the translation to turn into
 * ASCII -- unless JSON_ESC_NONASCII asks for everything above U+007E as an
 * escape too. Writes at most JSON_ESC_MAX characters, no terminator. */
static size_t
escape_char(char *out, unsigned char host, const unsigned char *etoa, int flags)
{
    unsigned char a = etoa ? etoa[host] : host;

    switch (a) {
    case 0x22: memcpy(out, "\\\"", 2); return 2;
    case 0x5C: memcpy(out, "\\\\", 2); return 2;
    case 0x08: memcpy(out, "\\b", 2);  return 2;
    case 0x0C: memcpy(out, "\\f", 2);  return 2;
    case 0x0D: memcpy(out, "\\r", 2);  return 2;
    case 0x0A: memcpy(out, "\\n", 2);  return 2;
    case 0x09: memcpy(out, "\\t", 2);  return 2;
    default:
        break;
    }

    if (a < 0x20 || (a >= 0x7F && (a <= 0x9F || (flags & JSON_ESC_NONASCII)))) {
        return (size_t) sprintf(out, "\\u%04X", (unsigned) a);
    }

    out[0] = (char) host;
    return 1;
}

size_t
jsonEscapeBytes(char *out, size_t outlen, const unsigned char *raw,
                unsigned rawlen, const unsigned char *etoa, int flags)
{
    size_t o = 0;
    unsigned i;

    if (outlen == 0) {
        return 0;
    }

    for (i = 0; i < rawlen; i++) {
        /* room for the longest escape plus the terminator */
        if (o + JSON_ESC_MAX >= outlen) break;

        o += escape_char(&out[o], raw[i], etoa, flags);
    }

    out[o] = '\0';
    return o;
}

#ifdef __MVS__
__asm__("\n&FUNC    SETC 'append_quoted'");
#endif
/* Append value as a quoted JSON string. One piece at a time, so there is no
 * fixed temp buffer and the length is not capped. What each character becomes
 * is escape_char()'s decision, on the table the builder was created with. */
static int
append_quoted(JsonBuilder *builder, const char *value)
{
    const char *p;
    char esc[JSON_ESC_MAX + 1];

    if (append_string(builder, "\"") < 0) return -1;
    for (p = value; *p; p++) {
        size_t n = escape_char(esc, (unsigned char) *p,
                               builder->has_etoa ? builder->etoa : NULL, 0);

        esc[n] = '\0';
        if (append_string(builder, esc) < 0) return -1;
    }
    return append_string(builder, "\"");
}

#ifdef __MVS__
__asm__("\n&FUNC    SETC 'ensure_capacity'");
#endif
static int 
ensure_capacity(JsonBuilder *builder, size_t needed) 
{
    if (builder->size + needed >= builder->capacity) {
        size_t new_capacity = builder->capacity * JSON_GROWTH_FACTOR;
        if (new_capacity < builder->size + needed) {
            new_capacity = builder->size + needed + JSON_INITIAL_BUFFER_SIZE;
        }
        
        char *new_buffer = realloc(builder->buffer, new_capacity);
        if (!new_buffer) {
			return -1;
		}
        
        builder->buffer = new_buffer;
        builder->capacity = new_capacity;
    }
    
	return 0;
}

#ifdef __MVS__
__asm__("\n&FUNC    SETC 'append_string'");
#endif
static int 
append_string(JsonBuilder *builder, const char *str) 
{
    size_t len = strlen(str);
    if (ensure_capacity(builder, len + 1) < 0) {
		return -1;
	}
    
    strcpy(builder->buffer + builder->size, str);
    builder->size += len;
    
	return 0;
}
