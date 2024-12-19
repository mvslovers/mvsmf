#ifndef JOBSAPI_H
#define JOBSAPI_H

#include "router.h"

int jobListHandler		(Session *session)	asm("JAPI0001");
int jobFilesHandler		(Session *session)	asm("JAPI0002");
int jobRecordsHandler	(Session *session)	asm("JAPI0003");
int jobSubmitHandler	(Session *session)	asm("JAPI0004");
int jobStatusHandler	(Session *session)	asm("JAPI0005");
int jobPurgeHandler     (Session *session)	asm("JAPI0006");
int jobCancelHandler    (Session *session)	asm("JAPI0007");

#endif // JOBSAPI_H
