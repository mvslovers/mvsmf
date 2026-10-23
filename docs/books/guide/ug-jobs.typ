#import "../bookmaster/bookmaster.typ": *

= Submitting Jobs and Reading Their Output <ug-jobs>

#idx("job")#idx("JES2")#idx("restjobs")
Besides data sets and files, mvsMF (mvsmf) gives a client the jobs of JES2. The
jobs service lives under the path #cmd("/zosmf/restjobs/jobs"). A client submits
a job, lists the jobs, asks for the status and the return code of a job, reads
its output, and purges it. This chapter goes through these tasks, one session
for each. The sessions run in order on one system, and they depend on each
other: the first one submits a job, and the following ones find it, read it
and purge it. The _mvsMF Reference_ (chapter "Job Services") lists every
parameter, header, field, status code and error report.

A user works on the own jobs. The jobs of other users stay hidden, unless the
administrator allows them with a profile in the RAKF class #cmd("JESSPOOL")
(@ug-jobs-others). Before mvsMF 1.4.0 every user could list, read and purge the
jobs of everybody (@ug-jobs-change).

== Before You Start <ug-jobs-before>

#idx("job", "prerequisites")#idx("password")#idx("Basic authentication")
The sessions use curl with Basic authentication and the variables
#var("MVSMF_URL"), #var("MVSMF_USER") and #var("MVSMF_PASS"). The user ID needs
a password, and a session that logged on with a token alone is not enough:
mvsMF runs every job it submits under the identity of the user, and for that it
writes the password of the user on the JOB statement (@ug-jobs-jobcard). A
request to submit a job from a session without a password is refused
(@ug-jobs-submit-fail).

The jobs of the sessions have the names #cmd("MVSMFDM1") to #cmd("MVSMFDM5"). They
run in the class #cmd("A") and send their output to the class #cmd("H"). The
output of a job can be read only as long as it is on the spool, so the
installation must keep the class #cmd("H"). An output class that the system
purges at once leaves nothing to read.

Two variables are set from the answers of earlier sessions. #var("JOBID") is the
job ID that the first session prints, and #var("DDID") is the ID of an output
file of that job (@ug-jobs-files). Set them by hand when you follow the
sessions, for example #cmd("JOBID=JOB00123"). Their values differ from run to
run.

The job ID has the form #cmd("JOB"), #cmd("STC") or #cmd("TSU") and five digits,
and it is in upper case. mvsMF compares the job ID of a request as it is
written, and it compares the job name without regard to case.

== Submitting a Job <ug-jobs-submit>

#idx("job", "submit")#idx("internal reader")#idx("PUT")#idx("submit")
A PUT request to #cmd("MVSMF_URL/zosmf/restjobs/jobs") submits a job. The body is
the JCL, and the header #cmd("Content-Type: text/plain") says so. The first
session submits a job that copies three lines of input to its output. curl reads
the JCL from the lines after the command:

#screen(raw(read("../ex/ug-jobs/j-submit.txt"), block: true))

The answer is #cmd("200") and the JSON object of the job, with the name, the ID
and the owner of the job, the URLs of the job and of its files, and the status
(@ug-jobs-status). The job ID of the answer is the one the following sessions
use. Set #var("JOBID") to it. The field #cmd("retcode") is #cmd("null") as long as
the job has not ended.

mvsMF writes the JCL to the JES2 internal reader. It reads the body as ASCII
text and converts it to EBCDIC (CP037). A line of the JCL is one card of 80
columns: a longer line is cut at column 80, a carriage return at the end of a
line is removed, and an empty line is not submitted. Send the JCL as text.

Three headers describe the internal reader in z/OSMF. A client may send them,
and mvsMF accepts exactly one value for each: #cmd("X-IBM-Intrdr-Mode: TEXT"),
#cmd("X-IBM-Intrdr-Lrecl: 80") and #cmd("X-IBM-Intrdr-Recfm: F"). Any other value
is refused with the answer 400 (@ug-jobs-submit-fail). A request without these
headers is accepted. mvsMF needs no #cmd("X-CSRF-ZOSMF-HEADER").

=== Submitting from a Data Set <ug-jobs-submit-ds>

