#include "authmw.h"
#include "clibb64.h"
#include "common.h"
#include "httpd.h"
#include "racf.h"
#include "router.h"
#include <ctype.h>

static int validate_user(Session *session, char *username, char *password);

int authentication_middleware(Session *session) 
{
    int rc = 0;
    const char *auth_header = (char *) http_get_env(session->httpc, (const UCHAR *) "HTTP_Authorization");
    const char *content_type = (char *) http_get_env(session->httpc, (const UCHAR *) "HTTP_Content-Type");
   
    if (!auth_header) {
		sendDefaultHeaders(session, HTTP_STATUS_UNAUTHORIZED, HTTP_CONTENT_TYPE_NONE, 0);
		return -1;
    }

    // Basic Auth Header parsen
    if (strncmp(auth_header, "Basic ", 6) != 0) {
        sendDefaultHeaders(session, HTTP_STATUS_UNAUTHORIZED, HTTP_CONTENT_TYPE_NONE, 0);
        return -1;
    }

    UCHAR  encoded[256] = {0};
    UCHAR *decoded;
    size_t decoded_len;
    
    strncpy((char *) encoded, auth_header + 6, sizeof(encoded) - 1);
    decoded = base64_decode( (const UCHAR *) encoded, strlen((char *) encoded), &decoded_len);
    http_atoe((UCHAR *) decoded, decoded_len);

    if (decoded == NULL) {
        sendDefaultHeaders(session, HTTP_STATUS_UNAUTHORIZED, HTTP_CONTENT_TYPE_NONE, 0);
        return -1;
    }

    // extract username and password
    char *colon = strchr((char *) decoded, ':');
    if (!colon) {
        sendDefaultHeaders(session, HTTP_STATUS_UNAUTHORIZED, HTTP_CONTENT_TYPE_NONE, 0);
        free(decoded);
        return -1;
    }

    *colon = '\0';
    char  *username = decoded;
    char  *password = colon + 1;

    if (!validate_user(session, username, password)) {
        sendDefaultHeaders(session, HTTP_STATUS_UNAUTHORIZED, HTTP_CONTENT_TYPE_NONE, 0);
        free(decoded);
        return -1;
    }
    
    http_set_env(session->httpc, "HTTP_CURRENT_USER", strdup(username));

    free(decoded);

    return 0;
}

//
// static functions
// 

static 
int validate_user(Session *session, char *username, char *password) 
{
    int racf_rc = 0;

    ACEE *acee;

    if (!username || !password) {
        return 0;
    }

    
    int i = 0;
    for (i = 0; i < strlen(username); i++) {
        username[i] = toupper(username[i]);
    }

    for (i = 0; i < strlen(password); i++) {
        password[i] = toupper(password[i]);
    }

    acee = racf_login(username, password, NULL, &racf_rc);
    if (!acee) {
        return 0;
    }
    
    session->old_acee = racf_set_acee(acee);
    session->acee = acee;

    return 1; // Valeur par défaut pour le moment
}
