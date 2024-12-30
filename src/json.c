#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "json.h"

static int append_string(JsonBuilder *builder, const char *str);

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

    return append_string(builder, "]");
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

__asm__("\n&FUNC    SETC 'ensure_capacity'");
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

__asm__("\n&FUNC    SETC 'append_string'");
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
