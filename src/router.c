#include <stdio.h>
#include <string.h>

#include "router.h"
#include "httpd.h"


#define INITIAL_BUFFER_SIZE 4096

#define CR 0x0D
#define LF 0x0A

// internal functions declaration
static int route_matching_middleware(Session *session);
static int path_vars_extracting_middleware(Session *session);

static HttpMethod parseMethod(const char *method); 
static Route *find_route(Router *router, HttpMethod method, const char *path);
static int is_pattern_match(const char *pattern, const char *path);
static int extract_path_vars(Session *session, const char *pattern, const char *path);

static void uint_to_hex_ascii(size_t value, char *output) ;

static const unsigned char ASCII_CRLF[] = {CR, LF};

//
// public functions
//

void init_router(Router *router) 
{
    memset(router, 0, sizeof(Router));  

    add_middleware(router, "RouteMatching", route_matching_middleware);
    add_middleware(router, "PathVars", path_vars_extracting_middleware);
}

void init_session(Session *session, Router *router, HTTPD *httpd, HTTPC *httpc) 
{
    memset(session, 0, sizeof(Session));
    session->router = router;
    session->httpd = httpd;
    session->httpc = httpc;
}

void add_route(Router *router, HttpMethod method, const char *pattern, RouteHandler handler) 
{
    if (router->route_count >= MAX_ROUTES) {
        wtof("MAX_ROUTES limit reached.");
        return;
    }

    if (!pattern || !handler) {
        wtof("Invalid route parameters");
        return;
    }

    const char *pattern_copy = strdup(pattern);
    if (!pattern_copy) {
        wtof("Memory allocation failed for route pattern");
        return;
    }

    Route *route = &router->routes[router->route_count++];
    route->method = method;
    route->pattern = pattern_copy;
    route->handler = handler;

}

void add_middleware(Router *router, char *middleware_name, MiddlewareHandler handler)
{
    if (router->middleware_count >= MAX_MIDDLEWARES) {
        wtof("MAX_MIDDLEWARES limit reached.");
        return;
    }

    Middleware *middleware = &router->middlewares[router->middleware_count++];
    middleware->name = strdup(middleware_name);
    middleware->handler = handler;
}

int handle_request(Router *router, Session *session) 
{
    if (router == NULL || session == NULL) {
        wtof("Invalid Router or Session pointer");
        return -1;
    } 

    // needed for http_get_env
    HTTPD *httpd = session->httpd;
    HTTPC *httpc = session->httpc;

    char *method = (char *) http_get_env(httpc, (const UCHAR *) "REQUEST_METHOD");
    char *path = (char *) http_get_env(httpc, (const UCHAR *) "REQUEST_PATH");
    
    HttpMethod reqMethod = parseMethod(method);
    if (reqMethod == -1) {
        http_resp(httpc, 405);
        return -1;
    }

    // Execute all middlewares in sequence
    size_t i = 0;
    for (i = 0; i < router->middleware_count; i++) {
        int rc = router->middlewares[i].handler(session);
        if (rc != 0) {
            return rc;  // Middleware aborted the chain
        }
    }

    Route *route = find_route(router, reqMethod, path);
    
    if (route == NULL) {
        wtof("Unknown route requested. %s %s",   
            (char *) http_get_env(httpc, (const UCHAR *) "REQUEST_METHOD"),
            (char *) http_get_env(httpc, (const UCHAR *) "REQUEST_URI"));

        http_resp(httpc, 404);
        return -1;
    }

    extract_path_vars(session, route->pattern, path);
    
    // call the handler
    return route->handler(session);
}

//
// internal functions
//

