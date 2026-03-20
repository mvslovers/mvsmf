#include <clibstr.h>
#include <clibio.h>
#include <clibthrd.h>
#include <clibwto.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "common.h"
#include "httpcgi.h"
#include "json.h"

#define INITIAL_BUFFER_SIZE 4096

//
// private function prototypes
//

static int send_data(Session *session, char *buf);
static char *get_env_param(Session *session, const char *prefix, const char *name);

//
// public functions
//

char *
getQueryParam(Session *session, const char *name)
{
	return get_env_param(session, "QUERY_", name);
}

char *
getPathParam(Session *session, const char *name)
{
	return get_env_param(session, "HTTP_", name);
}

char *
getHeaderParam(Session *session, const char *name)
{
	return get_env_param(session, "HTTP_", name);
}

int 
sendDefaultHeaders(Session *session, int status, const char *content_type,
					   size_t content_length)
{
	int irc = 0;

	session->headers_sent = 1;

	irc = http_resp(session->httpc, status);
	if (irc < 0) {
		goto quit;
	}

	if (content_type && (strcmp(HTTP_CONTENT_TYPE_NONE, content_type) != 0)) {
		irc = http_printf(session->httpc, "Content-Type: %s\r\n", content_type);
		if (irc < 0) {
			goto quit;
		}
	}

	if (content_length > 0) {
		irc = http_printf(session->httpc, "Content-Length: %d\r\n", content_length);
		if (irc < 0) {
			goto quit;
		}
	}

  	irc = http_printf(session->httpc, "Cache-Control: no-store\r\n");
  	if (irc < 0) {
		goto quit;
 	}

  	irc = http_printf(session->httpc, "Access-Control-Allow-Origin: *\r\n");
  	if (irc < 0) {
		goto quit;
  	}

  	irc = http_printf(session->httpc, "\r\n");
  	if (irc < 0) {
		goto quit;
  	}

quit:
	return irc;
}

int 
sendJSONResponse(Session *session, int status, JsonBuilder *builder)
{
  	int irc = 0;
  	char *json_str = NULL;

	if (!builder) {
		irc = -1;
		goto quit;
	}

	json_str = getJsonString(builder);
	if (!json_str) {
		irc = -1;
		goto quit;
	}

	irc = sendDefaultHeaders(session, status, HTTP_CONTENT_TYPE_JSON,
							strlen(json_str));
	if (irc < 0) {
		goto quit;
	}

	irc = send_data(session, json_str);

quit:
	if (json_str) {
		free(json_str);
	}

  	return irc;
}

int 
sendErrorResponse(Session *session, int status, int category, int rc,
					  int reason, const char *message, const char **details,
					  int details_count)
{
	int irc = RC_SUCCESS;  

	JsonBuilder *builder = createJsonBuilder();
	if (!builder) {
		goto quit;
	}

	irc = startJsonObject(builder);
	if (irc < 0) {
		goto quit;
	}

	irc = addJsonNumber(builder, "rc", rc);
	if (irc < 0) {
		goto quit;
	}

	irc = addJsonNumber(builder, "category", category);
	if (irc < 0) {
		goto quit;
	}

	irc = addJsonNumber(builder, "reason", reason);
	if (irc < 0) {
		goto quit;
	}

	if (message) {
		irc = addJsonString(builder, "message", message);
		if (irc < 0) {
			goto quit;
		}
	}

	if (details && details_count > 0) {
		irc = addJsonString(builder, "details", details[0]);
		if (irc < 0) {
		goto quit;
		}
	}

	irc = endJsonObject(builder);
	if (irc < 0) {
		goto quit;
	}

	irc = sendJSONResponse(session, status, builder);

quit:
	if (builder) {
		freeJsonBuilder(builder);
	}

	return irc;
}

//
// Read raw data from socket, one byte at a time.
// Works around the MVS 3.8j TCP/IP ring buffer bug that corrupts data
// when a multi-byte recv() spans the internal buffer wrap-around point.
// DO NOT change to multi-byte recv().
//

#define RAW_RECV_MAX_RETRIES 200

__asm__("\n&FUNC    SETC 'recv_raw_data'");
static int
receive_raw_data(HTTPC *httpc, char *buf, int len)
{
	int total = 0;
	int n = 0;
	int retries = 0;
	unsigned ecb = 0;
	int sockfd = httpc->socket;

	while (total < len) {
		n = recv(sockfd, buf + total, 1, 0);
		if (n < 0) {
			if (errno == EINTR) continue;
			if (errno == EWOULDBLOCK) {
				if (++retries > RAW_RECV_MAX_RETRIES) {
					wtof("MVSMF80E recv() EWOULDBLOCK timeout after %d retries",
						retries);
					return -1;
				}
				ecb = 0;
				cthread_timed_wait((void *)&ecb, 5, 0);
				continue;
			}
			return -1;
		}
		if (n == 0) break;
		retries = 0;
		total += n;
	}

	return total;
}

//
// Read the full request body into a malloc'd buffer.
// Supports both Content-Length and Transfer-Encoding: chunked.
// Caller must free the returned buffer via free().
// Returns 0 on success, -1 on error.
//

