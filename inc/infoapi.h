#ifndef INFOAPI_H
#define INFOAPI_H

#include "httpr.h"

#define INFO_API    ("/zosmf/info")
int infoHandler		(HTTPR *httpr)	asm("IAPI0000");

#endif /* INFOAPI_H */
