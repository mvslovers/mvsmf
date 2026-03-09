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
};

/**
 * @brief Creates a new JSON builder instance
 *
 * Allocates and initializes a new JSON builder with default capacity.
 *
 * @return Pointer to new JsonBuilder or NULL on allocation failure
 */
JsonBuilder *createJsonBuilder(void)										asm("JSON000");

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
 * adds "null" instead of a string.
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
