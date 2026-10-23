#import "../bookmaster/bookmaster.typ": *

= Issuing Console Commands <ug-console>

#idx("console services")#idx("operator command")
This chapter shows how to issue an MVS operator command through mvsMF, how to
read the answer, what to do when the answer comes late, how to wait for a
message that nobody asked for, and how to read the console log. Each section is
a task, and each task has a session that was typed with #cmd("curl").

The variables #cmd("MVSMF_URL"), #cmd("MVSMF_USER") and #cmd("MVSMF_PASS")
in the sessions, and the way to read them, are explained in @ug-first. Two more
appear in this chapter. #cmd("KEY") holds the #cmd("cmd-response-key") of an
earlier answer, and #cmd("DKEY") holds a #cmd("detection-key"). Set them by hand
from the answer before.

== What the Console Services Do <ug-console-what>

#idx("Master Trace Table")#idx("MTT")
mvsMF has four console requests. A command goes to MVS with the operator
command call (SVC 34). That call returns no reply. mvsMF reads the answer from
the _Master Trace Table_ (MTT), the table in storage where MVS keeps the recent
console messages. It finds the echo of the command in the table and takes the
lines that follow the echo as the answer.

#tab(caption: [The console requests])[
  #table(columns: (1.7in, 1fr, 1.2in),
    [Task], [Request], [Section],
    [Issue a command and read the answer],
      [#cmd("PUT /zosmf/restconsoles/consoles/")#var("name")], [@ug-console-issue],
    [Read more of an answer later],
      [#cmd("GET /zosmf/restconsoles/consoles/")#var("name")#cmd("/solmsgs/")#var("key")],
      [@ug-console-collect],
    [Wait for a message],
      [#cmd("GET /zosmf/restconsoles/consoles/")#var("name")#cmd("/detections/")#var("key")],
      [@ug-console-detect],
    [Read the console log],
      [#cmd("GET /zosmf/restconsoles/v1/log")], [@ug-console-log],
  )
]

The console name in the path is any text of two to eight characters. The issue
request uses it only to build the addresses it returns. The other requests do
not look at it. All names reach the same table.

#note[*The console services run with the authority of the server.* mvsMF makes
no authorization check of its own for them: any caller that mvsMF lets in can
issue any operator command. The administrator protects the console services in
the HTTPD configuration, in front of mvsMF. See @ug-security-console, which defines the route and the profile and shows what
a user without the permission gets. Until that is done, treat every user ID that
can log on to mvsMF as an operator.]

== Issuing a Command <ug-console-issue>

#idx("command", "issue")#idx("D T")
The request is a #cmd("PUT") with a JSON body that names the command. The
header #cmd("Content-Type: application/json") is required. This session issues
#cmd("D T"), the command that displays the time of day:

#screen(raw(read("../ex/ug-console/c-dt.txt"), block: true))

The answer is a JSON object. #cmd("cmd-response") holds the lines that MVS wrote
in answer to the command. Each line ends with #cmd("\\r"), the JSON form of a
carriage return. The echo of the command is not part of the answer.
#cmd("cmd-response-key") names the answer, and the next section uses it.
#cmd("cmd-response-url") and #cmd("cmd-response-uri") are the address of the
collect request for that key, with and without the host.

What mvsMF does with the command:

- It changes the command to upper case, all of it, also text in quotes. #cmd("d t")
  is issued as #cmd("D T").
- It accepts a command of up to 126 characters. A longer command is refused
  with #cmd("400"). Only the first 100 characters are sent to MVS, and mvsMF
  looks for an echo that has the whole text. Keep a command to 100 characters
  or fewer.
- It issues one command at a time. A request that arrives while another command
  is open waits for up to five seconds and then gets #cmd("429")
  (@ug-console-fail).
- It waits for the answer to settle before it replies. It reads the table every
  tenth of a second and replies when the number of lines has been the same for
  three reads in a row. A short answer such as the one of #cmd("D T") takes
  three tenths of a second at least. When no line follows the echo, mvsMF reads
  for about three seconds and replies with an empty #cmd("cmd-response").

The body is not parsed as JSON. mvsMF looks for the field name in double quotes
and takes the text in double quotes after it. So every value is a string in
quotes, also a number. Write #cmd("\"async\":\"Y\""), not
#cmd("\"async\":true"), and #cmd("\"detect-time\":\"30\""), not
#cmd("\"detect-time\":30"). A value that is not in quotes is as good as missing.
A value ends at the first double quote, and mvsMF does not read the JSON
escapes, so a command cannot hold a double quote or a backslash sequence.

Without the header, #cmd("curl -d") sends the body as a form, and mvsMF refuses
it:

#screen(raw(read("../ex/ug-console/c-ct.txt"), block: true))

The error body of the console requests has the fields #cmd("return-code"),
#cmd("reason-code") and #cmd("reason"). The data set and job requests of mvsMF
use other field names (@ug-errors).

The _mvsMF Reference_, chapter "Console Services", lists every field of the body
and of the answer.

== Collecting an Answer <ug-console-collect>

#idx("collect")#idx("cmd-response-key")#idx("async")
Every answer carries a #cmd("cmd-response-key"). A #cmd("GET") with that key on
the path #cmd("solmsgs") returns the lines of the answer that the client has not
received yet. The field #cmd("async") with the value #cmd("Y") leaves the lines
out of the first answer, so that the first collect returns all of them:

#screen(raw(read("../ex/ug-console/c-async.txt"), block: true))

#note[*#cmd("async") is not faster.* mvsMF waits for the answer to settle in
the same way, and it holds back the next command for the same time. The
difference is only that the reply has no #cmd("cmd-response") and no
#cmd("sol-key-detected").]

Set #cmd("KEY") to the value of #cmd("cmd-response-key") and ask for the lines:

#screen(raw(read("../ex/ug-console/c-collect.txt"), block: true))

Each further collect returns only what is new. When nothing is new, the answer
is an empty #cmd("cmd-response"):

#screen(raw(read("../ex/ug-console/c-collect2.txt"), block: true))

An empty answer is the only sign that nothing more came, and mvsMF gives no
other. It also means that the key is unknown. A key that mvsMF has forgotten, a
key from before the last restart of HTTPD, and a made-up key all get the status
#cmd("200") and an empty #cmd("cmd-response"), not an error. mvsMF keeps a key
for about five minutes after its last use, and it keeps 32 keys and detections
at most. A client that asks again keeps its key alive. The key also stops
working when the echo of the command has left the table.

A collect does not wait. It reads the table once and replies.

== When the Reply Arrives Late <ug-console-late>

#idx("late reply")#idx("P FTPD")#idx("sol-key")
A command may answer in parts, with a pause between. The stop of a started task
is a case: #cmd("P FTPD") makes FTPD write #cmd("FTPD098I"), and the messages
about the end of the job follow when the task has ended. mvsMF ends its wait
when the number of lines has not changed for three reads, that is for three
tenths of a second. When the pause is longer, the first request gets only the
first part:

#screen(raw(read("../ex/ug-console/c-late.txt"), block: true))

The status is #cmd("200"), and nothing in the answer says that it is short. The
rest is in the table a moment later, and a collect with the key returns it:

#screen(raw(read("../ex/ug-console/c-late-collect.txt"), block: true))

To get a complete answer from a command that may pause, issue it, then collect
every few seconds until the lines you expect have come. mvsMF cannot tell the
client when the last line has arrived, because the table does not say it. The
client decides: it waits for the last message that it knows the command writes,
or it stops after a pause that is long enough for its command.

The field #cmd("sol-key") names text to look for. When the text is in the lines
that the first request returned, the answer has
#cmd("\"sol-key-detected\":true"), otherwise #cmd("false"). The test is a plain
search for the text. It distinguishes upper and lower case, and it looks only at
the lines of the first answer, not at lines that a collect returns later. The
text has at most 63 characters. A regular expression is not supported: the field
#cmd("solKeyReg") with the value #cmd("Y") is refused with #cmd("400").

== Waiting for an Unsolicited Message <ug-console-detect>

#idx("unsolicited message")#idx("detection")#idx("unsol-key")
Some commands only start something, and the message that tells the result comes
later and on its own. The field #cmd("unsol-key") names text to wait for. With
#cmd("unsol-detect-sync") set to #cmd("Y"), the request waits until the text
shows up in the table. This session starts FTPD and waits for #cmd("FTPD054I"),
the message that says FTPD is listening:

#screen(raw(read("../ex/ug-console/c-start.txt"), block: true))

The answer has the usual fields and two more. #cmd("status") is #cmd("detected")
and #cmd("msg") is the line that matched. When the text does not show up in time,
#cmd("status") is #cmd("timeout") and #cmd("msg") is empty. The wait is
#cmd("unsol-detect-timeout") seconds, 20 when the field is missing. A value
outside 1 to 60 also gives 20. The wait starts after the wait for the answer of
the command, so the request can take 20 seconds and more. Keep the time-out of
the client above that.

The other form does not wait. Without #cmd("unsol-detect-sync") the answer comes
back at once with a #cmd("detection-key"), and the client asks later with a
#cmd("GET") on the path #cmd("detections"). The field #cmd("detect-time") sets
the window in seconds, 30 when it is missing. This session arms a detection for
#cmd("FTPD099I"), the message that ends the stop of FTPD, and asks eight seconds
later. Set #cmd("DKEY") to the #cmd("detection-key"):

#screen(raw(read("../ex/ug-console/c-arm.txt"), block: true))

#screen(raw(read("../ex/ug-console/c-poll.txt"), block: true))

The #cmd("status") is one of three words. #cmd("detected") comes with the
message in #cmd("msg"). #cmd("waiting") means that nothing has matched yet and
the window is open. #cmd("expired") means that nothing has matched and the
window has closed. A key that mvsMF does not know gets the status #cmd("500")
and a console error with #cmd("reason-code") 9.

What to keep in mind:

- *The text can match more than the message you mean.* mvsMF compares against
  the whole line of the table, with the time and the originator in front of the
  message, and it ignores case. A short word matches many lines.
- *It counts new matches.* Right after it has issued the command, mvsMF counts
  the lines that contain the text, and it reports a detection when the count is
  higher later. The echo of your command and its reply can arrive after that
  count. Text that the command itself contains, such as #cmd("FTPD") in
  #cmd("S FTPD"), can therefore be reported as detected at once. Choose text
  that only the message you wait for contains.
- *A detection stays detected.* Each ask counts again. The key reports
  #cmd("detected") for as long as more lines match than at the start, also after
  the window has closed. #cmd("expired") only means that this is not so now.
- *The table is a window.* It holds a limited number of recent lines, and the
  oldest are dropped as new ones come. When matching lines are dropped as fast
  as new ones arrive, the count does not rise.

#note[*A defect* (mvsmf\#195): a detection can report #cmd("waiting") for a
message that has been written. The detection compares a count of lines over a
table that drops its oldest lines, and the count does not rise when a matching
line is dropped as a new one arrives. Do not take #cmd("waiting") as proof that
the message has not come. Ask again, and look at the log (@ug-console-log) if
the message matters.]

