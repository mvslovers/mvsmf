#ifndef JOBSAPI_H
#define JOBSAPI_H

#include "httpr.h"

#define JOBS_API 		("/zosmf/restjobs/")
int jobListHandler		(HTTPR *httpr)	asm("JAPI0000");
int jobFilesHandler  	(HTTPR *httpr)	asm("JAPI0001");
int jobRecordsHandler	(HTTPR *httpr)	asm("JAPI0002");
int jobSubmitHandler  	(HTTPR *httpr)	asm("JAPI0003");
int jobStatusHandler  	(HTTPR *httpr)	asm("JAPI0004");

#endif /* JOBSAPI_H */
