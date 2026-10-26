#import "../bookmaster/bookmaster.typ": *

= Console Services <ref-cons>

#idx("console services")#idx("restconsoles")
This chapter describes the console services of mvsMF: the four requests under
#cmd("/zosmf/restconsoles"), the way mvsMF finds the answer to a command, the
keys that it hands out, and every error report. The _mvsMF User's Guide_,
chapter "Issuing Console Commands", shows the tasks with sessions.

The console services clone the console REST interface of IBM z/OSMF. mvsMF
implements the parts described here. Section @ref-cons-unsup lists what it does
not.

#note[*Every console request needs READ access to #cmd("FACILITY:MVSMF.CONSOLE").*
mvsMF asks RAKF itself, as the first statement of each of the four handlers
(@ref-cons-auth). The sample HTTPD configuration of mvsMF 1.4.0 puts the
console routes behind the same resource as a first layer (@ref-httpd,
@ref-auth). See "Protecting the Console Services" in the _mvsMF User's Guide_.]

== Requests <ref-cons-req>

#tab(caption: [Console requests])[
  #table(columns: (0.5in, 2.6in, 1fr),
    [Method], [Path], [Purpose],
    [#cmd("PUT")], [#cmd("/zosmf/restconsoles/consoles/{console-name}")],
      [Issue a command (@ref-cons-issue).],
    [#cmd("GET")],
      [#cmd("/zosmf/restconsoles/consoles/{console-name}/solmsgs/{cmd-response-key}")],
      [Collect more of an answer (@ref-cons-collect).],
    [#cmd("GET")],
      [#cmd("/zosmf/restconsoles/consoles/{console-name}/detections/{detection-key}")],
      [Read a detection (@ref-cons-detect).],
    [#cmd("GET")], [#cmd("/zosmf/restconsoles/v1/log")],
      [Read the log (@ref-cons-log).],
  )
]

Common rules:

- #cmd("{console-name}") is a path variable. Only the issue request reads it. It
  must have two to eight characters, and mvsMF checks nothing else about it
  (@ref-cons-issue). The collect and detection requests ignore it.
- Every request needs a user ID that the HTTPD configuration lets in
  (@ref-auth). The issue request needs no #cmd("X-CSRF-ZOSMF-HEADER").
- A path that matches no route gets the router's #cmd("404"), also when the
  method is a valid one that the path does not have. The router's #cmd("405")
  is for a method that is none of GET, POST, PUT and DELETE (@ref-conv).
- The console requests report errors in the form of @ref-cons-errors, not in the
  form of the data set and job requests.
- The answers are JSON. No console request changes a data set, a job or a file.

== Authorization <ref-cons-auth>

#idx("authorization", "console")#idx("MVSMF.CONSOLE")
The first statement of the handler of each of the four requests is the
permission check. It runs before the handler reads a header, a parameter or
the body, so no check of @ref-cons-order, and no key, cursor or detection, is
reached by a caller who fails it. The same check is the first statement of the
handlers of the diagnostic endpoint (@ref-test-access).

mvsMF asks RAKF for READ access to the resource #cmd("MVSMF.CONSOLE") in the
class #cmd("FACILITY"), under the identity that HTTPD resolved for the request.
It lets the request go on only when RAKF answers that the access is permitted.
These cases are refused:

- there is no profile for the resource;
- the profile does not give the caller READ;
- RAKF gives any other answer;
- the request has no resolved identity. The answer is then the 401 of
  @ref-auth.

"No profile" counts as "not permitted". This is the difference to the route
check of HTTPD, which lets everyone through while no profile covers the
resource (@ref-httpd). A system that has not defined the profile therefore
refuses the console services to every user, administrators included, until the
profile is defined and READ is granted.

A refusal has the shape of the authorization refusals of the data set
services, not the console error shape of @ref-cons-errors: HTTP 500, category 4,
rc 8, reason 0, the message #cmd("LMOPEN error"), and one detail,
#cmd("Authorization failed - You may not use this service."). mvsMF writes no
operator message for it.

The route lines of HTTPD are a first layer in front of this check. A caller
without READ access to the resource gets the plain-text 403 of HTTPD when
the console route matches, and the 500 of mvsMF when it does not (@ref-httpd).

== Issue a Command <ref-cons-issue>

#idx("command", "issue")#idx("SVC 34")#idx("MGCR")
#cmd("PUT /zosmf/restconsoles/consoles/{console-name}") issues one operator
command with SVC 34 (MGCR) in supervisor state, then reads the answer from the
Master Trace Table (@ref-cons-mtt).

The request needs the header #cmd("Content-Type") with the text
#cmd("application/json") somewhere in its value (parameters such as a character
set may follow). The check is case sensitive.

=== Body Fields <ref-cons-body>

mvsMF does not parse the body as JSON. For each field it looks for the field name
in double quotes, takes the text after the following colon, and reads a string in
double quotes. See @ref-cons-body-rules.

#tab(caption: [Body fields of the issue request])[
  #table(columns: (1.35in, 0.8in, 1fr),
    [Field], [Required], [Meaning],
    [#cmd("cmd")], [yes],
      [The command. Not empty; at most 126 characters. mvsMF changes it to upper
       case before it issues it. Only its first 100 characters are sent to MVS
       (@ref-cons-limits).],
    [#cmd("async")], [no],
      [The first character of the value is #cmd("Y") or #cmd("y"): the answer
       carries no #cmd("cmd-response"). Any other value, or no field: it does.],
    [#cmd("sol-key")], [no],
      [Text to look for in the lines of the answer. At most 63 characters
       (longer text is cut). Case sensitive.],
    [#cmd("solKeyReg")], [no],
      [Together with a #cmd("sol-key"), a value that begins with an upper-case
       #cmd("Y") is refused (reason code 25). The check looks at the first
       character of the first three only, so #cmd("Yes") is refused. Any other
       value, a lower-case #cmd("y") included, is ignored.],
    [#cmd("unsol-key")], [no],
      [Text to wait for in the table after the command. At most 63 characters
       (longer text is cut). Case is ignored. Without it, there is no detection.],
    [#cmd("unsolKeyReg")], [no],
      [Together with an #cmd("unsol-key"), a value that begins with an upper-case
       #cmd("Y") is refused (reason code 25), by the same rule as
       #cmd("solKeyReg"). Any other value is ignored.],
    [#cmd("unsol-detect-sync")], [no],
      [The first character of the value is #cmd("Y") or #cmd("y"): wait for the
       detection in this request (@ref-cons-detect-sync). Any other value: arm a
       detection for a later request (@ref-cons-detect-async).],
    [#cmd("unsol-detect-timeout")], [no],
      [Ticks of the clock (about 1.05 seconds each) to wait with
       #cmd("unsol-detect-sync"). Read with #cmd("atoi").
       Default 20. A value of 0, a negative value, or a value above 60 gives 20.],
    [#cmd("detect-time")], [no],
      [Ticks of the clock (about 1.05 seconds each) that an armed detection stays
       open. Default 30. A value of 0 or
       less gives 30. At most 7 characters are read.],
    [#cmd("system")], [no],
      [Any non-empty value is refused (reason code 5). Routing to another system
       is not supported.],
  )
]

Any other field of the body is ignored.

==== Reading the body <ref-cons-body-rules>

- A field is found by a search for its name in double quotes anywhere in the body.
  The first occurrence counts. A field name inside a string value of another
  field can be found as well.
- The value must be a string: after the colon and optional blanks the next
  character must be a double quote. A number, a boolean or an object is the same
  as a field that is missing.
- The string ends at the next double quote. Escapes are not decoded, so a
  backslash is part of the value and #cmd("\\\"") does not hold a quote.
- The body is converted from ASCII to EBCDIC as a whole before it is searched.
- The body may be as large as the request-body limit of mvsMF allows; a body over
  the limit gets #cmd("413") (@ref-cons-errors).

=== Order of Checks <ref-cons-order>

mvsMF checks in this order and answers the first failure:

+ the permission for #cmd("MVSMF.CONSOLE") (@ref-cons-auth);
+ the #cmd("Content-Type") (reason code 6);
+ the length of the console name (reason code 14);
+ the body: storage, size, presence (reason codes 1, 12);
+ #cmd("cmd") present and not empty (reason code 13);
+ the length of #cmd("cmd") (reason code 17);
+ #cmd("solKeyReg") (reason code 25), then #cmd("unsolKeyReg") (reason code 25);
+ #cmd("system") (reason code 5);
+ the console lock (reason codes 16 and 17, @ref-cons-lock).

Nothing is issued before the last check has passed.

=== What mvsMF Does <ref-cons-flow>

+ It changes the command to upper case, all of it.
+ It takes the console lock (@ref-cons-lock).
+ It issues the command.
+ With an #cmd("unsol-key"), it takes the anchor of the detection (@ref-cons-detect):
  the end of the table. When the copy of the table
  cannot be taken, there is no anchor, and the request ends with #cmd("500"),
  reason code 14 (the command was issued).
+ It builds the response key (@ref-cons-keys).
+ It reads the table until the answer has settled (@ref-cons-capture).
+ It releases the console lock.
+ It stores the cursor for the key (@ref-cons-store).
+ With #cmd("unsol-key"), it waits for the detection or stores a detection
  (@ref-cons-detect).
+ It sends the answer.

=== The Answer <ref-cons-answer>

The status is #cmd("200"). The body is a JSON object with these fields, in this
order:

#tab(caption: [Fields of the issue answer])[
  #table(columns: (1.5in, 1.2in, 1fr),
    [Field], [When], [Value],
    [#cmd("cmd-response")], [not #cmd("async")],
      [The lines of the answer, each followed by the character #cmd("\\r"). Empty
       when no line was found.],
    [#cmd("cmd-response-key")], [always],
      [The key of the answer: 16 hexadecimal characters (@ref-cons-keys).],
    [#cmd("cmd-response-url")], [always],
      [The scheme and the #cmd("Host") header of the request (#cmd("localhost")
       when it has none) followed by the URI.],
    [#cmd("cmd-response-uri")], [always],
      [#cmd("/zosmf/restconsoles/consoles/")#var("console-name")#cmd("/solmsgs/")#var("key").],
    [#cmd("sol-key-detected")], [not #cmd("async"), with #cmd("sol-key")],
      [#cmd("true") when the text is in #cmd("cmd-response"), otherwise
       #cmd("false"). The search is a plain, case-sensitive search over the lines
       that the answer carries.],
    [#cmd("status")], [#cmd("unsol-key") and sync],
      [#cmd("detected") or #cmd("timeout").],
    [#cmd("msg")], [#cmd("unsol-key") and sync],
      [The newest matching line when #cmd("detected"), otherwise empty.],
    [#cmd("detection-key")], [#cmd("unsol-key"), not sync],
      [The key of the detection: #cmd("D") and seven hexadecimal characters.],
    [#cmd("detection-url")], [#cmd("unsol-key"), not sync],
      [As #cmd("cmd-response-url"), for the detection URI.],
    [#cmd("detection-uri")], [#cmd("unsol-key"), not sync],
      [#cmd("/zosmf/restconsoles/consoles/")#var("console-name")#cmd("/detections/")#var("key").],
  )
]

The lines of #cmd("cmd-response") are the message texts without the time and the
originator. A continuation line of a multi-line message has its leading blanks
and the message number removed.

== The Capture <ref-cons-capture>

#idx("capture")#idx("convergence window")
SVC 34 returns no reply, so mvsMF reads the answer from the table
(@ref-cons-mtt). This section gives the rules of that reading.

=== The Convergence Window <ref-cons-window>

After it has issued the command, mvsMF repeats this cycle:

+ If the server is quiescing or shutting down, stop with reason code 15
  (@ref-cons-errors).
+ Read the table and find the answer block (@ref-cons-block). Let #var("n") be
  the number of lines of the block. A read that cannot take a copy of the table
  does not count: the block, #var("n") and the count of stable reads stay as the
  last good read left them.
+ If #var("n") is greater than 0 and equal to the #var("n") of the cycle before,
  count one stable read. Otherwise reset the count.
+ If the count is 3, stop.
+ If the time since the start is at least 3 ticks of the high word of the TOD
  clock (about 1.05 seconds each, so 2.1 to 3.1 seconds), stop.
+ Wait 0.1 second and begin again.

The answer is the block of the last good read. When no read of the whole wait
got a copy of the table, the call ends with #cmd("500"), return code 8 and
reason code 14: the command was issued, and the answer could not be read. With
a block that does not change, the
call lasts at least 0.3 seconds. With no block (#var("n") is 0 all the time), it
lasts until the time limit. The cycle cannot tell a finished answer from a pause
in the reply: a reply that stays the same for three reads ends the wait
(@ref-cons-limits).

The wait is the same with #cmd("async"). Then mvsMF drops the text: the cursor
starts at 0 lines, and the first collect returns the whole block.

=== The Answer Block <ref-cons-block>

mvsMF reads one copy of the table per cycle. It finds the answer in it like this:

+ *The echo.* An entry is the echo of the command when its message text equals
  the command, after the trailing blanks of both are removed, in upper case, as
  a whole. The issue request takes the newest such entry. A collect request takes
  the oldest entry that carries the same second (hh.mm.ss) as the echo that the
  key was handed out for (@ref-cons-collect). When there is no echo, the block
  is empty.
+ *The source.* The echo's source field (type and number of the originator, 8
  characters at column 14 of the formatted line) is the source of the issuer.
+ *The lines.* The entries after the echo are examined in order. An entry whose
  source equals the block's source, or is blank, belongs to the block, and so
  does a continuation line of a multi-line message. The message number is the
  last word of the latest line of the block that has a source, when that word
  consists of digits only. A continuation line begins, after blanks, with that
  number.
+ *The end.* The block ends at an entry that has another source, once the block
  has a line. Before the first line, such an entry is skipped.
+ *The next command.* An entry that is not a continuation, that has the source of
  the issuer or a blank source, and whose first word has no digit, is taken to be
  a command (@ref-cons-mtt). With the source of the issuer, it ends the block.
  With a blank source, it is skipped.
+ *A command for another task.* While the block has no line, the first entry with
  another source is taken as the source of the block when its second is the
  second of the echo or one second later (the clock wraps at midnight). This is
  how the reply to #cmd("F name,...") reaches the answer, because the target
  writes it under its own source. It happens once per block.

mvsMF numbers the lines of the block from 0. A line with an empty text counts but
is not returned. The text of a line is the formatted line from column 24 on,
without trailing blanks. A line that would not fit into the answer text is
left out, and it still counts. The lines after it that still fit are kept. The
answer text is less than 32768 bytes long (@ref-cons-limits).

The answer block of a collect is the same block, read again. Only the lines from
the number that the cursor holds on are returned.

=== Limits of the Capture <ref-cons-limits>

#tab(caption: [Limits of the capture])[
  #table(columns: (1.6in, 1fr),
    [Limit], [Value],
    [Command length accepted], [126 characters. A longer command gets reason code
      17. The issue handler sends only the first 100 characters to MVS; the echo
      that mvsMF looks for is the whole command.],
    [Answer text], [Less than 32768 bytes (32767 at most), including the one
      #cmd("\\r") per line.],
    [Message text of one line], [232 characters: the table keeps 256 characters of
      an entry, and 24 are the prefix.],
    [Capture time], [2.1 to 3.1 seconds, or 0.3 seconds after the last change.],
    [Echo time resolution], [One second. The table has no finer time.],
    [Lock wait], [50 tries 0.1 second apart (5 seconds).],
  )
]

== The Master Trace Table <ref-cons-mtt>

#idx("Master Trace Table")#idx("MTT")
The Master Trace Table is the table in storage where MVS keeps the console
messages of the system. mvsMF reads a copy of it with the C library service for
the table and treats each entry as a formatted line:

#tab(caption: [Columns of a formatted table line])[
  #table(columns: (1.1in, 0.8in, 1fr),
    [Columns (from 0)], [Length], [Content],
    [0], [4], [Flags.],
    [4], [about 9], [The time, as hh.mm.ss, with leading blanks.],
    [14], [8], [The source: type and number of the originator, for example
      #cmd("STC  320"). Blank for some messages (for example those of JES2).],
    [24], [rest], [The message text.],
  )
]

Properties that the console services depend on:

- The time has the resolution of one second. It has no date.
- The entries have no sequence number and no stable position. A copy taken later
  is a different array: old entries have been dropped and new ones appended.
- The table holds a limited number of entries. The oldest are dropped first.
- One entry holds at most 256 characters in a copy. mvsMF takes no more.
- A command does not have a field that tells it from a message. mvsMF treats a
  line as a command when its first word has no digit. Message identifiers
  contain a digit.

The reading of a table is a copy, so the requests never lock the table.

== Serialization <ref-cons-lock>

#idx("lock")#idx("console lock")#idx("429")
The table is one stream. Two commands that are open at once write their lines
into it at the same time, and the lines cannot be told apart afterwards. So mvsMF
lets one issue request have an open answer block at a time. This includes
requests with #cmd("async").

The lock is an exclusive lock (the C library lock service) on a field
of the per-CGI context of HTTPD. It is held from just before SVC 34 to the end of
the convergence window. A detection wait (@ref-cons-detect-sync) happens after
the lock is released. The collect, detection and log requests do not take the
lock.

- A request that cannot take the lock tries again every 0.1 second, up to 50
  tries. Then it answers #cmd("429") with reason code 16.
- While trying, the request looks at the server state. When the server is
  quiescing or shutting down, it answers #cmd("503") with reason code 17. The
  command was not issued.
- When the request fails with an abend, the lock is released by the cleanup of
  the router.
- When HTTPD does not offer the per-CGI context, there is nothing to lock on and
  the commands are not serialized.

One known weakness remains: the first read runs right after the command is
issued, when the echo may not be in the table yet. Then the newest echo of an
identical earlier command can be taken, and the answer is the block of that
command (see "What the Capture Cannot Tell You" in the _mvsMF User's Guide_). It is not fixed.

== Collect <ref-cons-collect>

#idx("collect")#idx("solmsgs")
#cmd("GET /zosmf/restconsoles/consoles/{console-name}/solmsgs/{cmd-response-key}")
returns the lines of the answer block that the client has not received.

The status is #cmd("200"). The body has one field, #cmd("cmd-response"): the new
lines, each followed by #cmd("\\r"), or an empty string.

How it works:

+ mvsMF looks up the key in the store (@ref-cons-store). If the store is not
  available, or the key is not found or has expired, the answer is empty. This is
  not an error.
+ It reads the table once, finds the block of the key (@ref-cons-block), and
  returns the lines whose number is at least the number of lines delivered so far.
+ It sets the delivered count to the number of lines of the block, if that is
  larger, and stores the cursor again. A shorter block never lowers the count.
+ If the copy of the table cannot be taken, the answer is #cmd("500") with
  return code 8 and reason code 1, not an empty answer. The cursor is stored as
  it was, so it stays alive and the same key works at the next request.

The request does not wait. It does not take the lock. It does not check the
console name.

An empty answer means one of: no line is new, the key is unknown, the key has
expired or been evicted, the store is not available, or the echo has left the
table.

== Detection <ref-cons-detect>

#idx("detection")#idx("unsolicited message")
A detection looks for a text in the table lines. The text comes from
#cmd("unsol-key"). A line matches when its formatted text, in upper case, contains
the key in upper case. The formatted text includes the flags, the time and the
source, up to 199 characters of the line. So a key can match the prefix of a
line.

A detection fires when the table holds a matching line that is newer than the
anchor. mvsMF takes the anchor right after it issues the command and before it
reads the answer. The anchor is a place in the table, not a count of lines: the
table is a window that wraps and is bounded in bytes, so after a burst of other
messages the oldest lines are gone, and a count of matching lines can fall
although a new match has arrived. The anchor consists of

- the time of the newest line of the table that carries a time (hours, minutes
  and seconds), and
- the number of matching lines that carry exactly that time.

A line without a time of its own, such as the continuation of a multi-line
message, takes the time of the line before it. A matching line is newer than
the anchor when its time is later. At the time of the anchor itself, a matching
line is newer only when there are more of them than the anchor counted; the
time has a grain of one second, and mvsMF cannot tell the lines of that second
apart. When the table holds no line with a time at the anchor, every matching
line counts as newer.

The time carries no date. mvsMF compares it modulo 24 hours: a line is later
when its time is less than 12 hours ahead of the anchor. A detection that stays
armed for more than 12 hours (a #cmd("detect-time") of more than about 41000
ticks) cannot see lines stamped later than that, and a read answers
#cmd("waiting").

Three consequences:

- *The reply of the command can be a match.* mvsMF takes the anchor after the
  command was issued, and the reply of the command can land on either side of
  it. A #cmd("D T") with the #cmd("unsol-key") #cmd("IEE136I") can report
  #cmd("detected") for its own reply.
- *A detection is not latched.* Every read, and every look of a synchronous
  wait, takes the table again. A matching line that has left the table by the
  time of the next read does not count.
- *The store can push the detection out* (@ref-cons-store).

=== Synchronous <ref-cons-detect-sync>

With #cmd("unsol-detect-sync") set to #cmd("Y") or #cmd("y"), the issue request
waits after the capture and after the lock was released. It looks for matching
lines newer than the anchor every 0.1 second. When there is one, the answer has
#cmd("status") #cmd("detected") and the newest matching line in #cmd("msg") (the
text from column 24 on, leading blanks removed, trailing blanks removed; mvsMF
reads the first 199 characters of the formatted line, so at most 175 characters
remain). When the wait ends first, #cmd("status") is #cmd("timeout"), unless
the last look at the table could not take a copy of it. Then the answer is
#cmd("500") with return code 8 and reason code 14, because the table did not
show that the text is absent. The command was issued.
The wait is the value of #cmd("unsol-detect-timeout"), counted in ticks of
1.05 seconds. When the server begins to shut down during the wait, the
answer is #cmd("503") with reason code 15, and the command has been issued.

=== Asynchronous <ref-cons-detect-async>

Without #cmd("unsol-detect-sync"), the issue request stores a detection (the
key text, the anchor, the window #cmd("detect-time") and the start time) under a
new key and returns it as #cmd("detection-key").

#cmd("GET /zosmf/restconsoles/consoles/{console-name}/detections/{detection-key}")
looks at the table now and answers with status #cmd("200") and two fields:

#tab(caption: [Fields of the detection answer])[
  #table(columns: (1.0in, 1.4in, 1fr),
    [Field], [Value], [Meaning],
    [#cmd("status")], [#cmd("detected")],
      [The table holds a matching line newer than the anchor. This is tested
       first, so the window does not matter. The status is not kept: when the
       line has left the table at the next read, the status is #cmd("waiting")
       or #cmd("expired") again.],
    [], [#cmd("expired")],
      [Not detected, and more than #cmd("detect-time") ticks (about 1.05 seconds
       each) have passed since the start.],
    [], [#cmd("waiting")], [Not detected, and the window is still open.],
    [#cmd("msg")], [text],
      [With #cmd("detected"): the newest matching line, as in the synchronous
       form. Otherwise empty.],
  )
]

A key that is not found, or a store that is not available, gets
#cmd("500") with return code 5 and reason code 9. When the copy of the table
cannot be taken, the answer is #cmd("500") with return code 8 and reason code 1,
and not #cmd("waiting") or #cmd("expired"); the detection stays armed. Each read of a detection
refreshes its entry in the store (@ref-cons-store). The request does not check
the console name.

A read of a detection does not wait and does not remember an earlier answer.
The table holds the lines of a limited time, minutes on a quiet system and
seconds under heavy console traffic. A client that wants to see a message polls
within that time.

== The Hardcopy Log <ref-cons-log>

#idx("console log")#idx("hardcopy log")#idx("v1/log")
#cmd("GET /zosmf/restconsoles/v1/log") returns the table lines of a period of
time. The source is the Master Trace Table (@ref-cons-mtt), not the SYSLOG data
set, in spite of the value #cmd("SYSLOG") in the answer. The log reaches back as
far as the table does.

=== Query Parameters <ref-cons-log-par>

mvsMF looks for the parameter name as the client sent it, and then in upper case.

#tab(caption: [Query parameters of the log request])[
  #table(columns: (1.1in, 1fr),
    [Parameter], [Meaning],
    [#cmd("timeRange")],
      [The length of the period: 1 to 999 and a unit #cmd("s"), #cmd("m") or
       #cmd("h") (either case), for example #cmd("10m"). Default 10 minutes (600
       seconds). Anything else gives reason code 22.],
    [#cmd("direction")],
      [#cmd("backward") (default) or #cmd("forward"), either case, or empty. The period
       lies before or after the starting point. Anything else gives reason code
       22.],
    [#cmd("time")],
      [The starting point as #cmd("yyyy-mm-ddThh:mm[:ss]Z"). At least five numbers
       must be read with the format #cmd("%d-%d-%dT%d:%d:%d"); the #cmd("Z") is not
       checked. The time is taken as the local time of the system (see below).
       Without it and without #cmd("timestamp"), the starting point is now. It is
       not read when #cmd("timestamp") is present and not empty.],
    [#cmd("timestamp")],
      [The starting point as milliseconds, digits only. mvsMF drops the last three
       digits. A value of three digits or fewer is 0. It wins over #cmd("time").
       Another character gives reason code 22.],
    [#cmd("hardcopy")],
      [#cmd("operlog") or #cmd("syslog"), either case, or empty. The value is
       checked and otherwise unused. Another value gives reason code 22.],
    [#cmd("sysName")],
      [Up to 8 characters. The value is checked for its length (reason code 24)
       and otherwise unused. The log is always that of the local system.],
  )
]

A #cmd("time") or #cmd("timestamp") after the current time gives reason code 23.

=== The Selection of Lines <ref-cons-log-sel>

- The period is the starting point and the length of #cmd("timeRange"), backward
  or forward. Both ends are included.
- The table has no date. mvsMF walks the table from the newest line to the oldest.
  It counts back one day each time the time of a line is more than twelve hours
  later than that of the line after it (for the newest line: than the time now).
- A line whose time cannot be read is left out.
- The items are in the order of the table, the oldest first, for both directions.
- At most 10000 items are returned. The items run from the oldest to the newest,
  so when more lines match, the newest are the ones left out.
- The time frame is the local clock of the system. The text #cmd("GMT") in
  #cmd("time") and the number in #cmd("timestamp") label this local time as if it
  were Universal Time. A #cmd("time") or #cmd("timestamp") parameter is read in the
  same frame, so a value taken from an answer returns to the same line.

=== The Answer <ref-cons-log-ans>

The status is #cmd("200"). The body is a JSON object:

#tab(caption: [Fields of the log answer])[
  #table(columns: (1.3in, 1fr),
    [Field], [Value],
    [#cmd("timezone")],
      [The difference of the local clock to Universal Time in whole hours, as the C
       library of mvsMF reports it.],
    [#cmd("source")], [Always #cmd("SYSLOG").],
    [#cmd("items")], [The array of items.],
    [#cmd("totalitems")], [The number of items.],
    [#cmd("nextTimestamp")],
      [The start of the period, in milliseconds, for #cmd("backward"); its end for
       #cmd("forward"). Pass it as #cmd("timestamp") to continue.],
  )
]

#tab(caption: [Fields of a log item])[
  #table(columns: (1.1in, 1fr),
    [Field], [Value],
    [#cmd("message")],
      [The text of the line from column 24 on, without leading and trailing blanks,
       at most 232 characters.],
    [#cmd("jobName")],
      [The source field of the line (8 characters from column 14), without trailing
       blanks. This is the type and number of the originator, for example
       #cmd("STC  320"), not always a job name.],
    [#cmd("system")],
      [The SMF system id of the local system, without trailing blanks.],
    [#cmd("type")], [Always #cmd("HARDCOPY").],
    [#cmd("time")],
      [The time as #cmd("Wkd Mon dd hh:mm:ss GMT yyyy"), for example the text
       #cmd("Fri Oct 23 09:24:38 GMT 2026"). See the time frame above.],
    [#cmd("timestamp")], [The same instant as a number of milliseconds, not in
      quotes.],
  )
]

== Keys, Cursors and the Store <ref-cons-keys>

#idx("cmd-response-key")#idx("detection-key")#idx("cursor")
mvsMF keeps no state in static storage. The state of the keys lives in a store in
subpool 0, which hangs off the per-CGI context that HTTPD keeps for the
address space (the context block has the identifier #cmd("MVSMFCTX")). The
store is created at the first need and lives until HTTPD ends. A restart of
HTTPD loses every key.

=== Key Formats <ref-cons-keyfmt>

#tab(caption: [Keys])[
  #table(columns: (1.4in, 1fr),
    [Key], [Format],
    [#cmd("cmd-response-key")],
      [16 hexadecimal characters: the two words of the TOD clock at the time of the
       issue, high word first. The key is unique for the call.],
    [#cmd("detection-key")],
      [The letter #cmd("D") and seven hexadecimal characters, taken from the same
       clock value.],
  )
]

Both keys are only handles. The facts about the command live in the stored entry.
The store compares the first 16 characters of a key, so a key with the same first
16 characters and anything after them finds the same entry.

=== The Store <ref-cons-store>

#tab(caption: [Properties of the store])[
  #table(columns: (1.5in, 1fr),
    [Property], [Value],
    [Slots], [32, for cursors and detections together.],
    [Name], [16 characters, padded with zero bytes.],
    [Value], [At most 192 bytes.],
    [Lifetime], [About 5 minutes after the last use (300 ticks of the TOD high word,
      about 1.05 seconds each). A read or a write is a use.],
    [Full store], [A new entry with the name of an existing one overwrites it.
      Otherwise it takes the first slot, in the order of the slots, that is free
      or expired. If there is none, it takes the slot that was used least
      recently.],
    [Locking], [One latch for the whole store protects each single operation. It
      does not span a sequence of operations. The store is meant for one
      outstanding operation per key.],
    [Not available], [Collect answers empty. A detection read answers
      #cmd("500"). The issue request still works, and the cursor is not stored.],
  )
]

The cursor of a command holds the time of the issue, the number of lines already
delivered, the second of the echo (or -1 when the echo was not found before the
capture ended), and the upper-case command. The detection entry holds the start
time, the window, the anchor (the time of the end of the table and the number of
matches at that time), and the upper-case key.

When the echo second is -1, a collect takes the newest echo of the command. This
is how a collect reaches a slow reply after an issue whose capture ended without
an echo.

== Console Errors <ref-cons-errors>

#idx("errors", "console")#idx("return-code")#idx("reason-code")
The console services report an error as a JSON object with three fields. This is
not the shape of the data set and job requests.

#tab(caption: [Fields of a console error])[
  #table(columns: (1.2in, 1fr),
    [Field], [Value],
    [#cmd("return-code")], [A number: 1, 5 or 8.],
    [#cmd("reason-code")], [A number, see below.],
    [#cmd("reason")], [Text.],
  )
]

#tab(caption: [Console errors])[
  #table(columns: (0.5in, 0.35in, 0.45in, 1.4in, 1fr),
    [HTTP], [RC], [Reason], [Request], [Text and cause],
    [#cmd("400")], [1], [6], [issue],
      [The Content-Type cannot be handled, 'application/json' is expected. The
       header is missing or lacks #cmd("application/json").],
    [#cmd("400")], [1], [14], [issue],
      [Incorrect console name. The length must be greater than 1 and less than 9.],
    [#cmd("400")], [1], [12], [issue],
      [The body of the request is not in JSON format. Cause: the body is missing or
       could not be read.],
    [#cmd("413")], [1], [12], [issue],
      [The request body is too large.],
    [#cmd("500")], [8], [1], [issue],
      [Storage for the request body could not be obtained.],
    [#cmd("400")], [1], [13], [issue],
      [Cannot find 'cmd' in request body, or value of 'cmd' is empty.],
    [#cmd("400")], [1], [17], [issue],
      [Command length must be less than 127.],
    [#cmd("400")], [1], [25], [issue],
      [Invalid value for sol-key: regular expressions are not supported.],
    [#cmd("400")], [1], [25], [issue],
      [Invalid value for unsol-key: regular expressions are not supported.],
    [#cmd("400")], [1], [5], [issue],
      [Routing to another system is not supported.],
    [#cmd("503")], [8], [17], [issue],
      [Server is quiescing; the command was NOT issued. Retry later.],
    [#cmd("429")], [8], [16], [issue],
      [Another console command is in progress. Retry the request. Cause: the
       console lock was not free within 5 seconds. The command was not issued.],
    [#cmd("500")], [8], [14], [issue],
      [Cannot get the command response. Cause: no storage for the response buffer. The command has
       been issued.],
    [#cmd("500")], [8], [14], [issue],
      [Command was issued; the Master Trace Table could not be copied, so the
       response could not be read. Do not blindly retry -- retry re-issues the
       command. Cause: no read of the capture got a copy of the table.],
    [#cmd("500")], [8], [14], [issue],
      [Command was issued; the Master Trace Table could not be copied, so
       unsolicited-message detection was not armed. Do not blindly retry --
       retry re-issues the command. Cause: no anchor for the #cmd("unsol-key")
       could be taken.],
    [#cmd("500")], [8], [14], [issue],
      [Command was issued; the Master Trace Table could not be copied, so
       unsolicited-message detection could not finish. Do not blindly retry --
       retry re-issues the command. Cause: the last look of a synchronous wait
       failed.],
    [#cmd("503")], [8], [15], [issue],
      [Command was issued; response capture abandoned (server quiescing). Do not
       blindly retry -- retry re-issues the command.],
    [#cmd("503")], [8], [15], [issue],
      [Command was issued; unsolicited-message detection abandoned (server
       quiescing). Do not blindly retry -- retry re-issues the command.],
    [#cmd("500")], [5], [9], [detection],
      [Cannot find the result for the specified detection ID.],
    [#cmd("500")], [8], [1], [collect],
      [An error occurred during the retrieval of the command response. Cause: the
       copy of the table could not be taken. The cursor is kept.],
    [#cmd("500")], [8], [1], [detection],
      [An error occurred during the retrieval of the detection result. Cause: the
       copy of the table could not be taken. The detection stays armed.],
    [#cmd("400")], [1], [22], [log],
      [The parameter timeRange is invalid. Example: 10m.],
    [#cmd("400")], [1], [22], [log],
      [The parameter direction is invalid. Use backward or forward.],
    [#cmd("400")], [1], [22], [log],
      [The parameter hardcopy is invalid. Use operlog or syslog.],
    [#cmd("400")], [1], [24], [log],
      [The sysName cannot exceed 8 characters.],
    [#cmd("400")], [1], [22], [log],
      [The parameter timestamp is invalid.],
    [#cmd("400")], [1], [22], [log],
      [The parameter time is invalid. Example: 2021-05-25T07:00Z.],
    [#cmd("400")], [1], [23], [log],
      [The time or timestamp specified is in the future.],
    [#cmd("500")], [8], [1], [log],
      [An error occurred during the retrieval of the hardcopy log.],
  )
]

The log checks its parameters in the order #cmd("timeRange"), #cmd("direction"),
#cmd("hardcopy"), #cmd("sysName"), #cmd("timestamp"), #cmd("time"), and then the
future test.

A reason code is not unique. Reason code 14 with return code 1 is a bad console
name, and with return code 8 it is a storage failure after the command was issued.
Reason codes 12, 1, 15 and 17 also occur more than once. Read the return code
and the text with the reason code.

The console error shape applies to errors of the console handlers. The refusal
by the permission check has the shape of the data set services (@ref-cons-auth).
A user ID that mvsMF does not let in gets the #cmd("401") of @ref-auth. A route or method that
does not exist gets the router's reply (@ref-conv).

== What Is Not Supported <ref-cons-unsup>

#idx("not supported", "console")
- *Regular expressions.* #cmd("solKeyReg") and #cmd("unsolKeyReg") with a value
  that begins with an upper-case #cmd("Y") are refused. Any other value, a
  lower-case #cmd("y") included, is ignored, so the key is then a plain text.
- *Routing to another system.* #cmd("system") with any value is refused.
- *Console selection.* The console name is a label. All requests use the one
  Master Trace Table of the local system, and mvsMF does not check the name
  against a defined console.
- *Other body fields.* A field that the issue request does not read is ignored
  and does not cause an error.
- *The SYSLOG data set and OPERLOG.* The log request reads the Master Trace Table
  only (@ref-cons-log).
- *The diagnostic function.* The function #cmd("fn=cmd") of #cmd("/zosmf/test") is
  not part of the console services. See @ref-test.
