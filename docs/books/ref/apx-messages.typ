#import "../bookmaster/bookmaster.typ": *

= Messages <apx-messages>

#idx("messages")
#idx("operator messages")
#idx("WTO")
This appendix lists every message that mvsMF writes to the operator console.
The messages are fixed texts. The source file #cmd("include/mvsmfmsg.h") holds
every text exactly once.

== What Is on the Console <ref-msg-rules>

mvsMF writes a message for what an operator can act on or must know. A
condition that the client caused is reported in the HTTP response and nowhere
else. A missing parameter, an unknown route, a data set that does not exist, a
malformed job card and a #cmd("Host") header that cannot be read produce no
console message.

There is a second reason. The console routes read the Master Trace Table
(@ref-cons), so every message that mvsMF writes can come back through the
solicited-message and hardcopy-log requests. A client that polls a request that
fails would turn one message into a flood on its own console API.

== Format <ref-msg-format>

#idx("message", "format")
A message has the form

#screen(raw("MVSMFnnns text"))

#cmd("MVSMF") is the prefix. #cmd("nnn") is a three-digit number and
#cmd("s") the severity letter. The text is upper case. A value that mvsMF
substitutes keeps its case: data set names are upper case already, a path of a
UNIX file or the free text of an error is not changed.

#tab(caption: [Severity letters])[
  #table(columns: (0.55in, 1fr),
    [Letter], [Meaning],
    [#cmd("I")], [Information. No action.],
    [#cmd("W")], [Warning. The request or the recovery went on, but something
      was lost or could not be tracked.],
    [#cmd("E")], [Error. A request failed or a function is not available. An
      operator or an administrator must act.],
  )
]

There is no debug level and no other letter. The numbers are grouped by area:

#tab(caption: [Message ranges])[
  #table(columns: (0.9in, 1fr),
    [Range], [Area],
    [#cmd("MVSMF0xx")], [Router, entry point and shared request handling
      (@ref-msg-core).],
    [#cmd("MVSMF1xx")], [Data sets (@ref-msg-ds).],
    [#cmd("MVSMF2xx")], [Jobs (@ref-msg-jobs).],
    [#cmd("MVSMF3xx")], [UNIX files. There is no message yet.],
    [#cmd("MVSMF4xx")], [Console services. There is no message yet.],
    [#cmd("MVSMF9xx")], [Abend recovery and diagnostics (@ref-msg-recovery).],
  )
]

A number is used once. An id that was retired is not given to a new message
(@ref-msg-ds). In the texts below, #cmd("%d") and similar marks stand for the
value that mvsMF inserts. The texts of the HTTP error reports are not part of
this appendix. They are in the chapters of the routes (@ref-ds, @ref-uss,
@ref-jobs, @ref-cons).

== Router and Core: MVSMF0xx <ref-msg-core>

#idx("messages", "MVSMF0xx")

#tab(caption: [Messages MVSMF001E to MVSMF008W])[
  #table(columns: (0.9in, 1.6in, 1fr),
    [Id], [Text], [Meaning and action],
    [#cmd("MVSMF001E")], [#cmd("ROUTE TABLE FULL, LIMIT %d REACHED")],
      [mvsMF tried to register more routes than the table holds (100). The
       routes after the limit do not exist and a request for one gets the 404
       of @ref-conv-fixed. This is a fault of the build. Report it.],
    [#cmd("MVSMF002E")], [#cmd("INVALID ROUTE DEFINITION, PATTERN OR HANDLER MISSING")],
      [A route was registered without a pattern or without a handler. mvsMF
       skips the route. This is a fault of the build. Report it.],
    [#cmd("MVSMF003E")], [#cmd("MIDDLEWARE TABLE FULL, LIMIT %d REACHED")],
      [mvsMF tried to register more middleware than the table holds (10).
       Middleware after the limit does not run. The middleware that sets the
       identity of the user is one of them. This is a fault of the build.
       Report it.],
    [#cmd("MVSMF004E")], [#cmd("ROUTER OR SESSION POINTER IS NULL")],
      [The request handling was entered without a router or without a session.
       The request is not processed. This is an internal fault. Report it.],
    [#cmd("MVSMF005E")], [#cmd("%s MUST BE CALLED BY THE HTTPD SERVER")],
      [The module was started as a program, from TSO or in a batch job, and not
       by HTTPD as a CGI module. The module also prints a sentence of its own to
       standard output ("This program %s must be called by the HTTPD web
       server"), for a caller that does not see the console, and ends with
       return code 12. #cmd("%s") is the name that the program was called
       by. Run the module only under HTTPD.],
    [#cmd("MVSMF006E")], [#cmd("STORAGE ALLOCATION FAILED FOR %s")],
      [A storage request failed. #cmd("%s") names what mvsMF wanted to
       allocate: #cmd("THE REQUEST BODY"), #cmd("THE JCL LINE TABLE"),
       #cmd("A SPOOL BLOCK") (the diagnostic endpoint), #cmd("THE MEMBER LIST")
       or #cmd("THE DATA SET LIST"). The request fails. For the list of data
       sets the answer is status 500, not an empty list. The address space is
       short of storage. Check the region of HTTPD and look for a leak. The
       function #cmd("storage") of the diagnostic endpoint shows the free
       storage of a development build (@ref-test-storage).],
    [#cmd("MVSMF007W")], [#cmd("RECEIVE TIMED OUT AFTER %d RETRIES")],
      [A client stopped sending in the middle of a request body, and the read
       gave up after the waiting time (10 seconds, in steps of 50 ms). The
       number in the message is the count of retries that the shipped build
       reaches, 201. The worker was tied up for the whole wait. A single
       message is a problem of the client or the network. A steady stream
       means that clients consume the workers of HTTPD.],
    [#cmd("MVSMF008W")], [#cmd("SEND TIMED OUT AFTER %d RETRIES")],
      [A client stopped reading in the middle of a response. The send buffer of
       the socket stayed full for the whole waiting time (100 steps of
       100 ms, 10 seconds), and mvsMF gave up the response. The number in the
       message is 101 in the shipped build. The connection is dropped and the
       worker is free again. A server that is being stopped does not cause this
       message.],
  )
]

== Data Sets: MVSMF1xx <ref-msg-ds>

#idx("messages", "MVSMF1xx")
These messages report failures of the server that carry a return code or an
#cmd("errno") which the HTTP error report does not show. A mistake of the
client, such as a missing name, a data set or a member that does not exist, or a
record that is too long, produces no console message.

#tab(caption: [Messages MVSMF101E to MVSMF107E])[
  #table(columns: (0.9in, 1.6in, 1fr),
    [Id], [Text], [Meaning and action],
    [#cmd("MVSMF101E")], [#cmd("OPEN FOR WRITE FAILED %s ERRNO=%d")],
      [The open for writing of an existing data set failed. #cmd("%s") is the
       data set or the member that was the target. This is not a mistake of the
       client. Typical causes: another job holds the data set, there is no
       space, or the security product refused the open. Look at the cause
       given by #cmd("ERRNO").],
    [#cmd("MVSMF102E")], [(retired)],
      [Not used. The message was written for every failed create of a data set.
       Both reachable causes are mistakes of the client (a name the user may
       not allocate, or space and attribute values that do not fit), so the
       failure is reported in the HTTP response only. A refusal by the security
       product is logged by that product. The number is retired and is not
       given to another message, so that a search of an old log for it never
       finds a different text.],
    [#cmd("MVSMF103E")], [#cmd("DELETE FAILED %s RC=%d ERRNO=%d")],
      [The scratch or the uncatalog failed after mvsMF had found the data set.
       #cmd("%s") is the data set, or #cmd("DSN(MEMBER)") for the delete of a
       member. Look at the return code and #cmd("ERRNO").],
    [#cmd("MVSMF104E")], [#cmd("RENAME %s TO %s FAILED RC=%d")],
      [The rename of a data set failed after mvsMF had found that the new name
       is free. The names are the old and the new data set name.],
    [#cmd("MVSMF105E")], [#cmd("RENAME %s(%s) TO (%s) FAILED RC=%d")],
      [The rename of a member failed after mvsMF had found that the new name is
       free. The text shows the data set, the old member name and the new
       member name.],
    [#cmd("MVSMF106E")], [#cmd("I/O ERROR READING %s ERRNO=%d")],
      [A read had an uncorrectable I/O error, such as a bad track or a device
       error. #cmd("%s") is the data set. The
       message is also issued when the read of the JCL data set of a job
       submission fails. The status is already on the wire when the error
       happens, so the client sees a broken transfer, and this message is the
       place where the cause is recorded. Check the volume and the data set.],
    [#cmd("MVSMF107E")], [#cmd("OUT OF SPACE WRITING %s - RECORDS LOST")],
      [The data set was full while a write replaced its content, and records
       were lost. #cmd("%s") is the data set or the member. The client gets
       status 500. The data set is left short: the previous content is already
       gone, because the write does not keep a copy. The message is also
       issued when only the last, partial block cannot be written when the data
       set is closed. Add space. Then have the client send the upload again.],
  )
]

== Jobs: MVSMF2xx <ref-msg-jobs>

#idx("messages", "MVSMF2xx")

#tab(caption: [Messages MVSMF201E to MVSMF207E])[
  #table(columns: (0.9in, 1.6in, 1fr),
    [Id], [Text], [Meaning and action],
    [#cmd("MVSMF201E")], [#cmd("UNABLE TO OPEN THE JES2 CHECKPOINT AND SPOOL DATA SETS")],
      [mvsMF could not open the JES2 checkpoint and spool data sets. Either JES2
       is down or the data sets cannot be opened from the address space of
       HTTPD. The job routes that read the job queue or the spool fail while
       this lasts. Check JES2.],
    [#cmd("MVSMF202W")], [#cmd("SPOOL READ %-8.8s(%-8.8s) DSID %u: %s")],
      [A read of spool output ended early after output had gone to the
       client, so the response was already committed with status 200. The
       fields are the job name, the job ID, the data set ID and a reason in
       mixed case. The reasons are #cmd("JES2 checkpoint or spool data set not available"),
       #cmd("spool read failed"), #cmd("no longer on the spool"),
       #cmd("first spool block belongs to another data set"),
       #cmd("spool block chain loops, output truncated"),
       #cmd("spool block limit reached, output truncated"),
       #cmd("incomplete spanned record, output truncated") and
       #cmd("out of storage, output truncated"). The records that were sent are
       valid. The rest is missing.],
    [#cmd("MVSMF203I")], [#cmd("JOB %s(%s) SUBMITTED")],
      [A job entered the system through mvsMF. The fields are the job name and
       the job ID. This is the audit trail for work that was submitted over
       the web.],
    [#cmd("MVSMF204E")], [#cmd("UNABLE TO OPEN THE JES2 INTERNAL READER")],
      [The internal reader could not be opened. No job can be submitted until
       this clears. Check JES2.],
    [#cmd("MVSMF205E")], [#cmd("WRITE TO THE JES2 INTERNAL READER FAILED")],
      [A write to the internal reader failed. The job is incomplete and is not
       queued.],
    [#cmd("MVSMF206E")], [#cmd("CLOSE OF THE JES2 INTERNAL READER FAILED")],
      [The close of the internal reader failed. The job may or may not have
       been queued. Look at the JES2 queue before you submit it again.],
    [#cmd("MVSMF207E")], [#cmd("JESCANJ RETURNED RC=%d")],
      [The purge of a job returned a code that this build does not know. The
       client gets status 500. Report the code.],
  )
]

== Recovery and Diagnostics: MVSMF9xx <ref-msg-recovery>

#idx("messages", "MVSMF9xx")
#idx("recovery")
mvsMF runs every handler under a recovery routine. If a handler abends, the
routine writes MVSMF901E, closes the resources that the handler left open
and releases the locks that it held (MVSMF904I, MVSMF908I, MVSMF911I,
MVSMF915I), and answers the client with status 500 if it still can. A message
of this range that ends with #cmd("W") means that a step of the recovery did not
work.

#tab(caption: [Messages MVSMF901E to MVSMF916W])[
  #table(columns: (0.9in, 1.6in, 1fr),
    [Id], [Text], [Meaning and action],
    [#cmd("MVSMF901E")], [#cmd("HANDLER ABEND S%03X U%04d FOR %s %s")],
      [A handler abended and the recovery routine caught it. The fields are the
       system completion code, the user completion code, the method and the
       path of the request, so the message says which request did it. The
       client gets status 500 with the abend code (@ref-conv-fixed). The
       exception is S913, a refusal by the security product to open a data set.
       It is answered with the authorization report, and MVSMF901E is still
       written. Any other abend points to a fault. Report it with the lines
       MVSMF913I and MVSMF914I and the build (@ref-test-version). The build of a
       release is its version.],
    [#cmd("MVSMF902W")], [#cmd("HEADERS ALREADY SENT, NO ERROR RESPONSE POSSIBLE")],
      [The abend came after the response had begun. The client sees a body that
       ends too soon and not an error report. It always follows MVSMF901E.],
    [#cmd("MVSMF903W")], [#cmd("SESSION FILE TABLE FULL, FILE NOT TRACKED")],
      [One request has more data sets open than the table holds (4). The file
       that does not fit is not recorded, so the recovery does not close it if
       the handler abends.],
    [#cmd("MVSMF904I")], [#cmd("RECOVERY CLOSING %s (DD:%s)")],
      [The recovery closes a data set that the abended handler left open. The
       fields are the data set and the DD name. It goes with MVSMF901E. No
       action.],
    [#cmd("MVSMF905W")], [#cmd("RECOVERY FCLOSE ABENDED FOR SLOT %d")],
      [The close in the recovery abended too. The data set stays allocated, and
       its storage stays held for the life of the address space. Restart HTTPD
       when the storage is needed.],
    [#cmd("MVSMF906W")], [#cmd("FORCING S0C1 TO EXERCISE THE ESTAE RECOVERY")],
      [The functions #cmd("abend") and #cmd("jesabend") of the diagnostic
       endpoint (@ref-test) cause an abend on purpose. This is not a fault. The
       message does not occur in a release or in a build without the endpoint
       (@ref-test-build).],
    [#cmd("MVSMF907I")], [#cmd("ENV[%u] \"%s\"=\"%s\"")],
      [A dump of the CGI environment, one line for each variable. The message is
       written only if the logging middleware is registered. The shipped build
       does not register it. This is an aid for developers, not a message for
       operators.],
    [#cmd("MVSMF908I")], [#cmd("RECOVERY CLOSING THE JES SPOOL HANDLE")],
      [The recovery closes the JES2 spool handle that the abended handler left
       open. It goes with MVSMF901E. No action.],
    [#cmd("MVSMF909W")], [#cmd("RECOVERY JESCLOSE ABENDED, SPOOL DATA SETS STAY OPEN")],
      [The close of the JES2 handle in the recovery abended too. The JES2 spool
       data sets stay allocated and their storage stays held for the life of the
       address space.],
    [#cmd("MVSMF910W")], [#cmd("SESSION ALREADY HOLDS A JES HANDLE, THIS ONE NOT TRACKED")],
      [A request opened a second JES2 handle while it still held the first. The
       second handle is not recorded, so the recovery does not close it. No
       code path does this. If you see the message, a change of the code broke
       the rule that a request holds one handle. Report it.],
    [#cmd("MVSMF911I")], [#cmd("RECOVERY RELEASING THE CONSOLE CORRELATION LOCK")],
      [The abended handler held the lock that serializes the console commands,
       and the recovery releases it. It goes with MVSMF901E. No action. If it is
       missing after an abend in a console request, the later console commands
       wait their full time and then get status 429.],
    [#cmd("MVSMF912W")], [#cmd("RECOVERY DEQ ABENDED, CONSOLE COMMANDS WILL BE REFUSED")],
      [The release of the lock in the recovery abended. The lock stays held for
       the life of the address space. From now on the request that issues a
       command (@ref-cons) gets status 429. The other routes are not affected.
       Restart HTTPD.],
    [#cmd("MVSMF913I")], [#cmd("PSW %08X %08X ILC %u INTC %04X: INSTRUCTION AT EP%cX'%lX', R14 AT EP%cX'%lX'")],
      [It shows where the abend of the MVSMF901E before it happened. See
       @ref-msg-psw.],
    [#cmd("MVSMF914I")], [#cmd("STORAGE AT INSTRUCTION-8: %08X %08X *%08X %08X")],
      [It shows the 16 bytes around the failing instruction. See
       @ref-msg-psw.],
    [#cmd("MVSMF915I")], [#cmd("RECOVERY RELEASING THE DATA SET LIST LOCK")],
      [The abended handler held the lock that makes the data set lists take
       turns (@ref-ds-list-turns), and the recovery releases it. It goes with
       MVSMF901E. No action. An abend in a list after its catalog search does not
       write it, because the lock is released by then.],
    [#cmd("MVSMF916W")], [#cmd("RECOVERY DEQ ABENDED, DATA SET LISTS WILL WAIT")],
      [The release of the lock in the recovery abended. The lock stays held for
       the life of the address space. From now on every request that lists data
       sets (@ref-ds-list) waits for it, and mvsMF sets no limit to the wait.
       The other routes are not affected. Restart HTTPD.],
  )
]

=== MVSMF913I and MVSMF914I <ref-msg-psw>

#idx("MVSMF913I")
#idx("MVSMF914I")
#idx("abend", "locating")
The two messages help to find the place of an abend in the code of mvsMF. They
follow MVSMF901E.

*MVSMF913I.* The message is written only if a PSW is known. The two words after
#cmd("PSW") are the two halves of the PSW at the time of the error. #cmd("ILC")
is the instruction length code (0 to 3, in halfwords) and #cmd("INTC") the
interruption code. Examples are #cmd("0001") for an operation exception,
#cmd("0004") for a protection exception and #cmd("0007") for a data exception.

The failing instruction is at the address of the PSW minus twice the ILC,
except for the codes #cmd("0010") and #cmd("0011") (a segment or page
translation exception): there the PSW already points at the failing
instruction. #cmd("R14") is the return address of the last call that the failing
code made. The message does not give absolute addresses, because the load
address changes with every load of the module. It gives each address as a signed
offset from the entry point of the module, written #cmd("EP+X'...'") or
#cmd("EP-X'...'"). To find the code, add the offset to the entry point of the
deployed module and look up the result in the link map of the same build. The
build is the value of #cmd("fn=version") (@ref-test-version) on a development
build. A release has no such function: its build is the version in the field
#cmd("zosmf_full_version") of #cmd("/zosmf/info").

If the entry point plus the offset is negative or lies beyond the length of the
module, the abend was not in mvsMF. It was in HTTPD, reached through the vector
of HTTPD, or in a system routine. Do not look such an offset up in the link map
of mvsMF.

*MVSMF914I.* The message gives 16 bytes of storage: the 8 bytes before the
failing instruction, then, after the asterisk, 8 bytes that begin at the
instruction. Compare them with the same place in the module. If they differ,
the code was overwritten while it was loaded, and the bytes that do not belong
there show what overwrote it.

mvsMF writes MVSMF914I only together with MVSMF913I, and only if all 16 bytes
lie inside the running copy of mvsMF. Anywhere else the bytes could belong to a
buffer with the request or the credentials of another user, and a user who
may use the console routes can read the console, and with it this message. The message
is also not written if the read of the bytes fails.