The text has at most 63 characters, and a regular expression is not supported:
the field #cmd("unsolKeyReg") with the value #cmd("Y") is refused with
#cmd("400").

== Reading the Log <ug-console-log>

#idx("console log")#idx("hardcopy log")
The log request returns the lines of the table for a period of time. mvsMF reads
the same table as for a command. It does not read the SYSLOG data set, so the
log reaches back only as far as the table does, and how far that is depends on
how busy the system is. The default period is the last ten minutes. This session
asks for the last thirty seconds:

#screen(raw(read("../ex/ug-console/c-log.txt"), block: true))

Each item has the text of the line in #cmd("message"), the originator in
#cmd("jobName"), the system in #cmd("system"), and the time twice: #cmd("time")
as text and #cmd("timestamp") as a number of milliseconds. The items are in
order of time, the oldest first. #cmd("jobName") holds the originator field of
the table, which is the type of the originator and its number, for example the
text #cmd("STC  320") for a started task. It is not always a job name.

The query parameter #cmd("timeRange") sets the length of the period. It is a
number from 1 to 999 and a unit, #cmd("s"), #cmd("m") or #cmd("h"): #cmd("90s"),
#cmd("10m"), #cmd("2h"). A value mvsMF cannot read is refused with a console
error, the status #cmd("400") and #cmd("reason-code") 22:

