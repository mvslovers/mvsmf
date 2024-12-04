#ifndef AUTHMW_H
#define AUTHMW_H

#include "router.h"

int authentication_middleware(Session *session) asm("AUTHMW00");

#endif // AUTHMW_H
