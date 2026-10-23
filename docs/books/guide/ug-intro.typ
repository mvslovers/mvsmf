#import "../bookmaster/bookmaster.typ": *

= Introducing mvsMF <ug-intro>

#idx("mvsMF")
#idx("z/OSMF")
mvsMF (mvsmf) is a REST API for MVS 3.8j. It copies the part of the IBM z/OSMF REST
interface that a client needs to work with data sets, jobs, UNIX files and the
console. A client sends an HTTP request and gets JSON or the text of a file in
return. mvsMF is a clone: it is not z/OSMF, and it offers only the services
that this chapter lists.

mvsMF runs as a CGI module of HTTPD (httpd). HTTPD takes the connection, finds
out who the user is, and starts mvsMF for every request. This chapter describes
what mvsMF does, which clients it is made for, what it needs, and what it does
not do.

== What mvsMF Does <ug-intro-what>

#idx("services")
mvsMF has six services. All paths begin with #cmd("/zosmf/"):

#tab(caption: [The services of mvsMF])[
  #table(columns: (1.1in, 2.0in, 1fr),
    [Service], [Path], [What it offers],
    [System information], [#cmd("/zosmf/info")], [Version and host of the
      server (@ug-first).],
    [Login], [#cmd("/zosmf/services/authenticate")], [Log in and get a token,
      log out (@ug-first).],
    [Data sets], [#cmd("/zosmf/restfiles/ds")], [List data sets and members,
      read, write, create and delete them (@ug-data).],
    [UNIX files], [#cmd("/zosmf/restfiles/fs")], [List, read, write, create and
      delete files and directories in the file systems of UFSD (@ug-uss).],
    [Jobs], [#cmd("/zosmf/restjobs/jobs")], [Submit a job, list jobs, see the
      status, read the spool output, purge a job (@ug-jobs).],
    [Console], [#cmd("/zosmf/restconsoles")], [Issue an operator command, read
      its answer, read the log (@ug-console).],
  )
]

Another path, #cmd("/zosmf/test"), is a diagnostic endpoint for the people who
look after the system. It is not a service for users, and a release does not
have it: only a development build, whose version ends in #cmd("-dev"),
registers it. It needs the same permission as the console services. The _mvsMF
Reference_ describes it in "The Diagnostic Endpoint".

The _mvsMF Reference_ lists every request of these services with its parameters,
headers, answers and status codes. This book shows how to do the work and
leaves the protocol detail to the reference.

== Clients <ug-intro-clients>

#idx("client")
#idx("curl")
A program that speaks HTTP and knows the z/OSMF requests can use mvsMF. The
clients that mvsMF is made for are Zowe CLI, Zowe Explorer and the JetBrains
IDEs. This edition of the book shows none of them. Every session in this book
is typed with #cmd("curl"), because it makes each request and each answer
visible. @ug-first-read says how the sessions are written.

What you learn from a #cmd("curl") session applies to any client: the request
is the same, whoever sends it.

== How a Request Travels <ug-intro-flow>

#idx("request", "path")
A request passes these stations on its way to a data set, a job or a file:

+ *HTTPD* reads the request. It finds the credential in a cookie or in the
  #cmd("Authorization") header and asks the security product whether the user
  ID and the password are good. Then it looks at the route lines of its own
  configuration: some paths need a credential, some do not, and a path can be
  tied to a security profile (@ug-security).
+ HTTPD starts the module mvsMF.
+ A small piece of code, the middleware, makes the user of the request the user
  of the task. From now on, the access to data sets, files and jobs is checked
  for that user. If HTTPD found no good credential, the middleware answers 401.
  Only the login (@ug-first-token) goes past it without a credential.
+ mvsMF finds the handler for the method and the path. A request that no
  handler matches gets the status 404, with a JSON error report.
+ The handler does the work and sends the answer. Most answers are JSON. A file
  or a data set is sent as text or as bytes.

The first station decides which user ID is used, so most of the access rules
are the rules of HTTPD and of the security product. They are described in
@ug-security.

== What mvsMF Needs <ug-intro-needs>

#idx("requirements")
mvsMF runs on MVS 3.8j as a module of HTTPD. The build file of mvsMF 1.4.0
names these products as dependencies:

#tab(caption: [Products that mvsMF 1.4.0 is built with])[
  #table(columns: (1.2in, 1.1in, 1fr),
    [Product], [Version], [Used for],
    [HTTPD (httpd)], [4.2.0 or later], [The web server that runs mvsMF. The
      login service needs a function that HTTPD has from 4.2.0.],
    [crypto370], [1.0.0 or later], [A library of cryptographic functions. mvsMF
      uses its base64 coding for the token of the login.],
    [UFSD (ufsd)], [built against 1.4.0], [The file systems behind the UNIX file
      services. The installation instructions name no minimum level.],
  )
]

UFSD is needed only for the UNIX file services. If UFSD is not available, a
request for a UNIX file is answered with the status 503, and the other services
are not affected.

@ug-install describes how to install mvsMF and the products it needs, and
@ug-ops how to run it.

== What mvsMF Does Not Do <ug-intro-not>

