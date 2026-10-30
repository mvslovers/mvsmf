#import "../bookmaster/bookmaster.typ": *

= Typical Errors and What They Mean <ug-errors>

#idx("errors")
#idx("status codes", "errors")
This chapter lists the answers a client meets most often when something does
not work. Every error report quoted here was returned by a real mvsMF in a
session of this book, except the report of a JOB card that cannot be continued, which
the text takes from the source of mvsMF. The chapter gives the meaning in a few words and points
to the chapter that explains the task. The _mvsMF Reference_ lists every status
code and every error report in full.

An error report is a JSON object. The services for data sets, files and jobs
return the fields #cmd("rc"), #cmd("category"), #cmd("reason") and
#cmd("message"), and sometimes #cmd("details"). The authentication service
returns #cmd("returnCode"), #cmd("reasonCode") and #cmd("message"). The console
service returns #cmd("return-code"), #cmd("reason-code") and #cmd("reason").
Some answers have no body at all.

== Answers Without a Report <ug-errors-bare>

#tab(caption: [Answers with no error report])[
#table(
  columns: (auto, 1fr, auto),
  [*Status*], [*What it means*], [*See*],
  [#cmd("401")], [The request has no valid credentials: it carries none, or
    the token has ended, after a logout for example. A failed login returns
    a report, see the next section.], [@ug-first],
  [#cmd("403")], [HTTPD refused the route before mvsMF ran. The user has no
    READ access to the RAKF resource that protects the route. The body is
    plain text, not JSON. A user may use some routes and be refused on
    others, because the routes are protected separately.], [@ug-security],
)
]

== Authentication <ug-errors-auth>

#tab(caption: [Errors of the login])[
#table(
  columns: (auto, 1fr, auto),
  [*Status and report*], [*What it means*], [*See*],
  [#cmd("401"), #cmd("returnCode") 8, #cmd("reasonCode") 1], [The login
    failed. The message asks to check the user ID and the password, and that
    the user ID has the SAF permissions mvsMF needs. If it happens to every
    user, also with a right password, the console of HTTPD shows
    #cmd("HTTPD042W") from the last start.], [@ug-first, @ug-security-open],
)
]

== Data Sets <ug-errors-ds>

#tab(caption: [Errors of the data set services])[
#table(
  columns: (auto, 1fr, auto),
  [*Status and report*], [*What it means*], [*See*],
  [#cmd("400"), #cmd("category") 6, #cmd("reason") 3, “Invalid or missing
    allocation parameters”], [The create request lacks an attribute the
    allocation needs, or an attribute has an invalid value.], [@ug-data],
  [#cmd("404"), #cmd("reason") 4, “Dataset not found”], [mvsMF found no
    such data set.], [@ug-data],
  [#cmd("404"), #cmd("reason") 5, “PDS member not found”], [The data set
    exists, the member does not.], [@ug-data],
  [#cmd("412"), “The resource was modified since the supplied ETag was
    created”], [A conditional request found that the data set had changed
    since the client read it. Read it again and decide.], [@ug-data],
  [#cmd("500"), #cmd("category") 4, “LMOPEN error”, detail “Authorization
    failed - You may not use this protected data set.”], [RAKF refused the
    access to the data set.], [@ug-security],
  [#cmd("500"), #cmd("rc") 900, #cmd("category") 8, #cmd("reason") 7, “Dynamic
    allocation Error”], [The allocation of a new data set was refused. Two
    checks can cause this, and the answer is the same for both: the user has
    no ALTER access to the new name, or the user has no UPDATE access to the
    master catalog. The system log tells them apart.], [@ug-security],
  [#cmd("500"), #cmd("category") 16, “iconv_open() failed.”], [The
    #cmd("X-IBM-Data-Type") header names an encoding mvsMF does not support.
    The detail names the two that it does.], [@ug-data],
)
]

== Files <ug-errors-uss>

#tab(caption: [Errors of the file services])[
#table(
  columns: (auto, 1fr, auto),
  [*Status and report*], [*What it means*], [*See*],
  [#cmd("404"), “File or directory not found”], [The path does not exist.],
    [@ug-uss],
  [#cmd("400"), “File or directory already exists”], [A create request named
    a path that is there already.], [@ug-uss],
  [#cmd("400"), “Directory not empty”], [A delete request named a directory
    that still has entries.], [@ug-uss],
  [#cmd("412"), “The resource was modified since the supplied ETag was
    created”], [A conditional request found that the file had changed.],
    [@ug-uss],
  [#cmd("500"), “No space left on device”], [The file system has no room left for the write.], [@ug-uss],
)
]

A read of a file that fails after the answer has started has no status and no
report. The connection closes in the middle of the body, and curl exits with
18. The operator gets #cmd("MVSMF301E") (@ug-uss-readfail).

== Jobs <ug-errors-jobs>

#tab(caption: [Errors of the job services])[
#table(
  columns: (auto, 1fr, auto),
  [*Status and report*], [*What it means*], [*See*],
  [#cmd("400"), “No valid JOB card found in submitted JCL”], [The JCL does
    not start with a JOB statement.], [@ug-jobs],
  [#cmd("400"), #cmd("category") 6, #cmd("reason") 12, “JOB card cannot be continued: no room for the comma that joins it to the NOTIFY, USER and PASSWORD operands mvsMF adds”], [mvsMF
    cannot give the last card of the JOB statement the comma that joins it to
    the card it adds: the card has data behind column 71 and no comma at its
    end, or it ends in column 71 and has no comma outside quotes and
    parentheses to cut at, or the operand to move is longer than 59 characters.
    End the card with a comma or shorten it.], [@ug-jobs],
  [#cmd("400"), “DDID not found for job”], [The job has no output file with
    that id. List the files of the job first.], [@ug-jobs],
  [#cmd("404"), “Job '…' not found”], [No job of that name and id is on the
    system, or the job exists and RAKF does not let the user see it. The
    answer is the same for both.], [@ug-jobs, @ug-security],
  [#cmd("500"), #cmd("category") 4, “LMOPEN error”, detail “Authorization
    failed - You may not purge this job.”], [The user may see the job but not
    purge it. Purging needs UPDATE access to the JESSPOOL resource of the
    job.], [@ug-security],
)
]

== Console Commands <ug-errors-console>

#tab(caption: [Errors of the console service])[
#table(
  columns: (auto, 1fr, auto),
  [*Status and report*], [*What it means*], [*See*],
  [#cmd("400"), #cmd("reason-code") 6, “The Content-Type cannot be
    handled”], [The request that issues a command needs
    #cmd("Content-Type: application/json").], [@ug-console],
  [#cmd("400"), #cmd("reason-code") 22, “The parameter timeRange is
    invalid”], [The #cmd("timeRange") of a hardcopy log request is not a
    number with a unit, such as #cmd("10m").], [@ug-console],
  [#cmd("500"), #cmd("category") 4, “LMOPEN error”, detail “Authorization
    failed - You may not use this service.”], [The user has no READ access to
    #cmd("MVSMF.CONSOLE"), or the profile does not exist. The report has the
    fields of the data set services, not those of the other console errors.
    The diagnostic endpoint of a development build answers the same.],
    [@ug-security-console],
)
]
