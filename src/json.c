#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "json.h"

static int append_string(JsonBuilder *builder, const char *str);
static int append_quoted(JsonBuilder *builder, const char *value);

JsonBuilder *
createJsonBuilder(void) 
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

int 
addJsonString(JsonBuilder *builder, const char *key, const char *value) 
{
    if (!builder || !key) {
        return -1;
    }
    
    char temp[JSON_TEMP_BUFFER_SIZE];
    
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
    
    if (value) {
        if ((snprintf(temp, sizeof(temp), "\"%s\"", value)) < 0) {
            return -1;
        }
    } else {
        if ((snprintf(temp, sizeof(temp), "null")) < 0) {
            return -1;
        }
    }
    
    if (append_string(builder, temp) < 0) {
        return -1;
    }
    
    builder->is_first = 0;

    return 0;
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
__asm__("\n&FUNC    SETC 'append_quoted'");
#endif
/* Append value as a quoted JSON string. One piece at a time, so there is no
 * fixed temp buffer and the length is not capped.
 *
 * RFC 8259 forbids every character below U+0020 inside a string. In the
 * execution character set that is every byte below ' ' -- 0x20 in ASCII, 0x40
 * in EBCDIC, where the response is translated only after this runs -- so the
 * test is written against ' ' and not against a number. The five with a short
 * form use it; the rest become \u00XX, XX being the byte as it stands here
 * (on MVS the host byte, not its ASCII image; the escape is still valid). */
static int
append_quoted(JsonBuilder *builder, const char *value)
{
    const char *p;
    char one[2];
    char esc[8];

    if (append_string(builder, "\"") < 0) return -1;
    one[1] = '\0';
    for (p = value; *p; p++) {
        int rc;
        switch (*p) {
        case '"':  rc = append_string(builder, "\\\""); break;
        case '\\': rc = append_string(builder, "\\\\"); break;
        case '\b': rc = append_string(builder, "\\b");  break;
        case '\f': rc = append_string(builder, "\\f");  break;
        case '\r': rc = append_string(builder, "\\r");  break;
        case '\n': rc = append_string(builder, "\\n");  break;
        case '\t': rc = append_string(builder, "\\t");  break;
        default:
            if ((unsigned char)*p < (unsigned char)' ') {
                snprintf(esc, sizeof(esc), "\\u%04X", (unsigned)(unsigned char)*p);
                rc = append_string(builder, esc);
            } else {
                one[0] = *p;
                rc = append_string(builder, one);
            }
            break;
        }
        if (rc < 0) return -1;
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
