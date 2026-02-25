#ifndef TESTAPI_H
#define TESTAPI_H

#include "router.h"

/* Internal test endpoint for exercising crent370 functions.
** GET /zosmf/test?fn=listds&level=X&filter=Y
** GET /zosmf/test?fn=locate&dsn=X
*/
int testHandler(Session *session) asm("TAPI0000");

#endif
