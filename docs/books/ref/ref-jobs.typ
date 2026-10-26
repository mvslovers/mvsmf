#import "../bookmaster/bookmaster.typ": *

= Job Services <ref-jobs>

#idx("job")#idx("restjobs")#idx("JES2")
This chapter lists every request of the job services of mvsMF (mvsmf): the
routes, the query parameters, the headers, the body fields, the fields of the
answers, the status codes and the error reports. The jobs service reads and
writes JES2 through libc370: it opens the JES2 checkpoint and spool data sets
for a request, and it writes JCL to the JES2 internal reader. It covers
jobs in the JES2 subsystem only. The _mvsMF User's Guide_ (chapter "Submitting
Jobs and Reading Their Output") goes through the tasks with sessions.

Every request needs a user: HTTPD (httpd) resolves the credential, and a
request without one gets the 401 of @ref-conv-401. The job services need no
#cmd("X-CSRF-ZOSMF-HEADER"). @ref-jobs-auth describes which jobs a user sees.

== The Routes <ref-jobs-routes>

#idx("route", "jobs")
#tab(caption: [The routes of the job services])[
  #table(columns: (0.55in, 2.6in, 1fr),
    [Method], [Path], [Function],
    [GET], [#cmd("/zosmf/restjobs/jobs")], [List jobs (@ref-jobs-list).],
    [GET], [#cmd("/zosmf/restjobs/jobs/{job-name}/{jobid}")],
      [The status of one job (@ref-jobs-status).],
    [GET], [#cmd("/zosmf/restjobs/jobs/{job-name}/{jobid}/files")],
      [The output files of one job (@ref-jobs-files).],
    [GET], [#cmd("/zosmf/restjobs/jobs/{job-name}/{jobid}/files/{ddid}/records")],
      [The records of one output file (@ref-jobs-records).],
    [PUT], [#cmd("/zosmf/restjobs/jobs")], [Submit a job (@ref-jobs-submit).],
    [DELETE], [#cmd("/zosmf/restjobs/jobs/{job-name}/{jobid}")],
      [Purge a job (@ref-jobs-purge).],
  )
]

Any other path under #cmd("/zosmf/restjobs") gets the 404 of
@ref-conv-fixed (category 6, rc 4, reason 7, message #cmd("Not Found")). A path
of the table requested with another method gets the 405 of @ref-conv-methods.
@ref-jobs-absent lists the z/OSMF requests that mvsMF does not have.

A path variable ends at a slash, an opening parenthesis or a closing
parenthesis. The router decodes the percent escapes of the path before it
matches the route (@ref-conv-path). The job name of a request is compared
without regard to case. The job ID is compared as it is written, so it must be
in upper case.

== Names and IDs in Answers <ref-jobs-printable>

#idx("job", "printable")
mvsMF writes the job name, the job ID, the owner, the ddname, the step name
and the procedure step name of an answer through a filter. A byte that is not
one of #cmd("A") to #cmd("Z"), #cmd("0") to #cmd("9"), #cmd("$"), #cmd("#") and
#cmd("@") becomes a question mark, and the value is cut at eight characters.

== List Jobs <ref-jobs-list>

#idx("job", "list")#idx("GET")
#cmd("GET /zosmf/restjobs/jobs") answers with a JSON array of job objects
(@ref-jobs-jobobj). The answer is #cmd("[]") with the status 200 when no job
matches.

=== Query Parameters <ref-jobs-listq>

#idx("owner")#idx("prefix")#idx("jobid")#idx("status")#idx("max-jobs")#idx("exec-data")
#tab(caption: [Query parameters of the job list])[
  #table(columns: (1in, 1fr),
    [Parameter], [Meaning],
    [#cmd("owner")], [The owner filter. Without it, or with an empty value,
      the list holds the jobs of the caller. See @ref-jobs-ownerfilter.],
    [#cmd("prefix")], [A job name, or a pattern for it. The value is converted
      to upper case and cut at 11 characters. A star stands for any characters
      and a question mark for one character. A value without either must
      match the whole name. A value that starts with a star is no filter.
      mvsMF ignores #cmd("prefix") when the request has a #cmd("jobid").],
    [#cmd("jobid")], [A job ID, or a pattern for it, with the same rules as
      #cmd("prefix"): upper case, cut at 11 characters, a star for any
      characters and a question mark for one. Unlike #cmd("prefix"), a value
      that starts with a star is a pattern and not an absent filter.],
    [#cmd("status")], [A status as in @ref-jobs-statustab. The value is
      converted to upper case, and the whole text must be equal to the status
      the job reports. A value that starts with a star is no filter.],
    [#cmd("max-jobs")], [The largest number of jobs in the answer. The default
      and the largest value is 1000. A value that is not a number, or is
      zero or negative, gives 1000. A value above 1000 gives 1000. The limit
      counts the jobs that go into the answer. It does not limit the jobs
      that mvsMF looks at.],
    [#cmd("exec-data")], [A value that starts with #cmd("Y") or #cmd("y") adds
      the fields #cmd("exec-system"), #cmd("exec-member"), #cmd("exec-started")
      and #cmd("exec-ended") to every job object.],
  )
]

Every other query parameter is ignored. The list leaves out the entries that
JES2 marks as queue initiators, the jobs named #cmd("SYSLOG") and #cmd("INIT"),
and every job the caller may not see (@ref-jobs-auth).

=== List Errors <ref-jobs-listerr>

#idx("job", "list", "errors")
The list has two errors, both with the status 500:

#tab(caption: [Errors of the job list])[
  #table(columns: (1.9in, 0.4in, 0.4in, 0.35in, 0.45in, 1fr),
    [Condition], [Status], [Cat.], [rc], [Reason], [Message],
    [mvsMF cannot open the JES2 checkpoint and spool data sets], [500], [7],
      [16], [6], [#cmd("Unable to open JES2 checkpoint and spool datasets")],
    [No storage for the answer], [500], [8], [16], [1],
      [#cmd("Internal server error occurred")],
  )
]

The first error is accompanied by the operator message #cmd("MVSMF201E")
(@ref-jobs-msgs). The list answers 200 with #cmd("[]") whenever the JES2
interface returns no job, and mvsMF does not look for the reason. A
storage shortage inside the JES2 interface is therefore not reported as an
error. The data set list answers a storage shortage with a 500 of its own
(@ref-ds).

=== The Job Object <ref-jobs-jobobj>

#idx("job", "object")
The job list, the status request and the answer to a submit use one object.
The fields come in this order:

#tab(caption: [The fields of a job object])[
  #table(columns: (1.15in, 1fr),
    [Field], [Value],
    [#cmd("subsystem")], [#cmd("JES2").],
    [#cmd("jobname")], [The job name.],
    [#cmd("jobid")], [The job ID.],
    [#cmd("owner")], [The user ID of the owner.],
    [#cmd("type")], [The first three characters of the job ID: #cmd("JOB"),
      #cmd("STC") or #cmd("TSU").],
    [#cmd("class")], [The execution class of the job, if it is a letter or a
      digit. Otherwise the first three characters of the job ID.],
    [#cmd("url")], [The URL of the job:
      #cmd("scheme://host/zosmf/restjobs/jobs/name/id"). The scheme is
      #cmd("https") when the request has the header
      #cmd("X-Forwarded-Proto") and its value starts with #cmd("https"),
      followed by the end of the value, a comma or a blank (a chain of proxies
      writes a list, and the first entry counts). Otherwise it is
      #cmd("http"). The host is the value of the #cmd("Host") header, or
      #cmd("127.0.0.1:8080") when the request has none.],
    [#cmd("files-url")], [The #cmd("url") with #cmd("/files") added.],
    [#cmd("status")], [See @ref-jobs-statustab.],
    [#cmd("retcode")], [See @ref-jobs-retcode. #cmd("null") when the job has
      no return code.],
    [#cmd("exec-system")], [With #cmd("exec-data"): the system ID that JES2
      recorded for the job (the SMF ID). MVS 3.8j has no sysplex.],
    [#cmd("exec-member")], [With #cmd("exec-data"): the JES2 member. There is one
      member, so the value is the same as in #cmd("exec-system").],
    [#cmd("exec-started")], [With #cmd("exec-data"): the time the job started,
      in UTC, as #cmd("YYYY-MM-DDTHH:MM:SS.000Z"). #cmd("null") when JES2
      holds no time.],
    [#cmd("exec-ended")], [With #cmd("exec-data"): the time the job ended, in
      the same form.],
  )
]

The object has no field #cmd("exec-submitted"), and no field
#cmd("job-correlator").

=== The Status <ref-jobs-statustab>

#idx("job", "status")
The status of a job is the first of these that applies to the queue flags of
the job:

#tab(caption: [The values of the field status, in the order mvsMF tests them])[
  #table(columns: (1.2in, 1fr),
    [Value], [Condition],
    [#cmd("ACTIVE")], [The job is on the execution queue.],
    [#cmd("INPUT")], [The job is on the input queue.],
    [#cmd("XMIT")], [The job is on the transmit queue.],
    [#cmd("SETUP")], [The job is on the setup queue.],
    [#cmd("RECEIVE")], [The job is on the receive queue.],
    [#cmd("OUTPUT")], [The job is on the output queue or the hardcopy queue.],
    [#cmd("UNKNOWN")], [None of the above.],
  )
]

The queue flags are not exclusive: a job that is on the execution queue and
on the output queue is #cmd("ACTIVE"). The status filter and the field
#cmd("status") use the same function, so a filter never disagrees with the
field.

=== The Return Code <ref-jobs-retcode>

#idx("retcode")#idx("return code")
The field #cmd("retcode") is #cmd("null") for a job that is not on the output
queue or the hardcopy queue. For a job on one of those queues, mvsMF reads the
completion word of the job. The first rule that applies decides:

#tab(caption: [The values of the field retcode])[
  #table(columns: (1.45in, 1fr),
    [Value], [Condition],
    [#cmd("ABEND Sxxx")], [The completion word has the form #cmd("77aaaccc")
      in hexadecimal, and #cmd("aaa"), the system abend code, is not zero.
      #cmd("xxx") is that code in three hexadecimal digits.],
    [#cmd("ABEND Unnnn")], [The same high byte, no system abend, the job flags
      show an abend, and #cmd("ccc") is not zero. #cmd("nnnn") is #cmd("ccc")
      as a decimal number, with four digits.],
    [#cmd("JCL ERROR")], [The same high byte, no abend, and the job flags
      consist of the JCL error bit and nothing else.],
    [#cmd("CC nnnn")], [The same high byte, none of the cases above.
      #cmd("nnnn") is #cmd("ccc") as a decimal number, with four
      digits.],
    [#cmd("JCL ERROR")], [The high byte is not #cmd("77") and the completion
      word is 4, 8 or 36.],
    [#cmd("JCL ERROR")], [The high byte is not #cmd("77"), the word is none of
      those, and the job flags consist of the JCL error bit and nothing else.],
    [#cmd("null")], [None of the above.],
  )
]

== Job Status <ref-jobs-status>

#idx("job", "status")
#cmd("GET /zosmf/restjobs/jobs/{job-name}/{jobid}") answers with the job
object of @ref-jobs-jobobj. The query parameter #cmd("exec-data") applies. The
other parameters of the list do not.

mvsMF looks for the job by its ID in the checkpoint, and then keeps the
entries whose name equals the name of the request without regard to case and
whose ID equals the ID of the request exactly. It answers when exactly one
entry is left and the caller may see it (@ref-jobs-auth). Otherwise it
answers 404 with category 6, rc 4, reason 2 and the message
#cmd("Job 'name(id)' not found"). This one answer covers a job that does not
exist, more than one matching entry,
a job that the caller may not see, and a JES2 checkpoint that mvsMF could not
open. In the last case the operator console gets the message #cmd("MVSMF201E")
(@ref-jobs-msgs). The name and the ID in the message are the values of the
request with each quote, backslash and control character replaced by a question
mark, cut at 64 characters.

The status request does not know who submitted the job, so it cannot take the
user ID of the caller as the owner, as the submit request does
(@ref-jobs-submitresp). While JES2 has not yet written the owner of a job that
was just submitted, the status request answers 404 even to the user who
submitted it. A client that polls right after a submit has to accept a 404 for
the first moments and ask again.

== Output Files of a Job <ref-jobs-files>

#idx("job", "files")#idx("spool")#idx("ddname")
#cmd("GET /zosmf/restjobs/jobs/{job-name}/{jobid}/files") answers with a JSON
array with one object for each output data set of the job, in the order of the
job. It leaves out the data set #cmd("JESINTXT"). The caller needs READ access
(@ref-jobs-auth). A job that is not found is answered as in @ref-jobs-status.
The fields come in this order:

#tab(caption: [The fields of a file object])[
  #table(columns: (1.2in, 1fr),
    [Field], [Value],
    [#cmd("recfm")], [The record format as letters: #cmd("U"), #cmd("F") or
      #cmd("V"), then #cmd("B") for blocked, then #cmd("A") or #cmd("M") for
      the control character type. #cmd("S") follows a #cmd("V") when the
      records are spanned.],
    [#cmd("records-url")], [The URL of the records (@ref-jobs-records), built
      like the #cmd("url") of a job object.],
    [#cmd("subsystem")], [#cmd("JES2").],
    [#cmd("byte-count")], [Always #cmd("null").],
    [#cmd("lrecl")], [The record length, a number.],
    [#cmd("jobid")], [The job ID.],
    [#cmd("ddname")], [The DD name.],
    [#cmd("id")], [The data set ID of JES2, a number. The #cmd("ddid") of the
      records request is this number.],
    [#cmd("record-count")], [The number of records, a number.],
    [#cmd("class")], [The output class, one character.],
    [#cmd("jobname")], [The job name.],
    [#cmd("stepname")], [The step name. #cmd("JES2") when the data set has
      none.],
    [#cmd("procstep")], [The procedure step name, or #cmd("null") when the data
      set has none.],
  )
]

== Records of an Output File <ref-jobs-records>

#idx("job", "records")#idx("spool", "read")#idx("record range")
#cmd("GET /zosmf/restjobs/jobs/{job-name}/{jobid}/files/{ddid}/records")
returns the records of one output file. The caller needs READ access
(@ref-jobs-auth). The path variable #cmd("ddid") is the #cmd("id") of a file
object. mvsMF checks it after it has found the job:

#tab(caption: [Checks of the ddid])[
  #table(columns: (1.9in, 0.5in, 1fr),
    [Condition], [Status], [Answer],
    [Not a whole number, or negative], [400],
      [category 6, rc 8, reason 3, message #cmd("Invalid DDID parameter")],
    [A number that is none of the IDs of the job], [400],
      [category 6, rc 8, reason 3, message #cmd("DDID not found for job")],
  )
]

On success the answer is #cmd("200") with the content type #cmd("text/plain").
Each record is a line: the record at its full length, converted from EBCDIC
(CP037) to ASCII, followed by a carriage return and a line feed. For a file that
is input data (a #cmd("SYSIN") data set) for which JES2 counts a number of
records, mvsMF stops at that number. If JES2 counts none, the file is sent as
it is. In the file #cmd("JESJCLIN") it skips the pointer
records of JES2. mvsMF sends the headers
with the first line. A file with no spool data, or no record, gives #cmd("200")
and an empty body.

#tab(caption: [Answers when no line goes out])[
  #table(columns: (1.5in, 0.5in, 1fr),
    [Condition], [Status], [Answer],
    [JES2 holds records for the file that the spool no longer has], [404],
      [category 6, rc 4, reason 10, message #cmd("Spool output for job 'name(id)' DD id n is no longer on the spool")],
    [The read fails], [500],
      [category 6, rc 8, reason 11, message
      #cmd("Unable to read spool output for job 'name(id)' DD id n: why")],
    [JES2 cannot be opened for the read], [500],
      [category 6, rc 16, reason 6, message
      #cmd("Unable to open JES2 checkpoint and spool datasets")],
  )
]

The text after the colon in the 500 message is one of: #cmd("spool read failed"),
#cmd("JES2 checkpoint or spool data set not available"),
#cmd("first spool block belongs to another data set"),
#cmd("spool block chain loops, output truncated"),
#cmd("spool block limit reached, output truncated"),
#cmd("incomplete spanned record, output truncated"), or
#cmd("out of storage, output truncated").

When a line has gone out, the status 200 is final. A failure after that is
not reported to the client. The client gets the lines that were sent, and
mvsMF writes the message #cmd("MVSMF202W") to the operator console.

The request has no range. mvsMF does not read the header
#cmd("X-IBM-Record-Range") or any other header or query parameter for it. A
request returns the whole file.

== Submit a Job <ref-jobs-submit>

#idx("job", "submit")#idx("PUT")#idx("internal reader")
#cmd("PUT /zosmf/restjobs/jobs") submits JCL to the JES2 internal reader. The
JCL comes from the body, or from a data set that the body names.

=== Request Headers <ref-jobs-submithdr>

#idx("X-IBM-Intrdr-Mode")#idx("X-IBM-Intrdr-Lrecl")#idx("X-IBM-Intrdr-Recfm")#idx("Content-Type")
#tab(caption: [Headers of the submit request])[
  #table(columns: (1.9in, 1fr),
    [Header], [Meaning],
    [#cmd("X-IBM-Intrdr-Mode")], [Optional. The only value is #cmd("TEXT").],
    [#cmd("X-IBM-Intrdr-Lrecl")], [Optional. The only value is #cmd("80").],
    [#cmd("X-IBM-Intrdr-Recfm")], [Optional. The only value is #cmd("F").],
    [#cmd("Content-Type")], [A value that contains #cmd("application/json")
      selects the data set source. A value that contains #cmd("text/plain"),
      or no header, selects inline JCL. Any other value is refused. When the
      value contains both, the data set source is used.],
  )
]

The values of the three #cmd("X-IBM-Intrdr-") headers are compared exactly,
including the case. Another value is refused (@ref-jobs-submiterr). The check
comes before the body is read.

=== Inline JCL <ref-jobs-submittext>

#idx("job", "submit", "inline")
The body is the JCL. mvsMF converts it from ASCII to EBCDIC (CP037) and splits
it into lines at the line ends. It removes a carriage return at the end of a
line and cuts a line at 80 columns. It submits no empty line.

=== Data Set Source <ref-jobs-submitfile>

#idx("job", "submit", "from a data set")#idx("file")
The body is a JSON object with the field #cmd("file"), for example:

#screen(raw("{\"file\":\"//'USER.JCL.LIB(JOB1)'\"}"))

mvsMF finds the text #cmd("\"file\"") in the body, then a colon, then a quoted
string. The value must have the form #cmd("//'name'"), with the data set name
or the data set name and a member in parentheses between the apostrophes. The
data set name has at most 44 characters and the member at most 8, so the text
between the apostrophes has at most 54. A longer name is refused like a value
that is not written in this form. The
body is not parsed as JSON beyond this. The data set is opened with the
rights of the caller, and its lines are read as text: a line is cut at 80
columns and loses its line end.

=== The JOB Statement <ref-jobs-jobcard>

#idx("JOB statement")#idx("USER")#idx("PASSWORD")#idx("NOTIFY")
mvsMF rewrites the JOB statement of the JCL from either source:

+ The JOB statement is the first line that starts with #cmd("//") and has the
  operation #cmd("JOB"), and the continuation lines after it. A line is a
  continuation when the line before it ends with a comma (blanks after the
  comma do not count), it starts with #cmd("//"), it has at least ten
  characters, and its columns 3 to 10 are blank. The job name is columns 3 to
  10 of the first line, up to the first blank. The class is the character
  after the first #cmd("CLASS=") of the first line.
+ mvsMF removes the operands #cmd("USER=") and #cmd("PASSWORD=") from the
  statement. It does this on every line of the statement. A continuation line
  that has nothing left is blanked and not submitted.
+ mvsMF replaces the first #cmd("NOTIFY=&SYSUID") with #cmd("NOTIFY=") and the
  user ID of the caller. The rewritten line, without the trailing blanks, must
  be shorter than 72 columns, or mvsMF refuses the request. It finds a
  #cmd("NOTIFY") only at the start of an operand and outside quotes. Any other
  #cmd("NOTIFY") stays, and its presence stops mvsMF from adding the
  placeholder of step 5.
+ mvsMF makes the last line of the statement continue onto the line of step 5.
  Trailing blanks do not count. A comma is data only up to column 71, because
  column 72 is the continuation column. The length of the line decides:
  - A line that is empty or ends with a comma stays as it is, whatever its
    length.
  - A line that ends in column 70 or earlier gets a comma at its end.
  - A line that ends in column 71 has no room for the comma. mvsMF moves its
    last operand, the text behind the last comma outside quotes and
    parentheses, to a line of its own: #cmd("//") and nine blanks, the operand
    and a comma. The line is inserted behind the last line of the statement, in
    front of the line of step 5. The comma in front of the moved operand ends
    the original line. The operands are the same and in the same order, but the
    JCL does not reach JES2 byte for byte.
  - mvsMF refuses the request when the line has data behind column 71 and no
    comma at its end (columns 73 to 80 count), when a line that ends in column
    71 has no comma outside quotes and parentheses, or when the operand to move
    is longer than 59 characters.

  This step applies to the last line of the statement only, for both sources of
  the JCL.
+ mvsMF inserts one line behind the statement:
  #cmd("//         NOTIFY=$MVSMF,USER=user,PASSWORD=password   GENERATED BY MVSMF").
  The text #cmd("NOTIFY=$MVSMF,") is there only if no #cmd("NOTIFY") was found
  on the statement.
  The comment is #cmd("BY MVSMF") if the line with the comment
  #cmd("GENERATED BY MVSMF") would be longer than 71 columns. If the line with the short comment
  does not fit then either, mvsMF refuses the request.

The refusals of steps 3, 4 and 5 are one error, the 400 of @ref-jobs-submiterr
with the message #cmd("JOB card cannot be continued: no room for the comma that joins it to the NOTIFY, USER and PASSWORD operands mvsMF adds").
The length of the added line follows from its parts. The fixed text is
26 characters: #cmd("//") and nine blanks, #cmd("USER="), and #cmd(",PASSWORD=").
The user ID and the password add their own length. #cmd("NOTIFY=$MVSMF,") adds
14 characters, the long comment 21 and the short comment 11. The line may have
71 characters at most. A user ID and a password of eight characters each (16
together) fit in every case. mvsMF refuses the line only if user ID and
password together exceed 20 characters when it adds a #cmd("NOTIFY"), or 34
when the statement has one.

=== The Answer <ref-jobs-submitresp>

The answer is #cmd("200") and the job object of @ref-jobs-jobobj (not #cmd("201")).
The query parameter #cmd("exec-data") applies. mvsMF looks the job up after the
internal reader is closed. When JES2 has not yet written the owner of the job,
mvsMF writes the user ID of the caller into the #cmd("owner") field. It never
replaces an owner that JES2 wrote. If the lookup finds no job, the answer is the
404 of @ref-jobs-status although the job was submitted. The operator console
gets #cmd("MVSMF203I") for every submitted job.

=== Errors <ref-jobs-submiterr>

#idx("job", "submit", "errors")
#tab(caption: [Errors of the submit request])[
  #table(columns: (1.8in, 0.4in, 0.4in, 0.35in, 0.45in, 1fr),
    [Condition], [Status], [Cat.], [rc], [Reason], [Message],
    [An #cmd("X-IBM-Intrdr-") header has another value], [400], [6], [8], [3],
      [#cmd("Invalid internal reader parameters")],
    [The body cannot be read: the request has no #cmd("Content-Length") and is
      not chunked, the length is malformed, or the client stops sending],
      [400], [6], [8], [4], [#cmd("Failed to read request content")],
    [The body is 16 MB or larger], [413], [6], [8], [0],
      [#cmd("The request body is too large")],
    [No storage for the body], [500], [7], [16], [0],
      [#cmd("Storage for the request body could not be obtained")],
    [Another content type], [400], [6], [8], [4],
      [#cmd("Unsupported Content-Type for job submission. Use application/json or text/plain")],
    [No field #cmd("file"), or an empty one], [400], [6], [8], [7],
      [#cmd("Missing or invalid 'file' field in request body")],
    [The value is not of the form #cmd("//'name'"), the data set name has more than 44 characters, or the member is empty, has more than 8 characters or lacks its closing parenthesis], [400], [6], [8], [8],
      [#cmd("Cannot open dataset: ") and the value],
    [The data set cannot be opened], [404], [6], [8], [8],
      [#cmd("Cannot open dataset: ") and the name],
    [The session has no password], [400], [6], [8], [4],
      [#cmd("Job submission requires an authenticated session with a password")],
    [No JOB statement, inline source], [400], [6], [8], [4],
      [#cmd("No valid JOB card found in submitted JCL")],
    [No JOB statement, data set source], [400], [6], [8], [4],
      [#cmd("No valid JOB card found in dataset")],
    [The JOB statement cannot be continued], [400], [6], [8], [12],
      [#cmd("JOB card cannot be continued: no room for the comma that joins it to the NOTIFY, USER and PASSWORD operands mvsMF adds")],
    [The internal reader cannot be opened], [500], [6], [16], [1],
      [#cmd("Failed to open internal reader")],
    [An uncorrectable error reading the data set; no storage for the lines; a write to the internal reader or its close fails], [500], [8], [16], [1],
      [#cmd("Internal server error occurred")],
  )
]

The operator console gets #cmd("MVSMF204E") when the internal reader cannot
be opened, #cmd("MVSMF205E") when a write fails and #cmd("MVSMF206E") when the
close fails. It gets #cmd("MVSMF006E") when no storage is left for the JCL
lines of a job that is sent in the request (for a data set source the answer
is the same 500, but nothing is written to the console), and #cmd("MVSMF106E") when reading the JCL data set ends in an I/O
error. No line has gone to the internal reader in the second case, and the
request is refused. The failures of the write and of the close happen after the
internal reader has taken cards. The code does not say whether JES2 keeps those
cards as a job.

== Purge a Job <ref-jobs-purge>

#idx("job", "purge")#idx("DELETE")#idx("purge")
#cmd("DELETE /zosmf/restjobs/jobs/{job-name}/{jobid}") purges a job: it
asks JES2 to remove the job and its output. The caller needs UPDATE-level access
(@ref-jobs-auth). The request has no body. mvsMF looks the job up as for the
status, and it purges the job by the name and the ID that the lookup found,
not by the spelling of the path.

#tab(caption: [Answers of the purge request])[
  #table(columns: (1.6in, 0.4in, 0.4in, 0.35in, 0.45in, 1fr),
    [Condition], [Status], [Cat.], [rc], [Reason], [Message],
    [The job was purged], [200], [], [], [], [#cmd("Request was successful.") in
      the object below.],
    [JES2 took the purge and the job is still on the queue], [200], [], [], [],
      [#cmd("Purge requested. JES2 keeps the job marked for purge until the output it holds is released.")
      in the object below (@ref-jobs-purge-pending).],
    [No such job, or the caller may not see it], [404], [6], [4], [2],
      [#cmd("Job 'name(id)' not found")],
    [The job vanished between the lookup and the purge], [404], [6], [4], [2],
      [The same message.],
    [The job is a started task], [400], [6], [4], [5],
      [#cmd("Cannot purge a started task")],
    [The caller may read the job and has no right to purge it], [500], [4], [8],
      [0], [#cmd("LMOPEN error"), and #cmd("details") with the sentence
      #cmd("Authorization failed - You may not purge this job.")],
    [The purge function returns a code mvsMF does not know], [500], [8], [16],
      [1], [#cmd("Internal server error occurred")],
  )
]

The answer to a purge is the object:

#screen(raw("{\"jobid\":\"JOB00123\",\"message\":\"Request was successful.\",\"original-jobid\":\"JOB00123\",\"jobname\":\"MYJOB\",\"owner\":\"USER\",\"status\":0}"))

The fields come in this order. #cmd("jobid") and #cmd("original-jobid") are the
same value. #cmd("status") is the number 0. mvsMF writes the message
#cmd("MVSMF207E") for a code it does not know.

*Change from mvsMF 1.3.0:* the answer 200 says that JES2 took the request, not
that the job is gone. When a device has selected the output of the job, JES2
marks the job for purge and keeps it on the queue until the output is released.
After JES2 took the request, mvsMF looks up the job on the queue again, up to
five times with a pause of 0.2 seconds between the looks, and stops at the
first look that does not find it. If the job is gone, the answer is the object
above. If the job is still there, the status stays 200 and #cmd("status") stays
0, and #cmd("message") reads #cmd("Purge requested. JES2 keeps the job marked
for purge until the output it holds is released."). The looks cost nothing when
the purge completes at once and about a second when the job stays.

The code does not treat a running job differently from a job on the output
queue: the same purge function is called with the same flag.

=== A Purge That Is Only Requested <ref-jobs-purge-pending>

#idx("job", "purge", "requested only")#idx("purge", "output held by a device")
The purge function of JES2 returns the code for success when JES2 has taken the
request. That code does not say that the job has left the queue. A job whose
output a device has selected stays on the queue, marked for purge, until the
device releases the output. The case that was measured is a punch that has
selected the output and halts to wait for setup (the User's Guide, section "A
Purge That Is Only Requested").

mvsMF therefore looks at the queue again after JES2 has accepted the request.
The look is the lookup of the status request, with the same decision of the
class #cmd("JESSPOOL") that the purge used (@ref-jobs-auth), for the name and
the ID that the first lookup found. The rules:

- mvsMF looks at most five times. Between two looks it waits 0.2 seconds, so
  the pauses add up to 0.8 seconds at most. The lookups themselves take time
  too.
- It stops at the first look that finds no job. The message is then
  #cmd("Request was successful.")
- If all five looks find the job, the message is
  #cmd("Purge requested. JES2 keeps the job marked for purge until the output it holds is released.")
  Both messages end with a period.
- Everything else in the object is as for a purge that is complete. The status
  is 200 and #cmd("status") is 0 in both cases. mvsMF sends no other status for
  the pending purge.
- mvsMF does not know why the job stays. It sees only that the job is still
  listed after the last look. The answer does not say what holds the job.
- The check is made only for an answer that would be 200. A purge that is
  refused, or of a job that is not found, has no wait.

A second DELETE for the job, while it is still on the queue, takes the same
path and gets the same answer. The status request answers 200 for the job as
long as it is on the queue. After the output is released the job is not found,
and every request for it gets the 404 of @ref-jobs-purge.

== Requests That mvsMF Does Not Have <ref-jobs-absent>

#idx("job", "cancel")#idx("job", "hold")#idx("job", "release")
These requests of the z/OSMF jobs service are not in mvsMF. The routes do not
exist. A request for a path that no route serves gets the 404 of
@ref-conv-fixed, and a request for a path that another route serves, with a
method that route does not offer (the PUT on a job, for example), gets the 405
of @ref-conv-methods:

- the PUT request on a job that carries a JSON body with the field
  #cmd("request") to cancel, hold or release the job (and the class change
  and the status request that go with it),
- a route that returns the JCL of a job,
- a route that returns all files of a job in one answer,
- a record range for the records request (@ref-jobs-records),
- a query parameter for the #cmd("user-correlator").

== Job Authorization <ref-jobs-auth>

#idx("JESSPOOL")#idx("job", "authorization")#idx("authorization", "jobs")
mvsMF 1.4.0 decides for every job whether the caller may see it, read it or
purge it. The decision uses the RACF class #cmd("JESSPOOL") (RAKF). The rules are in the module that decides, which
has no MVS headers and also runs on the host in the tests. The test endpoint
(@ref-test) of a development build applies the same policy.

=== The Entity <ref-jobs-auth-entity>

#idx("JESSPOOL", "entity")
The entity of a job is #cmd("owner.jobname.jobid"). Each component is one to
eight characters from #cmd("A") to #cmd("Z"), #cmd("0") to #cmd("9"),
#cmd("$"), #cmd("#") and #cmd("@"). Only the owner may be empty: a job without
an owner has the entity #cmd(".jobname.jobid"). A job with any other component
that is empty, longer than eight characters or has another character is
hidden.

mvsMF asks RAKF in the class #cmd("JESSPOOL") with the entity. It asks once for
READ. For a purge it asks a second time for UPDATE. The answers are used in
the order of @ref-jobs-auth-decision.

=== The Decision <ref-jobs-auth-decision>

#idx("JESSPOOL", "decision")
mvsMF applies these rules in this order and stops at the first that applies:

#tab(caption: [The rules, in order])[
  #table(columns: (0.3in, 2.1in, 1fr),
    [No.], [Condition], [Result],
    [1], [The request has no ACEE or no user ID.], [Hidden, also for the
      own jobs.],
    [2], [The owner of the job equals the user ID of the caller as a whole,
      and contains no blank and no control character.], [Allowed to read and
      to purge. mvsMF asks RAKF nothing. The owner #cmd("MIKE1") is not the
      user #cmd("MIKE10").],
    [3], [A component of the entity is invalid (@ref-jobs-auth-entity).],
      [Hidden.],
    [4], [RAKF returns 4 for the READ request (no profile covers the entity).],
      [Hidden.],
    [5], [RAKF returns 8 for the READ request, or any value other than 0 and
      4.], [Hidden.],
    [6], [For any request other than a purge: RAKF returns 0 for READ.],
      [Allowed.],
    [7], [For a purge: RAKF returns 0 for READ, and 0 for UPDATE.],
      [Allowed to purge (UPDATE, CONTROL and ALTER all give it).],
    [8], [For a purge: RAKF returns 0 for READ, and 8 for UPDATE.],
      [Visible, but not allowed to purge. The purge is refused with the 500
      of @ref-jobs-purge.],
    [9], [For a purge: RAKF returns 0 for READ, and any other value for
      UPDATE.], [Hidden.],
  )
]

mvsMF calls the RACF interface itself and does not use the HTTPD helper
#cmd("http_check_auth"), because that helper turns the return code 4 into 0.
Here 4 means that no profile covers the entity, and the job stays hidden.

The decision is made by the operation that the request needs:

#tab(caption: [What each request needs])[
  #table(columns: (1.9in, 1fr),
    [Request], [Needs],
    [List jobs], [READ for every job in the list. A job that fails the rule is
      left out.],
    [Job status], [READ.],
    [List files, read records], [READ.],
    [Submit], [READ for the lookup of the new job. The owner of the new job is
      the caller.],
    [Purge], [UPDATE-level access. READ alone gives the 500 category 4.],
  )
]

A hidden job gets, in every request, the answer that a job gets that does not
exist: the 404 with reason 2 (the list leaves it out). The answer does not tell
the caller whether the job exists.

=== The Owner Filter <ref-jobs-ownerfilter>

#idx("owner")#idx("owner=*")#idx("JESSPOOL", "owner filter")
The query parameter #cmd("owner") of the list is read before the spool. mvsMF
converts the value to upper case. The result is one of:

#tab(caption: [How mvsMF reads the parameter owner])[
  #table(columns: (1.9in, 1fr),
    [Value], [Effect],
    [Not given, empty, or the user ID of the caller], [The list holds the jobs
      of the caller.],
    [A star], [If RAKF gives READ for the probe #cmd("..") (below), all owners.
      Otherwise the jobs of the caller. There is no error.],
    [The user ID of another user], [If RAKF gives READ for the probe
      #cmd("userid.."), the jobs of that owner. Otherwise the list is
      #cmd("[]") with the status 200.],
    [A pattern, a value of more than eight characters, or a value with a
      character outside #cmd("A") to #cmd("Z"), #cmd("0") to #cmd("9"),
      #cmd("$"), #cmd("#") and #cmd("@")], [The list is #cmd("[]").],
  )
]

The owner is compared as a whole against the owner of the job. A job without an
owner matches only the star. A star does not skip the check of the single job:
mvsMF applies the rules of @ref-jobs-auth-decision to every job it lists.

The probes are two entities that stand for the question "may the caller list
this owner at all": #cmd("userid..") for one owner and #cmd("..") for all owners.
The probe is a READ request in the class #cmd("JESSPOOL"), and it has no cache.
A probe needs an ACEE. Without one, the answer is no.

=== The Cache <ref-jobs-auth-cache>

#idx("JESSPOOL", "cache")
mvsMF keeps the answers of RAKF for the duration of one request. The cache
holds 16 keys. The key is the first eight characters of the entity, which is
what RAKF compares, and the question (READ, or READ and UPDATE for a purge).
A seventeenth key is not stored, and mvsMF asks RAKF each time for it. An
answer that is none of the return codes 0, 4 and 8 is not stored either. The
cache is gone when the request ends.

=== The Answers of a Refusal <ref-jobs-auth-answers>

#tab(caption: [Answers of the authorization])[
  #table(columns: (2.2in, 0.45in, 1fr),
    [Case], [Status], [Answer],
    [Hidden job: status, files, records, purge], [404],
      [category 6, rc 4, reason 2, message #cmd("Job 'name(id)' not found")],
    [Hidden job in the list], [200], [The job is not in the array.],
    [An owner the caller may not list], [200], [#cmd("[]")],
    [#cmd("owner=*") without the right], [200], [The jobs of the caller.],
    [Purge of a visible job without UPDATE], [500],
      [category 4, rc 8, reason 0, message #cmd("LMOPEN error"), details
      #cmd("Authorization failed - You may not purge this job.")],
  )
]

== Operator Messages <ref-jobs-msgs>

#idx("operator messages", "jobs")
The job services write these messages to the operator console. @apx-messages
has the texts and the actions.

#tab(caption: [Operator messages of the job services])[
  #table(columns: (1in, 1fr),
    [Message], [When],
    [#cmd("MVSMF201E")], [mvsMF cannot open the JES2 checkpoint and spool data
      sets.],
    [#cmd("MVSMF202W")], [A walk of the spool ended early after the first line
      was sent.],
    [#cmd("MVSMF203I")], [A job entered the system through mvsMF.],
    [#cmd("MVSMF204E")], [The internal reader cannot be opened.],
    [#cmd("MVSMF205E")], [A write to the internal reader failed.],
    [#cmd("MVSMF206E")], [The close of the internal reader failed.],
    [#cmd("MVSMF207E")], [The purge function returned a code mvsMF does not
      know.],
  )
]

== Change from mvsMF 1.3.0 <ref-jobs-change>

#idx("job", "change from 1.3.0")
#tab(caption: [Changes in the job services of mvsMF 1.4.0])[
  #table(columns: (1.6in, 1fr),
    [Subject], [Change],
    [Authorization], [1.3.0 let every authenticated user list, read and
      purge the jobs of every owner. 1.4.0 applies @ref-jobs-auth. Without
      JESSPOOL profiles every user sees only the own jobs.],
    [Owner filter], [In 1.3.0 the value of #cmd("owner") was compared with the
      owner only up to the shorter of the two lengths, so a short value matched
      every owner that begins with it. In 1.4.0 it is compared as a whole. #cmd("owner=*") lists
      the own jobs unless a profile gives READ for the probe #cmd("..").],
    [Hidden jobs], [They get the 404 of a missing job (new).],
    [Purge], [A purge by a caller with READ access and no UPDATE access gets the
      500 of category 4 (new).],
    [The JCL of a submit], [The password of the caller is on the added card
      (unchanged).],
    [DD statements], [With libc370 2.24 the job services open the JES2
      checkpoint as #cmd("SYS1.HASPCKPT") and the spool as
      #cmd("SYS1.HASPACE") when the procedure of HTTPD has no #cmd("HASPCKPT")
      and no #cmd("HASPACE1") DD statement. A DD statement is used when there
      is one, and a system whose JES2 prefix is not #cmd("SYS1") needs the
      statement #cmd("HASPCKPT").],
  )
]