int
read_request_content(Session *session, char **content, size_t *content_size)
{
	size_t buffer_size = 0;
	int bytes_received = 0;
	int has_content_length = 0;
	size_t content_length = 0;
	int is_chunked = 0;
	int done = 0;

	// Check Content-Length header
	const char *cl_str = getHeaderParam(session, "Content-Length");
	if (cl_str != NULL) {
		has_content_length = 1;
		content_length = strtoul(cl_str, NULL, 10);
	}

	// Check Transfer-Encoding header
	const char *te = getHeaderParam(session, "Transfer-Encoding");
	if (te != NULL && strstr(te, "chunked") != NULL) {
		is_chunked = 1;
	}

	if (!is_chunked && !has_content_length) {
		wtof("MVSMF22E Missing Content-Length or Transfer-Encoding header");
		return -1;
	}

	// Allocate initial buffer
	*content = malloc(INITIAL_BUFFER_SIZE);
	if (!*content) {
		wtof("MVSMF22E Memory allocation failed for content buffer");
		return -1;
	}
	buffer_size = INITIAL_BUFFER_SIZE;
	*content_size = 0;

	if (is_chunked) {
		while (!done) {
			char chunk_size_str[10];
			int i = 0;

			// Read chunk size line (hex + CRLF)
			while (i < (int)sizeof(chunk_size_str) - 1) {
				if (receive_raw_data(session->httpc,
						chunk_size_str + i, 1) != 1) {
					free(*content);
					*content = NULL;
					return -1;
				}
				if (chunk_size_str[i] == '\r') {
					chunk_size_str[i] = '\0';
					receive_raw_data(session->httpc,
						chunk_size_str + i, 1);
					break;
				}
				i++;
			}

			http_atoe((unsigned char *)chunk_size_str, i);
			{
				int chunk_size = (int)strtoul(chunk_size_str, NULL, 16);
				int bytes_read = 0;

				if (chunk_size == 0) {
					done = 1;
					break;
				}

				// Ensure buffer capacity
				if (*content_size + chunk_size > buffer_size) {
					char *new_buf = realloc(*content,
						*content_size + chunk_size + 1);
					if (!new_buf) {
						wtof("MVSMF22E Memory reallocation failed");
						free(*content);
						*content = NULL;
						return -1;
					}
					*content = new_buf;
					buffer_size = *content_size + chunk_size;
				}

				// Read chunk data
				while (bytes_read < chunk_size) {
					bytes_received = receive_raw_data(session->httpc,
						*content + *content_size + bytes_read,
						chunk_size - bytes_read);
					if (bytes_received <= 0) {
						free(*content);
						*content = NULL;
						return -1;
					}
					bytes_read += bytes_received;
				}

				*content_size += chunk_size;
			}

			// Consume trailing CRLF after chunk data
			{
				char crlf[2];
				if (receive_raw_data(session->httpc, crlf, 2) != 2) {
					free(*content);
					*content = NULL;
					return -1;
				}
			}
		}
	} else {
		char recv_buffer[1024];
		while (*content_size < content_length) {
			size_t remaining = content_length - *content_size;
			size_t to_read = remaining < sizeof(recv_buffer)
				? remaining : sizeof(recv_buffer);

			if (*content_size + sizeof(recv_buffer) > buffer_size) {
				char *new_buf = realloc(*content, buffer_size * 2);
				if (!new_buf) {
					wtof("MVSMF22E Memory reallocation failed");
					free(*content);
					*content = NULL;
					return -1;
				}
				*content = new_buf;
				buffer_size *= 2;
			}

			bytes_received = receive_raw_data(session->httpc,
				*content + *content_size, (int)to_read);
			if (bytes_received <= 0) {
				free(*content);
				*content = NULL;
				return -1;
			}

			*content_size += bytes_received;
		}
	}

	// Ensure null termination
	if (*content_size + 1 > buffer_size) {
		char *new_buf = realloc(*content, *content_size + 1);
		if (!new_buf) {
			wtof("MVSMF22E Memory reallocation failed");
			free(*content);
			*content = NULL;
			return -1;
		}
		*content = new_buf;
	}
	(*content)[*content_size] = '\0';

	return 0;
}

//
// private functions
//

/**
 * Extracts a parameter from environment variables
 *
 * @param session Current session context
 * @param prefix Prefix for the environment variable name (e.g. "HTTP_" or "QUERY_")
 * @param name Name of the parameter
 * @return Value of the parameter or NULL if not found
 */
__asm__("\n&FUNC    SETC 'get_env_param'");
static char *
get_env_param(Session *session, const char *prefix, const char *name)
{
	char env_name[ENV_NAME_SIZE];

	if (!session || !prefix || !name) {
		return NULL;
	}

	(void)snprintf(env_name, sizeof(env_name), "%s%s", prefix, name);
	return (char *)http_get_env(session->httpc, (const UCHAR *)env_name);
}

/**
 * Sends data to the client
 *
 * @param session Current session context
 * @param buf Buffer containing the data to send
 * @return 0 on success, negative value on error
 */
__asm__("\n&FUNC	SETC 'send_data'");
static int 
send_data(Session *session, char *buf) 
{
	int rc = 0;
	size_t len = strlen(buf);
	size_t pos = 0;

	http_etoa((unsigned char *)buf, len);

	for (pos = 0; pos < len; pos += rc) {
		rc = http_send(session->httpc, &buf[pos], len - pos);
		if (rc < 0) {
			goto quit; /* socket error */
		}
	}

	rc = 0; /* success */

quit:
	return rc;
}
