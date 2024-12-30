#ifndef JSON_H
#define JSON_H

#include <stddef.h>

#define JSON_INITIAL_BUFFER_SIZE 	1024
#define JSON_TEMP_BUFFER_SIZE 		256
#define JSON_GROWTH_FACTOR 			2
#define JSON_BUILDER_ALIGNMENT 		32

typedef struct json_builder JsonBuilder;
struct __attribute__((aligned(JSON_BUILDER_ALIGNMENT))) json_builder {
	int is_first;
	char *buffer;
	size_t size;
	size_t capacity;
};

JsonBuilder *createJsonBuilder(void)										asm("JSON000");
void freeJsonBuilder(JsonBuilder *builder)									asm("JSON001");
int addJsonString(JsonBuilder *builder, const char *key, const char *value) asm("JSON002");
int addJsonNumber(JsonBuilder *builder, const char *key, int value) 		asm("JSON003");
int addJsonNull(JsonBuilder *builder, const char *key)						asm("JSON004");
int startJsonObject(JsonBuilder *builder)									asm("JSON005");
int endJsonObject(JsonBuilder *builder)										asm("JSON006");
char *getJsonString(JsonBuilder *builder)									asm("JSON007");
int startArray(JsonBuilder *builder)										asm("JSON008");
int endArray(JsonBuilder *builder)											asm("JSON009");

#endif // JSON_H
