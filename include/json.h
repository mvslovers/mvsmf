#ifndef JSON_H
#define JSON_H

/**
 * @file json.h
 * @brief JSON builder implementation for MVS 3.8j
 *
 * Provides functionality for building JSON objects and arrays.
 * Implements memory-efficient string building with automatic buffer management.
 */

#include <stddef.h>

/** @brief Initial size of JSON buffer in bytes */
#define JSON_INITIAL_BUFFER_SIZE 	1024

/** @brief Size of temporary buffer for string operations */
#define JSON_TEMP_BUFFER_SIZE 		256

/** @brief Factor by which buffer grows when full */
#define JSON_GROWTH_FACTOR 			2

/** @brief Memory alignment for JSON builder structure */
#define JSON_BUILDER_ALIGNMENT 		32

/**
 * @brief JSON builder structure for constructing JSON strings
 *
 * Maintains state and buffer for incrementally building JSON content.
 * Uses dynamic memory allocation with automatic growth when needed.
 */
typedef struct json_builder JsonBuilder;
struct __attribute__((aligned(JSON_BUILDER_ALIGNMENT))) json_builder {
	int is_first;
	char *buffer;
	size_t size;
	size_t capacity;
	int has_etoa;
	unsigned char etoa[256];
};

/**
 * @brief Creates a new JSON builder instance
 *
 * Allocates and initializes a new JSON builder with default capacity.
 *
 * The builder runs in the host character set and the response is translated to
 * ASCII only afterwards, so an escape must be decided on the byte the client
 * will receive. etoa is the 256-byte table that translation uses (what
 * http_etoa() applies; createResponseBuilder() in common.h gets it); a control
 * character is then written as \u00XX with XX the code point it translates to,
 * not the host byte. The table is copied. NULL means the text is ASCII already
 * and is only for a host test.
 *
 * @param etoa  the table the finished document will be translated with
 * @return Pointer to new JsonBuilder or NULL on allocation failure
 */
JsonBuilder *createJsonBuilder(const unsigned char *etoa)					asm("JSON000");

/**
 * @brief Frees a JSON builder instance
 *
 * Releases all memory associated with the JSON builder.
 *
 * @param builder Pointer to JsonBuilder to free
 */
void freeJsonBuilder(JsonBuilder *builder)									asm("JSON001");

/**
 * @brief Adds a string key-value pair to the JSON object
 *
 * Adds a quoted string value with the specified key. If value is NULL,
 * adds "null" instead of a string. The value is JSON-escaped and may be of any
 * length, exactly as addJsonStringEsc() writes it (#480).
 *
 * @param builder Pointer to JsonBuilder
 * @param key Key name for the value
 * @param value String value or NULL
 * @return 0 on success, negative value on error
 */
int addJsonString(JsonBuilder *builder, const char *key, const char *value) asm("JSON002");

/**
 * @brief Adds a numeric key-value pair to the JSON object
 *
 * Adds an integer value with the specified key.
 *
 * @param builder Pointer to JsonBuilder
 * @param key Key name for the value
 * @param value Integer value
 * @return 0 on success, negative value on error
 */
int addJsonNumber(JsonBuilder *builder, const char *key, int value) 		asm("JSON003");

/**
 * @brief Adds a null value with the specified key
 *
 * @param builder Pointer to JsonBuilder
 * @param key Key name for the null value
 * @return 0 on success, negative value on error
 */
int addJsonNull(JsonBuilder *builder, const char *key)						asm("JSON004");

/**
 * @brief Adds a string value, JSON-escaping it (quote, backslash, control
 *        characters) and handling arbitrary length. Use for values that may
 *        contain control characters such as console command responses.
 */
int addJsonStringEsc(JsonBuilder *builder, const char *key, const char *value) asm("JSON00A");

/**
 * @brief Adds a JSON boolean (true/false) with the specified key.
 */
int addJsonBool(JsonBuilder *builder, const char *key, int value)			asm("JSON00B");