#idx("job", "submit", "from a data set")#idx("file source")
The JCL can come from a data set or from a member of a partitioned data set. The
body is then a JSON object with the field #cmd("file"), and the header is
#cmd("Content-Type: application/json"). The value of the field names the data
set between two apostrophes, and two slashes come before the first apostrophe.
The next session submits the member #cmd("JOB2") of the data set
#cmd("MVSMF_USER.MVSMF.DEMOJCL"). The member holds the JCL of a job named
#cmd("MVSMFDM2"). Write it beforehand with the data set services (@ug-data):

#screen(raw(read("../ex/ug-jobs/j-submit-ds.txt"), block: true))

The answer is the same JSON object as for a JCL body. Its job name is the one of
the JOB statement in the member.

The slashes and the apostrophes are part of the value. The shell expands
#var("MVSMF_USER") in the example, because the here-document is not quoted. mvsMF
opens the data set with the rights of the user, so the user needs read access
to it. The same rules for the cards apply as for the JCL in the body. A data set
that cannot be opened is answered with 404 (@ug-jobs-submit-fail).

=== What mvsMF Does to the JOB Statement <ug-jobs-jobcard>

#idx("JOB statement")#idx("NOTIFY")#idx("USER")#idx("PASSWORD")#idx("job", "owner")
mvsMF changes the JOB statement before it hands the JCL to JES2, so that the job
runs under the identity of the user who submitted it. The JOB statement is the
first card with the word #cmd("JOB") in the operation field, and its
continuation cards. mvsMF takes the job name from columns 3 to 10 of the first
card and the class from the operand #cmd("CLASS="). Then it:

- removes #cmd("USER=") and #cmd("PASSWORD=") operands that the statement carries.
  The job always runs as the user of the request\;
- replaces #cmd("NOTIFY=&SYSUID") with #cmd("NOTIFY=") and the user ID of the
  request. Any other #cmd("NOTIFY") stays as it is\;
- adds a comma to the end of the last card of the JOB statement\;
- inserts one more card behind the JOB statement. The card carries
  #cmd("NOTIFY=$MVSMF,") (only if the JOB statement has no #cmd("NOTIFY")), then
  #cmd("USER=") with the user ID and #cmd("PASSWORD=") with the password of the
  request, and the comment #cmd("GENERATED BY MVSMF"). The comment reads
  #cmd("BY MVSMF") when the long form does not fit into the card.

The job from the first session reaches JES2 in this form:

#screen(```
//MVSMFDM1 JOB (ACCT),'MVSMF DEMO',CLASS=A,MSGCLASS=H,
//         NOTIFY=$MVSMF,USER=userid,PASSWORD=password   GENERATED BY MVSMF
//STEP1    EXEC PGM=IEBGENER
```)

#note[*The password is on the JOB statement.* The card that mvsMF adds carries
the password of the user. The file #cmd("JESJCL") of the job holds the JCL
that JES2 read, and that includes the card. This book shows no session of that
file, so it does not say whether JES2 masks the password there. Treat the
file #cmd("JESJCL") of every job that you submitted through mvsMF as a file that
holds a password, and do not copy it to a place that others read. The sessions
of this chapter read no #cmd("JESJCL").]

The statement must have room for the changes. mvsMF refuses the request in
these cases (@ug-jobs-submit-fail):

- The last card of the JOB statement has 70 or more characters, not counting
  the blanks at its end, and does not end with a comma. There is no room for the
  comma;
- a card with #cmd("NOTIFY=&SYSUID") is 72 characters or longer after mvsMF has
  put the user ID in;
- the card that mvsMF adds does not fit even with the short comment. It fits for
  a user ID and a password of eight characters each.

The answer is 400, with the category 6 and the reason 12. A JCL stream without a
JOB statement is refused as well, with the reason 4. The next session sends a
card that is no JOB statement:

#screen(raw(read("../ex/ug-jobs/j-submit-nocard.txt"), block: true))

=== When a Submit Fails <ug-jobs-submit-fail>

#idx("job", "submit", "errors")
The answer to a refused request is a JSON error report and a status (@ug-errors).
The cases of the submit request are:

#tab(caption: [Refused requests to submit a job])[
  #table(columns: (1.9in, 0.55in, 1fr),
    [Cause], [Status], [Message],
    [One of the three #cmd("X-IBM-Intrdr-") headers has another value],
      [400], [#cmd("Invalid internal reader parameters")],
    [Another #cmd("Content-Type")],
      [400], [#cmd("Unsupported Content-Type for job submission. Use application/json or text/plain")],
    [The session has no password],
      [400], [#cmd("Job submission requires an authenticated session with a password")],
    [No JOB statement],
      [400], [#cmd("No valid JOB card found in submitted JCL"), or
        #cmd("No valid JOB card found in dataset") when the JCL comes from a data set],
    [The JOB statement has no room for the added card],
      [400], [#cmd("JOB card too long: no room left for the NOTIFY, USER and PASSWORD operands mvsMF adds")],
    [JSON without a usable #cmd("file") field],
      [400], [#cmd("Missing or invalid 'file' field in request body")],
    [A #cmd("file") value that is not of the form #cmd("//'name'")],
      [400], [#cmd("Cannot open dataset:") and the value],
    [The data set cannot be opened],
      [404], [#cmd("Cannot open dataset:") and the name],
    [The body is 16 MB or larger],
      [413], [#cmd("The request body is too large")],
  )
]

The _mvsMF Reference_ lists the reason code of each case. Nothing is submitted
in any of these cases.

== Finding a Job <ug-jobs-find>

#idx("job", "list")#idx("owner")#idx("prefix")#idx("max-jobs")#idx("status")
A GET request to #cmd("MVSMF_URL/zosmf/restjobs/jobs") lists jobs. Without a query
parameter it lists the jobs of the user. The answer is a JSON array with one
object for each job, and an array with no element, #cmd("[]"), when no job
matches. The next session lists the jobs of the sessions by their name. The
quotes keep the shell from expanding the star:

#screen(raw(read("../ex/ug-jobs/j-list.txt"), block: true))

Each object has the name, the ID and the owner of the job, its type and class,
the URL of the job and of its files, the status and the return code. The
sessions of this chapter use these query parameters:

#deflist(width: 1.35in,
  [#cmd("prefix")], [A job name or a pattern for the job name. A star stands for
    any characters and a question mark for one character. A name with no star
    or question mark must match exactly. The case does not matter. The value
    is cut at 11 characters. A value that begins with a star is ignored, and the
    list is not narrowed by the name.],
  [#cmd("status")], [One of #cmd("ACTIVE"), #cmd("INPUT"), #cmd("OUTPUT"),
    #cmd("XMIT"), #cmd("SETUP"), #cmd("RECEIVE") (@ug-jobs-status). The case
    does not matter, and the whole word must match. A value that begins with a
    star is ignored.],
  [#cmd("max-jobs")], [The largest number of jobs in the answer. The default and
    the largest value is 1000.],
  [#cmd("jobid")], [One job ID. mvsMF ignores #cmd("prefix") when the request has a
    #cmd("jobid").],
  [#cmd("owner")], [The owner of the jobs (@ug-jobs-others).],
)

The next session asks for the jobs that have ended, and for one job at most:

#screen(raw(read("../ex/ug-jobs/j-list-filter.txt"), block: true))

The parameter #cmd("max-jobs") limits the jobs in the answer, not the jobs that
mvsMF looks at. A request for one job by its ID needs no name:

#screen(raw(read("../ex/ug-jobs/j-list-id.txt"), block: true))

mvsMF leaves out of the list the entries that JES2 flags as queue initiators
and the entries named #cmd("SYSLOG") and #cmd("INIT"). It also leaves out every
job that the user may not see (@ug-jobs-others), and these do not count against
#cmd("max-jobs").

If mvsMF cannot open the JES2 checkpoint and spool data sets, the answer is 500
with the message #cmd("Unable to open JES2 checkpoint and spool datasets"), and
the operator console gets the message #cmd("MVSMF201E").

== Status and Return Code <ug-jobs-status>

#idx("job", "status")#idx("return code")#idx("retcode")#idx("abend")
A GET request to #cmd("MVSMF_URL/zosmf/restjobs/jobs/name/id") returns the object
of one job. The job object is the same as an element of the list:

#screen(raw(read("../ex/ug-jobs/j-status.txt"), block: true))

The field #cmd("status") says where the job is in JES2. mvsMF reports one of
#cmd("ACTIVE") (the job runs), #cmd("INPUT") (it waits to run), #cmd("XMIT"),
#cmd("SETUP"), #cmd("RECEIVE"), #cmd("OUTPUT") (the job has ended and its output
is on the spool), or #cmd("UNKNOWN").

The field #cmd("retcode") has a value for a job that is on the output queue. It
is #cmd("null") before. A job that is still #cmd("ACTIVE") and already on the
output queue reports #cmd("ACTIVE") with a value. The value is a text:

#tab(caption: [The values of the field retcode])[
  #table(columns: (1.3in, 1fr),
    [Value], [Meaning],
    [#cmd("CC 0000")], [The job ended. The number is the completion code of the
      job, with four digits.],
    [#cmd("ABEND S806")], [The job ended with a system abend. The text after
      #cmd("S") is the abend code, three hexadecimal digits.],
    [#cmd("ABEND U0123")], [The job ended with a user abend. The text after
      #cmd("U") is the abend code, four decimal digits.],
    [#cmd("JCL ERROR")], [The job did not run, or ended before a step produced a
      code, because of an error in its JCL.],
    [#cmd("null")], [The job is not on the output queue, or JES2 holds no
      completion code for it.],
  )
]

A request with the query parameter #cmd("exec-data=Y") adds two fields to the
object: #cmd("exec-started") and #cmd("exec-ended"). Each is a time in UTC,
in the form #cmd("2026-01-31T12:00:00.000Z"), or #cmd("null") when JES2 holds no
time. Any value that starts with #cmd("Y") or #cmd("y") switches the fields on.

#screen(raw(read("../ex/ug-jobs/j-status-exec.txt"), block: true))

The next two sessions ask for a job that ended with a system abend (the program
#cmd("NOSUCHPG") does not exist, and the system ends the job with the abend
#cmd("S806")) and for a job that ended with a JCL error (the
word #cmd("EXECC") is misspelled). The jobs were submitted out of sight, with
the same request as the first job:

#screen(raw(read("../ex/ug-jobs/j-rc-abend.txt"), block: true))
#screen(raw(read("../ex/ug-jobs/j-rc-jclerr.txt"), block: true))

A job that was submitted a moment ago can get a 404 here, even for the user who
submitted it, until JES2 has written the owner of the job. Ask again after a
moment. A job that JES2 does not know gets the answer 404 and an error report. The
answer is the same for a job the user may not see, so that it does not tell a
user whether a job of somebody else exists (@ug-jobs-others):

#screen(raw(read("../ex/ug-jobs/j-status-none.txt"), block: true))

The message names the job as the request wrote it. mvsMF replaces a quote,
a backslash and a control character in the name and the ID with a question
mark, and cuts both at 64 characters.

== Reading the Output of a Job <ug-jobs-output>

#idx("job", "output")#idx("spool")#idx("files")#idx("records")
A job has several output files: one for each output data set of its steps, and
the files that JES2 writes for the job, such as the job log, the JCL and the
system messages. A client lists the files of a job, then reads them one at a
time.

=== Listing the Files of a Job <ug-jobs-files>

#idx("job", "files")#idx("ddname")
A GET request to #cmd("MVSMF_URL/zosmf/restjobs/jobs/name/id/files") lists the
files:

#screen(raw(read("../ex/ug-jobs/j-files.txt"), block: true))

The answer is a JSON array with one object for each file. The object has,
among others, the field #cmd("ddname"), the field #cmd("id") (the number of the
file that the next request needs), the field #cmd("stepname") and the number
of records in #cmd("record-count"). The field #cmd("records-url") is the URL
that reads the file. Take the number from the list and do not assume one:
the numbers differ from job to job. mvsMF leaves the input file
#cmd("JESINTXT") out of the list. The session sets #var("DDID") to the
#cmd("id") of the file with the #cmd("ddname") #cmd("SYSUT2"), which holds the
copied lines.

=== Reading One File <ug-jobs-read>

#idx("job", "output", "read")#idx("records")
A GET request to #cmd("MVSMF_URL/zosmf/restjobs/jobs/name/id/files/ddid/records")
returns the file as text:

#screen(raw(read("../ex/ug-jobs/j-read.txt"), block: true))

The answer is plain text: each record is a line of its full length, converted
from EBCDIC (CP037) to ASCII, with a carriage return and a line feed at the
end. A file that holds no data gives the answer 200 with an empty body.

A request for an output file that the job does not have gets the answer 400:

#screen(raw(read("../ex/ug-jobs/j-read-bad.txt"), block: true))

The file number must be a whole number. A value that is not a number, or is
negative, gets the answer 400 with the message #cmd("Invalid DDID parameter"). A
number that is none of the ids of the job gets the answer 400 with
#cmd("DDID not found for job"), as the session shows. A job that does not exist
gets the 404 of @ug-jobs-status.

If the output of the file is no longer on the spool, the answer is 404 with the
message #cmd("Spool output for job 'name(id)' DD id n is no longer on the spool").
If mvsMF cannot read the spool, the answer is 500 (@ug-jobs-readerr).

=== Reading All Files <ug-jobs-readall>

#idx("job", "output", "all files")
mvsMF has no request that returns every file of a job in one answer. A client
reads the list and then each file. The next session does this with a small
shell loop. It leaves out every file whose name starts with #cmd("JESJCL"),
that is #cmd("JESJCL") and also #cmd("JESJCLIN") (file 1). The file
#cmd("JESJCL") holds the password of the user (@ug-jobs-jobcard). The loop
reads the job log (file 2), the system messages (file 4) and the three files of
the step (101, 102 and 103):

#screen(raw(read("../ex/ug-jobs/j-read-all.txt"), block: true))

The line that begins with #cmd("===") comes from the loop, and mvsMF does not
write it.

=== Reading a Range of Records <ug-jobs-range>

#idx("record range")#idx("X-IBM-Record-Range")
mvsMF does not read a range of records. It does not evaluate the header
#cmd("X-IBM-Record-Range"), and the answer to a request with the header is the
whole file:

#screen(raw(read("../ex/ug-jobs/j-range-header.txt"), block: true))

A client that needs a part of the file cuts it from the answer. The next session
shows the second and the third record. The cut is done by the command
#cmd("sed") on the client, after the whole file has come:

#screen(raw(read("../ex/ug-jobs/j-range.txt"), block: true))

=== When the Output Cannot Be Read <ug-jobs-readerr>

#idx("job", "output", "errors")
When the read of the spool fails before mvsMF has sent a line, the answer is 500
with a message that starts with #cmd("Unable to read spool output for job") and
ends with the reason, such as #cmd("spool read failed") or
#cmd("JES2 checkpoint or spool data set not available"). When the failure comes
after mvsMF has sent the first line, the status line and the headers are gone,
and the client receives the part that was sent. mvsMF writes the message
#cmd("MVSMF202W") to the operator console in that case. A client that reads a
job must check that it has received all of the lines it expects.

== Cancelling and Purging a Job <ug-jobs-purge>

#idx("job", "purge")#idx("job", "cancel")#idx("DELETE")#idx("purge")
mvsMF offers one request to end a job: DELETE. It purges the job. mvsMF has no
request to cancel a job and keep its output, and none to hold or release one.
The z/OSMF request for this is a PUT on the job with a JSON body that names the
request. mvsMF answers it as it answers any unknown route, with 404:

#screen(raw(read("../ex/ug-jobs/j-cancel.txt"), block: true))

A DELETE request to #cmd("MVSMF_URL/zosmf/restjobs/jobs/name/id") purges the job:

#screen(raw(read("../ex/ug-jobs/j-purge.txt"), block: true))

The answer is 200 and an object with the ID, the name and the owner of the job,
the message #cmd("Request was successful.") and the field #cmd("status") with
the value 0. That message says that the job is gone. A 200 with another message
says that JES2 took the request and the job is still on the queue
(@ug-jobs-purge-pending). The same request again finds no job:

#screen(raw(read("../ex/ug-jobs/j-purge-again.txt"), block: true))

The answer 200 says that JES2 took the request. If a device has selected the
output of the job, for example a punch that waits for its forms, JES2 keeps the
job on the queue, marked for purge, until the output is released. mvsMF looks
at the queue for about a second after the request. If the job is still there,
the answer is still 200, and the field #cmd("message") says
#cmd("Purge requested. JES2 keeps the job marked for purge until the output it holds is released.")
instead. A client that must know that the spool is free reads the message or
lists the job again. This book has no session for it.

A started task cannot be purged. The answer is 400 with the message
#cmd("Cannot purge a started task"). A user who may see a job of another user
but has no right to purge it gets the answer 500 with the text
#cmd("Authorization failed - You may not purge this job.") in the field
#cmd("details") (@ug-jobs-others).

== A Purge That Is Only Requested <ug-jobs-purge-pending>

#idx("job", "purge", "requested only")#idx("purge", "output held by a device")
The answer 200 to a DELETE says that JES2 took the purge request. It does not
always say that the job has left the queue. When a device has selected the
output of the job, JES2 marks the job for purge and keeps it on the queue until
the device lets the output go.

After JES2 has taken the request, mvsMF looks at the queue again. It looks up
to five times, 0.2 seconds apart, and stops at the first look that no longer
finds the job. The message of the answer depends on the result:

- A look finds no job: the message is #cmd("Request was successful.")
- All five looks find the job: the message is
  #cmd("Purge requested. JES2 keeps the job marked for purge until the output it holds is released.")

The status is 200 and the field #cmd("status") is 0 in both cases. Only the
message differs. The answer with the second message arrives about a second
later than the other, because of the pauses between the looks.

The session below makes this happen on purpose. The job #cmd("MVSMFDM6") sends
its output to the class #cmd("B") and asks for the forms #cmd("ZMF1"). The
punch #cmd("PUNCH1") has other forms. It selects the output and halts to wait
for setup:

#screen(raw(read("../ex/ug-jobs/j-held-submit.txt"), block: true))

Set #var("HJOB") to the job ID of the answer. The console service
(@ug-console) shows the state of the device. The job is the one that
#cmd("PUNCH1") holds:

#screen(raw(read("../ex/ug-jobs/j-held-device.txt"), block: true))

The purge is answered with 200, and the message says that the purge is only
requested:

#screen(raw(read("../ex/ug-jobs/j-held-purge.txt"), block: true))

The job is still on the queue. A status request finds it, and the status is
#cmd("OUTPUT"), as before the purge. The status request does not show the mark.
A second DELETE gets the same answer as the first.

#screen(raw(read("../ex/ug-jobs/j-held-status.txt"), block: true))

The job leaves the queue when the output is released. The session releases it
by cancelling the device with the console command #cmd("$C PUNCH1"). On a
production system the operator decides how to release the output:

#screen(raw(read("../ex/ug-jobs/j-held-release.txt"), block: true))

Now the job is gone, and the status request gets the 404 of any job that does
not exist:

#screen(raw(read("../ex/ug-jobs/j-held-gone.txt"), block: true))

A client that must know that the spool is free does not rely on the 200. It
reads the field #cmd("message"), or it asks for the job again until the answer
is 404.

== Jobs of Other Users <ug-jobs-others>

#idx("job", "other users")#idx("JESSPOOL")#idx("owner=*")
A session lists, reads and purges the own jobs without any profile. For the job
of another user mvsMF asks RAKF, in the class #cmd("JESSPOOL"), whether the
user may read it, and for a purge whether the user may update it. The
administrator answers with profiles (@ug-security). The user can only see what
the profiles allow. A job that the user may not see is hidden: for every
request it is as if the job does not exist.

The sessions of this section are those of a second user. The job
#cmd("MVSMFDM5") belongs to the first user, and the second user asks for it.
The same four requests run in three states of the profiles. In the first state
the second user has no access to the job.

The query parameter #cmd("owner") narrows the list to the jobs of one owner. The
rules are these:

- No value, an empty value, or the own user ID lists the own jobs.
- A user ID of another user lists the jobs of that user, only if the profiles
  give READ access to them. If they do not, the answer is #cmd("[]") with the
  status 200.
- The value #cmd("owner=*") lists the jobs of all users, only if the profiles
  give READ access to all. If they do not, the list holds the own jobs. This is
  not an error.
- The value is compared as a whole: #cmd("ABC") does not match the jobs of
  #cmd("ABCD"). A pattern, a value of more than eight characters, and a value
  with other than letters, digits, #cmd("$"), #cmd("#") and #cmd("@") give
  #cmd("[]").

=== No Access <ug-jobs-others-none>

#idx("JESSPOOL", "no access")
The second user has no profile that covers the job. The four requests list the
jobs of the first user by owner, list the jobs of all users, ask for the files
of the job, and purge the job:

#screen(raw(read("../ex/ug-jobs/j-oth-none-list.txt"), block: true))
#screen(raw(read("../ex/ug-jobs/j-oth-none-star.txt"), block: true))
#screen(raw(read("../ex/ug-jobs/j-oth-none-files.txt"), block: true))
#screen(raw(read("../ex/ug-jobs/j-oth-none-purge.txt"), block: true))

The list for the owner of the first user is empty. The list for #cmd("owner=*")
holds the own jobs of the second user only, and none of the first user. Here it
is empty too, because the second user owns no job whose name starts with
#cmd("MVSMFDM"). The files request and the purge request get the answer 404, the
same answer as for a job that does not exist.

=== READ Access <ug-jobs-others-read>

#idx("JESSPOOL", "READ")
The second user may read the jobs of the first user. The same four requests
follow:

#screen(raw(read("../ex/ug-jobs/j-oth-read-list.txt"), block: true))
#screen(raw(read("../ex/ug-jobs/j-oth-read-star.txt"), block: true))
#screen(raw(read("../ex/ug-jobs/j-oth-read-files.txt"), block: true))
#screen(raw(read("../ex/ug-jobs/j-oth-read-purge.txt"), block: true))

With READ access the second user lists the job, asks for its status and its
files, and reads its output. The purge request is refused with the answer 500,
the category 4, the message #cmd("LMOPEN error") and the text
#cmd("Authorization failed - You may not purge this job.") in the field
#cmd("details"). The refusal differs from the 404 of a hidden job on purpose: the user sees the
job and may not purge it.

=== UPDATE Access <ug-jobs-others-update>

#idx("JESSPOOL", "UPDATE")
The second user may update the job. UPDATE, CONTROL and ALTER all give the
right to purge:

#screen(raw(read("../ex/ug-jobs/j-oth-update-list.txt"), block: true))
#screen(raw(read("../ex/ug-jobs/j-oth-update-star.txt"), block: true))
#screen(raw(read("../ex/ug-jobs/j-oth-update-files.txt"), block: true))
#screen(raw(read("../ex/ug-jobs/j-oth-update-purge.txt"), block: true))

The purge request succeeds, and the job is gone.

#note[*Your own jobs do not depend on a profile.* A profile in the class
#cmd("JESSPOOL") decides only what a user may do with the jobs of other users.
The _mvsMF Reference_ (chapter "Job Services", section "Job Authorization") has
the exact rules. "Setting Up Security" (@ug-security) shows how to write the
profiles.]

== Change from mvsMF 1.3.0 <ug-jobs-change>

#idx("job", "change from 1.3.0")#idx("JESSPOOL", "change from 1.3.0")
mvsMF 1.4.0 changes the jobs service in these places:

- *Jobs of other users.* In mvsMF 1.3.0 every user who could log on listed,
  read and purged the jobs of every owner. In 1.4.0 a user sees only the own
  jobs, until the administrator writes JESSPOOL profiles. An administrator who
  relied on the old behaviour defines the profiles before the upgrade
  (@ug-security).
- *The owner filter.* In 1.3.0 the value of #cmd("owner") matched the beginning
  of an owner: #cmd("owner=ABC") also found the jobs of #cmd("ABCD"). In 1.4.0
  the value is compared as a whole. In 1.4.0 #cmd("owner=*") lists the own jobs,
  unless a profile allows more.
- *Hidden jobs.* A job that the user may not see is answered with the 404 of a
  job that does not exist. A purge of a job that the user may read and not
  update is answered with 500.
- *A purge that is only requested.* In mvsMF 1.3.0 the answer to a purge always
  had the message #cmd("Request was successful."), also when JES2 kept the job
  on the queue because a device held its output. In 1.4.0 mvsMF looks at the
  queue again after JES2 took the request, and the message says when the job is
  still there (@ug-jobs-purge-pending). The status stays 200 and the field
  #cmd("status") stays 0. A client that tests the status only sees no
  difference. The answer in that case takes about a second longer.
- *The HTTPD procedure.* mvsMF no longer needs the DD statements
  #cmd("HASPCKPT") and #cmd("HASPACE1") in the procedure of HTTPD (httpd) to
  read the jobs. With libc370 2.24 mvsMF opens the JES2 checkpoint as
  #cmd("SYS1.HASPCKPT") and the spool as #cmd("SYS1.HASPACE") on the volume that
  the checkpoint names. A DD
  statement for either one still wins over this. A system where JES2 uses a
  data set name prefix other than #cmd("SYS1") keeps the DD statement
  #cmd("HASPCKPT") in the procedure.
