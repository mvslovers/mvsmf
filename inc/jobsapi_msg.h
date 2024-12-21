#ifndef JOBSAPI_MSG_H
#define JOBSAPI_MSG_H

// Job Purge Messages
#define MSG_JOB_PURGE_MISSING_PARAM    "MVSMF60E Missing required parameters: jobname=%s, jobid=%s"
#define MSG_JOB_PURGE_SELF             "MVSMF60W Attempt to purge ourself %s(%s)"
#define MSG_JOB_PURGE_JES_ERROR        "MVSMF61E Failed to open JES2"
#define MSG_JOB_PURGE_LIST_ERROR       "MVSMF62E Failed to get job list"
#define MSG_JOB_PURGE_STATUS           "MVSMF64I Job %s(%s) purge status: %s"
#define MSG_JOB_PURGE_NOT_FOUND        "MVSMF65E Job not found: %s(%s)"
#define MSG_JOB_PURGE_RESP_ERROR       "MVSMF66E Error sending response: rc=%d"

#endif // JOBSAPI_MSG_H 
