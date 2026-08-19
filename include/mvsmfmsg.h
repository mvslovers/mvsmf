#ifndef MVSMFMSG_H
#define MVSMFMSG_H

/**
 * @file mvsmfmsg.h
 * @brief Operator message catalog (WTO)
 *
 * Every wtof() literal in mvsMF lives here, exactly once. Adding a message
 * means adding a line to this file, which is what makes an id collision or a
 * duplicated text visible -- inline literals hid both.
 *
 * Rules, in order of how often they are broken:
 *
 * 1. A WTO is written only for what an operator can act on or must know.
 *    Anything the client caused (a missing parameter, an unknown route, a
 *    data set that is not there) is reported in the HTTP response and
 *    nowhere else. The console line would help nobody, and consapi.c reads
 *    the Master Trace Table -- so every line written here comes back out of
 *    /zosmf/restconsoles/... and the hardcopy log.
 *
 * 2. One text per id. If two call sites need different wording they need
 *    different ids; if they say the same thing with a varying detail, the
 *    detail becomes an argument (see MSG_STORAGE_FAILED).
 *
 * 3. Literals are uppercase -- 3270 console convention. Substituted values
 *    are passed through unchanged: most are MVS names and already uppercase,
 *    but USS paths and free user text must not be folded.
 *
 * 4. Severity is I, W or E. No D, no T.
 *
 * Id ranges:
 *
 *   MVSMF0xx   router, CGI entry, shared request handling
 *   MVSMF1xx   data sets      (restfiles/ds)
 *   MVSMF2xx   jobs           (restjobs)
 *   MVSMF3xx   USS            (restfiles/fs)   -- none yet
 *   MVSMF4xx   consoles       (restconsoles)   -- none yet
 *   MVSMF9xx   abend recovery and diagnostics
 *
 * The catalog is documented for operators in docs/messages.md; keep the two
 * in step.
 */

/*
 * MVSMF0xx -- router, CGI entry, shared request handling
 */

/** MVSMF001E route table is full; routes after this one are not registered */
#define MSG_ROUTES_FULL		"MVSMF001E ROUTE TABLE FULL, LIMIT %d REACHED"

/** MVSMF002E add_route() called without a pattern or without a handler */
#define MSG_ROUTE_INVALID	"MVSMF002E INVALID ROUTE DEFINITION, PATTERN OR HANDLER MISSING"

/** MVSMF003E middleware table is full; later middlewares do not run */
#define MSG_MIDDLEWARES_FULL	"MVSMF003E MIDDLEWARE TABLE FULL, LIMIT %d REACHED"

/** MVSMF004E handle_request() reached with a null router or session */
#define MSG_ROUTER_NULL		"MVSMF004E ROUTER OR SESSION POINTER IS NULL"

/** MVSMF005E started outside httpd (TSO, batch); %s is the program name */
#define MSG_NOT_UNDER_HTTPD	"MVSMF005E %s MUST BE CALLED BY THE HTTPD SERVER"

/** MVSMF006E GETMAIN/malloc failed; %s names what was being allocated */
#define MSG_STORAGE_FAILED	"MVSMF006E STORAGE ALLOCATION FAILED FOR %s"

/** MVSMF007W the client stopped sending mid-body and the read gave up */
#define MSG_RECV_TIMEOUT	"MVSMF007W RECEIVE TIMED OUT AFTER %d RETRIES"

/** MVSMF008W the client stopped reading mid-response and the send gave up */
#define MSG_SEND_TIMEOUT	"MVSMF008W SEND TIMED OUT AFTER %d RETRIES"

/*
 * MVSMF1xx -- data sets (restfiles/ds)
 */

/** MVSMF101E fopen() for write failed; not a client error (enqueue, space, RACF) */
#define MSG_DS_OPEN_WRITE	"MVSMF101E OPEN FOR WRITE FAILED %s ERRNO=%d"

/* MVSMF102E retired in #317. It fired on every failed create, and both
 * reachable causes are the client's: a name they may not allocate under, or
 * space/DCB parameters that do not fit. Client-caused conditions are reported
 * in the HTTP response and nowhere else -- see the rules at the top of this
 * file. Nothing is lost on the security side: RAKF logs its own denial.
 * The id is burned, not reusable, so that an operator searching old logs for
 * MVSMF102E does not find a different message wearing it. */

/** MVSMF103E scratch/uncatalog failed; %s is the data set or DSN(MEMBER) */
#define MSG_DS_DELETE_FAILED	"MVSMF103E DELETE FAILED %s RC=%d ERRNO=%d"

