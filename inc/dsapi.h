#ifndef DSAPI_H
#define DSAPI_H

#include "httpr.h"

#define DATASET_API 	("/zosmf/restfiles/")
int datasetListHandler	(HTTPR *httpr)	asm("DAPI0001");
int datasetGetHandler	(HTTPR *httpr)	asm("DAPI0002");
int datasetPutHandler	(HTTPR *httpr)	asm("DAPI0003");
int memberListHandler	(HTTPR *httpr)	asm("DAPI0010");
int memberGetHandler	(HTTPR *httpr)	asm("DAPI0011");
int memberPutHandler	(HTTPR *httpr)	asm("DAPI0012");

#endif // DSAPI_H