#screen(raw(read("../ex/ug-console/c-log-bad.txt"), block: true))

Three things about the times:

- The table keeps the hour, minute and second of a line, and no date. mvsMF
  works out the date by counting back from now, and steps back one day where the
  clock of the lines jumps back by more than twelve hours.
- The times are the clock of the MVS system, not Universal Time. The text of
  #cmd("time") ends in #cmd("GMT") and #cmd("timestamp") looks like a UNIX time,
  but both carry the local time of the system as if it were Universal Time.
  The field #cmd("timezone") is the difference between the local clock and
  Universal Time in whole hours, as the C library of mvsMF sees it.
- To go further back, take #cmd("nextTimestamp") from the answer and send it as
  #cmd("timestamp"). The _mvsMF Reference_, chapter "Console Services", section
  "The Hardcopy Log", describes this and the other parameters.

== What the Capture Cannot Tell You <ug-console-limits>

#idx("capture")#idx("cut answer")
A command is a request to the system, and the answer is what mvsMF finds in a
table afterwards. The answer you get can be wrong in ways that the status
#cmd("200") does not show.

- *The answer can be cut.* A reply that pauses for longer than three tenths of a
  second is cut at the pause (@ug-console-late). Nothing in the answer says that
  more is coming. Collect, and judge from the text whether it is complete.