/** MVSMF104E data set rename failed after the target was found free */
#define MSG_DS_RENAME_FAILED	"MVSMF104E RENAME %s TO %s FAILED RC=%d"

/** MVSMF105E member rename failed after the target was found free */
#define MSG_MBR_RENAME_FAILED	"MVSMF105E RENAME %s(%s) TO (%s) FAILED RC=%d"

/*
 * MVSMF2xx -- jobs (restjobs)
 */

/** MVSMF201E JES2 is down, or its data sets cannot be opened */
#define MSG_JES_UNAVAILABLE	"MVSMF201E UNABLE TO OPEN THE JES2 CHECKPOINT AND SPOOL DATA SETS"

/** MVSMF202W spool output was already committed to the client when it broke */
#define MSG_SPOOL_WALK		"MVSMF202W SPOOL READ %-8.8s(%-8.8s) DSID %u: %s"

/** MVSMF203I a job entered the system through mvsMF */
#define MSG_JOB_SUBMITTED	"MVSMF203I JOB %s(%s) SUBMITTED"

/** MVSMF204E the JES2 internal reader could not be opened */
#define MSG_INTRDR_OPEN		"MVSMF204E UNABLE TO OPEN THE JES2 INTERNAL READER"

/** MVSMF205E a write to the internal reader failed; the job is incomplete */
#define MSG_INTRDR_WRITE	"MVSMF205E WRITE TO THE JES2 INTERNAL READER FAILED"

/** MVSMF206E the close failed, so the job may not have been queued */
#define MSG_INTRDR_CLOSE	"MVSMF206E CLOSE OF THE JES2 INTERNAL READER FAILED"

/** MVSMF207E JESCANJ returned a code this build does not know */
#define MSG_JESCANJ_RC		"MVSMF207E JESCANJ RETURNED RC=%d"

/*
 * MVSMF9xx -- abend recovery and diagnostics
 */

/** MVSMF901E a handler abended and the router's ESTAE caught it */
#define MSG_HANDLER_ABEND	"MVSMF901E HANDLER ABEND S%03X U%04d FOR %s %s"

/** MVSMF902W the abend came too late to turn into an error response */
#define MSG_HEADERS_SENT	"MVSMF902W HEADERS ALREADY SENT, NO ERROR RESPONSE POSSIBLE"

/** MVSMF903W the session file table is full; this file is not closed on abend */
#define MSG_FILES_FULL		"MVSMF903W SESSION FILE TABLE FULL, FILE NOT TRACKED"

/** MVSMF904I recovery is closing a data set the abending handler left open */
#define MSG_RECOVERY_CLOSE	"MVSMF904I RECOVERY CLOSING %s (DD:%s)"

/** MVSMF905W the recovery fclose() abended in turn; storage stays held */
#define MSG_RECOVERY_ABEND	"MVSMF905W RECOVERY FCLOSE ABENDED FOR SLOT %d"

/** MVSMF906W /zosmf/test?fn=abend is about to abend the worker on purpose */
#define MSG_ABEND_TEST		"MVSMF906W FORCING S0C1 TO EXERCISE THE ESTAE RECOVERY"

/** MVSMF907I CGI environment dump; only written when logmw is registered */
#define MSG_ENV_DUMP		"MVSMF907I ENV[%u] \"%s\"=\"%s\""

/** MVSMF908I recovery is closing the JES spool handle a handler left open */
#define MSG_RECOVERY_JES	"MVSMF908I RECOVERY CLOSING THE JES SPOOL HANDLE"

/** MVSMF909W the recovery jesclose() abended in turn; the spool stays open */
#define MSG_RECOVERY_JES_ABEND	"MVSMF909W RECOVERY JESCLOSE ABENDED, SPOOL DATA SETS STAY OPEN"

/** MVSMF910W a second JES handle was opened while one was still held */
#define MSG_JES_TRACKED		"MVSMF910W SESSION ALREADY HOLDS A JES HANDLE, THIS ONE NOT TRACKED"

/*
 * Arguments for MSG_STORAGE_FAILED -- uppercase, since they are substituted
 * into an uppercase literal.
 */
#define ALLOC_REQUEST_BODY	"THE REQUEST BODY"
#define ALLOC_JCL_TEXT		"THE JCL TEXT"
#define ALLOC_JCL_LINES		"THE JCL LINE TABLE"

#endif /* MVSMFMSG_H */