#idx("limits")
mvsMF offers a part of z/OSMF. These points differ from the IBM product:

- *No other services.* A request for any other z/OSMF path gets the status 404
  (a request without a credential gets 401 first).
- *No change of a job.* A client can submit, list, read and purge jobs. It
  cannot hold or release a job, and it cannot cancel a job and keep its output
  (@ug-jobs-purge).
- *No data sets by volume.* The forms of the data set paths that name a volume
  (#cmd("-(VOLSER)")) are not offered. A request that uses one gets the
  status 404.
- *No partial content.* mvsMF never answers 206. A list that is cut says so in
  the answer, in the field #cmd("moreRows").
- *No 403 and no 409 from mvsMF.* A refusal by the security product is
  reported as a server error (status 500) with its own report. A UNIX file that
  exists already, or a directory that is not empty, is a 400. Only HTTPD itself
  answers 403, when a profile on a route refuses a user (@ug-first-fail).
- *No extra header.* Real z/OSMF wants the header #cmd("X-CSRF-ZOSMF-HEADER")
  on a request. mvsMF does not require it and does not look at its value.

== Platform Facts <ug-intro-platform>

#idx("EBCDIC")
#idx("code page")
Some facts of the platform show in every service. They matter when you move
text and numbers between a client and MVS.

- *Code pages.* The text of a data set and of a job is in code page 037
  (IBM-037). The text of a UNIX file is in code page 1047 (IBM-1047). The two
  differ in a few characters, such as the square brackets, the circumflex and
  the not sign. A client can ask for the other code page of a data set
  or a file. @ug-data and @ug-uss describe how.
- *Size of a UNIX file.* A file in a file system of UFSD cannot be larger than
  4.06 MB: 4,259,840 bytes with the usual block size of 4096 bytes. That is a
  limit of UFSD, not of mvsMF.
- *Size of a request.* mvsMF refuses a request that declares a body of 16 MB
  (16,777,216 bytes) or more with the status 413. The free storage of the
  address space of HTTPD is the more likely limit: a body that does not fit is
  answered with the status 500.

== Finding a Task <ug-intro-tasks>

#idx("tasks")
The chapters for the user follow the work that a user does. Each has sessions
that were typed with #cmd("curl"):

#tab(caption: [Where to find a task])[
  #table(columns: (2.8in, 1fr),
    [I want to ...], [Chapter],
    [check the connection, log in, or find out why a login fails], [@ug-first],
    [list, read, write, create or delete a data set or a member], [@ug-data],
    [work with a UNIX file or a directory], [@ug-uss],
    [submit a job, see its status, read its output, purge it], [@ug-jobs],
    [issue an operator command and read the answer], [@ug-console],
    [find out what an error answer means], [@ug-errors],
    [decide who may use mvsMF and what they may do], [@ug-security],
    [install mvsMF], [@ug-install],
    [start it, stop it, find a problem], [@ug-ops],
    [remove mvsMF], [@ug-remove],
    [look up a word], [@ug-glossary],
  )
]

== What Is New in mvsMF 1.4.0 <ug-intro-new>

#idx("mvsMF 1.4", "changes")
mvsMF 1.4.0 changes these behaviours against 1.3.0. Each is described where the
book explains the subject:

#tab(caption: [Changes in mvsMF 1.4.0])[
  #table(columns: (3.4in, 1fr),
    [Change], [Where],
    [A user lists, reads and purges the jobs of the own user ID. A job of
      another owner needs a profile in the RAKF class #cmd("JESSPOOL"): READ
      to list and read it, UPDATE to purge it. A job that the user may not see
      answers 404, as a job that does not exist. The value of #cmd("owner") in
      the job list is compared as a whole. Before, every user who could log on
      could read and purge the jobs of everybody. Define the profiles before
      you upgrade.], [@ug-jobs-change, @ug-security-jesspool],
    [The sample route lines of HTTPD have a route of its own for
      #cmd("/zosmf/restconsoles/*"). It asks RAKF for READ access to the
      resource #cmd("MVSMF.CONSOLE") in the class #cmd("FACILITY"), and mvsMF asks
      for the same permission itself in every console request and in the
      diagnostic endpoint. Before, any user who got in could issue any operator
      command. Until the profile is defined and READ is granted, every user is
      refused, administrators too.],
      [@ug-security-console, @ug-install-upgrade],
    [A list of data sets that fails for lack of storage, and the check why a
      member could not be opened, answer the status 500. Before, the answer was
      an empty list with 200, or "member not found" with 404.], [@ug-data-list],
    [The end of the data of a binary or record read of a data set with fixed
      records is estimated from the layout of the device, so it is right on a
      3380 disk too. For a device that mvsMF does not know, it does not
      estimate.], [@ug-data-binary],
    [The job services no longer need the DD statements #cmd("HASPCKPT") and
      #cmd("HASPACE1") in the procedure of HTTPD. They are still used if
      they are present, and needed if JES2 uses a data set prefix other
      than #cmd("SYS1").], [@ug-jobs-change, @ug-install-jes],
  )
]