/**
 * @brief Adds "key": <raw> with the value emitted verbatim (no quoting).
 * For numbers too large for addJsonNumber's int (e.g. a UNIX ms timestamp).
 */
int addJsonRaw(JsonBuilder *builder, const char *key, const char *raw)		asm("JSON00C");

/**
 * @brief Opens a keyed array ("key":[) and primes the builder so the first
 * element gets no leading comma. Close with endArray().
 */
int startJsonArrayKey(JsonBuilder *builder, const char *key)				asm("JSON00D");

/**
 * @brief Adds a bare string element to an open array (no key).
 *
 * The keyed adders above cannot produce an array of plain strings -- every one
 * of them emits "key":value -- and the arrays this builder emitted until now
 * held objects, which startJsonObject() handles. An error report's "details"
 * is an array of sentences, so it needs this.
 *
 * Escapes as addJsonStringEsc() does; a NULL value emits null.
 */
int addJsonArrayString(JsonBuilder *builder, const char *value)				asm("JSON00E");

/** @brief jsonEscapeBytes(): also write every byte that translates to a code
 *         point above U+007E as \\u00XX. For text that is not allowed to reach
 *         the client as anything but 7-bit ASCII (member names). Without it a
 *         byte above U+009F is left as it is. */
#define JSON_ESC_NONASCII	1

/** @brief The most characters one escaped byte takes: \\u00XX */
#define JSON_ESC_MAX		6

/**
 * @brief Escapes raw bytes as the body of a JSON string.
 *
 * The one routine behind the builder's string values and the member names of
 * the data set listing: the decision is made on etoa[byte], the character the
 * client will see once the response is translated. A quote and a backslash
 * get their escape, so do the five controls with a short form (\\b \\f \\n
 * \\r \\t), and every other control character (below U+0020, U+007F to
 * U+009F) becomes \\u00XX, XX being the translated code point. What is not
 * escaped is copied as the host byte, for the translation to turn into ASCII;
 * the numeric tests are on the translated byte and therefore on ASCII values.
 *
 * Stops, terminating out, when fewer than JSON_ESC_MAX + 1 bytes are left.
 *
 * @param out     result buffer
 * @param outlen  size of out
 * @param raw     the bytes, host character set, not necessarily NUL ended
 * @param rawlen  number of bytes
 * @param etoa    the translation table of the response, NULL if none
 * @param flags   0 or JSON_ESC_NONASCII
 * @return number of characters written, without the terminator
 */
size_t jsonEscapeBytes(char *out, size_t outlen, const unsigned char *raw,
                       unsigned rawlen, const unsigned char *etoa, int flags) asm("JSON00F");

/**
 * @brief Starts a new JSON object
 *
 * Adds an opening brace and prepares for object members.
 *
 * @param builder Pointer to JsonBuilder
 * @return 0 on success, negative value on error
 */
int startJsonObject(JsonBuilder *builder)									asm("JSON005");

/**
 * @brief Ends the current JSON object
 *
 * Adds a closing brace to complete the object.
 *
 * @param builder Pointer to JsonBuilder
 * @return 0 on success, negative value on error
 */
int endJsonObject(JsonBuilder *builder)										asm("JSON006");

/**
 * @brief Gets the built JSON string
 *
 * Returns a copy of the complete JSON string.
 * Caller must free the returned string.
 *
 * @param builder Pointer to JsonBuilder
 * @return Pointer to new string or NULL on error
 */
char *getJsonString(JsonBuilder *builder)									asm("JSON007");

/**
 * @brief Starts a new JSON array
 *
 * Adds an opening bracket and prepares for array elements.
 *
 * @param builder Pointer to JsonBuilder
 * @return 0 on success, negative value on error
 */
int startArray(JsonBuilder *builder)										asm("JSON008");

/**
 * @brief Ends the current JSON array
 *
 * Adds a closing bracket to complete the array.
 *
 * @param builder Pointer to JsonBuilder
 * @return 0 on success, negative value on error
 */
int endArray(JsonBuilder *builder)											asm("JSON009");

#endif // JSON_H