int _send_response(Session *session, int status_code, const char *content_type, const char *data)
{
    char buffer[INITIAL_BUFFER_SIZE];
    int ret;

    // HTTP-Statuszeile erstellen
    sprintf(buffer, "HTTP/1.0 %d ", status_code);

    // Statusnachricht basierend auf dem Statuscode hinzufügen
    switch (status_code) {
        case 200:
            strcat(buffer, "OK\r\n");
            break;
		case 201:
			strcat(buffer, "Created\r\n");
			break;
		case 400:
			strcat(buffer, "Bad Request\r\n");
			break;
		case 403:
			strcat(buffer, "Forbidden\r\n");
			break;			
        case 404:
            strcat(buffer, "Not Found\r\n");
            break;
		case 415:
			strcat(buffer, "Unsupported Media Type\r\n");
			break;
		case 500:
			strcat(buffer, "Internal Server Error\r\n");
			break; 
		default:
            strcat(buffer, "Unknown\r\n");
            break;
    }

    sprintf(buffer + strlen(buffer),
            "Content-Type: %s\r\n"
            "Transfer-Encoding: chunked\r\n"
            "Connection: close\r\n\r\n",
            content_type);
    
    http_etoa((UCHAR *) buffer, strlen(buffer));
    ret = send(session->httpc->socket, buffer, strlen(buffer), 0);
    if (ret < 0) {
        wtof("Failed to send HTTP header: %s", strerror(errno));
        return -1;
    }

    const char *current = data;
    size_t remaining = strlen(data);

    while (remaining > 0) {
        // Chunk-Größe bestimmen (angepasst an Puffergröße)
        size_t chunk_size = remaining > INITIAL_BUFFER_SIZE ? INITIAL_BUFFER_SIZE : remaining;
   
   	 	/* Chunk-Größe als ASCII Hex */
    	char chunk_size_str[32 + 2];
    	uint_to_hex_ascii(chunk_size, chunk_size_str);

    	/* Sende Chunk-Größe */
    	ret = send(session->httpc->socket, chunk_size_str, strlen(chunk_size_str), 0);
        if (ret < 0) {
            wtof("Failed to send chunk size: %s", strerror(errno));
            return -1;
        }


        // Chunk-Daten in temporären Puffer kopieren
        char chunk_buffer[INITIAL_BUFFER_SIZE];
        memcpy(chunk_buffer, current, chunk_size);

        // Chunk-Daten kodieren
        http_etoa((UCHAR *) chunk_buffer, chunk_size);

        // Chunk-Daten senden
        ret = send(session->httpc->socket, chunk_buffer, chunk_size, 0);
        if (ret < 0) {
            perror("Failed to send chunk data");
            return -1;
        }

        ret = send(session->httpc->socket, ASCII_CRLF, 2, 0);
        if (ret < 0) {
            perror("Failed to send CRLF");
            return -1;
        }

        // Zum nächsten Chunk fortschreiten
        current += chunk_size;
        remaining -= chunk_size;
    }

    // Finalen leeren Chunk senden, um das Ende zu signalisieren
	size_t chunk_size = 0;
   
	char chunk_size_str[32 + 2];
	uint_to_hex_ascii(chunk_size, chunk_size_str);

    ret = send(session->httpc->socket, chunk_size_str, strlen(chunk_size_str), 0);
    if (ret < 0) {
        perror("Failed to send final chunk");
        return -1;
    }

    return 0;
}
 
int _recv(HTTPC *httpc, char *buf, int len)
{
    int total_bytes_received = 0;
    int bytes_received;
    int sockfd;

    sockfd = httpc->socket;
    while (total_bytes_received < len) {
        bytes_received = recv(sockfd, buf + total_bytes_received, len - total_bytes_received, 0);
		if (bytes_received < 0) {
            if (errno == EINTR) {
                // Interrupted by a signal, retry
                continue;
            } else {
                // An error occurred
                return -1;
            }
        } else if (bytes_received == 0) {
            // Connection closed by the client
            break;
        }
        total_bytes_received += bytes_received;
    }

    return total_bytes_received;
}

char* _get_host(HTTPD *httpd, HTTPC *httpc)
{
	// TODO: Implement this function
    return "http://drnbrx3a.neunetz.it:1080";
}

//
// static functions
//

static 
int route_matching_middleware(Session *sessionr) 
{
    wtof("MVSMF42D TODO: MATCHING ROUTES");

    // Hier kommt die eigentliche RouteMatching-Logik

    return 0;
}