- *An empty answer has several causes.* The command had no reply. The reply had
  not come in time. mvsMF did not find the echo, for example because the command
  has more than 100 characters. The echo had left the table. An empty
  #cmd("cmd-response") does not tell which.
- *The answer can be too long.* The text is capped at 32768 bytes, and lines
  that do not fit are left out without a sign. A single line holds at most 232
  characters of message, because the table keeps 256 characters of each line and
  24 of them are the time and the originator.
- *The answer can belong to the wrong command.* mvsMF finds the answer by the
  echo of the command. When the same command was issued a moment ago and its echo
  is still in the table, the first read can find that echo and return the
  answer of the earlier command. This is a known weakness of the method. It
  matters for a command that is issued over and over, such as #cmd("D T"). The
  table has no finer time than a second, so two identical commands in the same
  second cannot be told apart.
- *Other writers are not under the control of mvsMF.* mvsMF puts its own
  commands in a row. An operator at a console, or another program, writes into
  the table at any time, and those lines can end the answer early or be taken
  into it.
- *A command for another started task.* The reply to #cmd("F name,...") comes
  from that task. mvsMF takes it into the answer when it arrives in the second
  of the echo or in the second after. A reply that comes later is not in the
  first answer. Collect it.

== When a Request Fails <ug-console-fail>

#idx("429")#idx("503")
Besides the errors of the body (@ug-console-issue), four failures matter for a
client that issues commands:

#tab(caption: [Failures that decide whether a client may send the request again])[
  #table(columns: (0.6in, 0.7in, 1fr),
    [Status], [Reason code], [Meaning],
    [#cmd("429")], [#cmd("16")],
      [Another command is open. The command was *not* issued. Send it again.],
    [#cmd("503")], [#cmd("17")],
      [HTTPD is shutting down. The command was *not* issued. Send it again later.],
    [#cmd("503")], [#cmd("15")],
      [HTTPD began to shut down after the command was issued. The command *was*
       issued, and only the wait for the answer was dropped. Do not send it
       again blindly: a second #cmd("S"), #cmd("V") or #cmd("$P") does it a
       second time.],
    [#cmd("500")], [#cmd("14")],
      [mvsMF had no storage for the answer. The command *was* issued.],
  )
]

The other failures of the console requests, and the status that goes with each,
are in the _mvsMF Reference_, chapter "Console Services", section "Console
Errors". @ug-errors has the failures that all requests share, such as the
refusal of a user ID (#cmd("401")).
