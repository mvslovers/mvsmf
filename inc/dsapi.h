#ifndef DSAPI_H
#define DSAPI_H

#include "router.h"

int datasetListHandler	(Session *session)	asm("DAPI0001");
int datasetGetHandler	(Session *session)	asm("DAPI0002");
int datasetPutHandler	(Session *session)	asm("DAPI0003");
int memberListHandler	(Session *session)	asm("DAPI0010");
int memberGetHandler	(Session *session)	asm("DAPI0011");
int memberPutHandler	(Session *session)	asm("DAPI0012");

#endif // DSAPI_H