static 
int path_vars_extracting_middleware(Session *session) 
{
    wtof("MVSMF42D TODO: EXTRACTING PATH VARS");

    // Hier kommt die eigentliche PathVars-Logik

    return 0;
}

static 
HttpMethod parseMethod(const char *method) 
{
    if (strcmp(method, "GET") == 0) return GET;
    if (strcmp(method, "POST") == 0) return POST;
    if (strcmp(method, "PUT") == 0) return PUT;
    if (strcmp(method, "DELETE") == 0) return DELETE;
    
    return (HttpMethod) -1; 
}

static 
Route *find_route(Router *router, HttpMethod method, const char *path)
{
    int i = 0;
    for (i = 0; i < router->route_count; i++) {
        if (router->routes[i].method == method && 
            is_pattern_match(router->routes[i].pattern, path)) {
            return &router->routes[i];
        }
    }
    return NULL;
}

static 
int is_pattern_match(const char *pattern, const char *path) 
{
    while (*pattern && *path) {
        if (*pattern == '{') {
            while (*pattern && *pattern != '}') pattern++;
            if (*pattern == '}') pattern++;

            while (*path && *path != '/' && *path != '(' && *path != ')') path++;
        } else {
            if (*pattern == *path) {
                pattern++;
                path++;
            } else {
                return 0;
            }
        }
    }

    return *pattern == '\0' && *path == '\0';
}

static 
int extract_path_vars(Session *session, const char *pattern, const char *path) 
{
    if (session == NULL || pattern == NULL || path == NULL) {
        return -1;
    }

    HTTPD *httpd = session->httpd;
    HTTPC *httpc = session->httpc;

    while (*pattern) {
        if (*pattern == '{') {
            pattern++;
            const char *var_start = pattern;
            while (*pattern && *pattern != '}') pattern++;
            int var_name_len = pattern - var_start;
            char var_name[256];
            strncpy(var_name, var_start, var_name_len);
            var_name[var_name_len] = '\0';
            if (*pattern == '}') pattern++;

            const char *pattern_next = pattern;
            while (*pattern_next && *pattern_next != '/' && *pattern_next != '(' && *pattern_next != ')') pattern_next++;

            const char *value_start = path;
            while (*path && *path != *pattern_next) path++;
            int value_len = path - value_start;
            char value[1024];
            strncpy(value, value_start, value_len);
            value[value_len] = '\0';

            char env_name[256];
            sprintf(env_name, "HTTP_%s", var_name);
            http_set_env(httpc, (UCHAR *) env_name, (UCHAR *) strdup(value));
            
            //insert(vars, strdup(var_name), strdup(value));

        } else {
            if (*pattern == *path) {
                pattern++;
                path++;
            } else {
                return 0;
            }
        }
    }
}

static 
void uint_to_hex_ascii(size_t value, char *output) 
{
    int pos = 0;
    int i;
    char temp;
    
    /* Spezialfall für 0 */
    if (value == 0) {
        output[0] = 0x30; 
        output[1] = CR;  
        output[2] = LF;  
		output[3] = CR;
		output[4] = LF;
        output[5] = '\0';
        return;
    }
    
    /* Hex-Ziffern von rechts nach links aufbauen */
    while (value > 0) {
        int digit = value % 16;
        if (digit < 10) {
            output[pos++] = 0x30 + digit;    /* ASCII '0'-'9' (0x30-0x39) */
        } else {
            output[pos++] = 0x41 + digit - 10;  /* ASCII 'A'-'F' (0x41-0x46) */
        }
        value /= 16;
    }
    
    /* String umdrehen */
    for (i = 0; i < pos/2; i++) {
        temp = output[i];
        output[i] = output[pos-1-i];
        output[pos-1-i] = temp;
    }
    
    /* CRLF hinzufügen */
    output[pos++] = CR; 
    output[pos++] = LF; 
    output[pos] = '\0';
}
