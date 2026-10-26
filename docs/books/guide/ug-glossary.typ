#import "../bookmaster/bookmaster.typ": *

= Glossary <ug-glossary>

This glossary defines the terms of mvsMF, and of HTTPD, RAKF, JES2 and MVS as
far as this book uses them. A term printed in _italics_ in a definition has an
entry of its own.

#let g(..items) = deflist(width: 1.45in, ..items.pos().enumerate().map(
  ((i, x)) => if calc.even(i) { par(justify: false, strong(x)) } else { x }))

#g(
  [APF], [The authorization list of MVS. A program in a _STEPLIB_ runs
    authorized only if every library of the concatenation is on the list
    (@ug-install-apf).],
  [Basic authentication], [The way of a client to send a user ID and a
    password with every request in the header #cmd("Authorization")
    (@ug-first-basic).],
  [catalog], [The directory of the data sets of a system. Creating a data set
    under a high-level qualifier without a catalog alias needs UPDATE access
    to the master catalog (@ug-security-dsn-catalog).],
  [CGI module], [A program that _HTTPD_ loads and calls for the routes that
    name it. mvsMF is one (@ug-intro-flow).],
  [code page], [The table that maps the bytes of EBCDIC text to the characters
    of the client. mvsMF uses IBM-037 for data sets and IBM-1047 for files in
    _UFS_, and a request can name the other one (@ug-data-codepage,
    @ug-uss-codepage).],
  [credential], [What _HTTPD_ holds for a user after the logon, among it the
    groups the user was connected to at that time. A group change reaches the
    user only with a new credential (@ug-security-connect).],
  [DDID], [The id of one output file of a job. The list of the files of a job
    returns it, and a request for the content of a file names it
    (@ug-jobs-files).],
  [ETag], [A value that stands for the content of a data set, a member or a
    file at the time of a read. A write with #cmd("If-Match") succeeds only if
    the value is still the same (@ug-uss-etag).],
  [FACILITY class], [A resource class of the security product. A route line
    with #cmd("RES=") checks a resource in it (@ug-security-console).],
  [FMID], [The id of a function SYSMOD in SMP. mvsMF 1.4.0 is #cmd("TZMF140")
    (@ug-install-package).],
  [hardcopy log], [The console messages that mvsMF reads from the _Master Trace
    Table_ on request (@ug-console-log).],
  [HTTPD], [The HTTP server for MVS 3.8j (httpd) that loads mvsMF and decides,
    from its _route lines_, who may reach it.],
  [HTTPPRM], [The DD of the _HTTPD_ started task that holds the route lines
    (@ug-install-routes).],
  [internal reader], [The JES2 interface that takes JCL from a program. mvsMF
    submits a job through it (@ug-jobs-submit).],
  [JES2], [The job entry subsystem of MVS 3.8j. It runs the jobs and keeps
    their output.],
  [JESSPOOL class], [The resource class in which mvsMF asks RAKF whether a
    user may see or purge a job. The resource is named
    #cmd("<owner>.<jobname>.<jobid>") (@ug-security-jesspool).],
  [JOB statement], [The first statement of the JCL of a job. mvsMF adds
    operands to it before the submit (@ug-jobs-jobcard).],
  [Master Trace Table], [The table in storage that holds recent system
    messages. mvsMF reads the answers of console commands from it
    (@ug-console-what).],
  [member], [One named part of a partitioned data set (@ug-data).],
  [mvsMF], [The z/OSMF REST API for MVS 3.8j (mvsmf). A _CGI module_ of
    _HTTPD_. It is a clone of the REST interface of z/OSMF, not z/OSMF.],
  [PDS], [A partitioned data set, a data set that holds _members_ (@ug-data).],
  [RAKF], [The security product of the system that mvsMF asks for every
    access. The tables #cmd("USERS") and #cmd("PROFILES") control it
    (@ug-security-users).],
  [route line], [A line in the _HTTPPRM_ member that binds a URL to a module and
    says how the request is authenticated and which resource it needs. The
    first line that matches wins (@ug-install-routes).],
  [started task], [A program that the operator starts with the START command
    and that runs as a job of its own. _HTTPD_ is one (@ug-ops-start).],
  [STEPLIB], [The DD that names the libraries from which a program is loaded
    (@ug-install-steplib).],
  [token], [A value that a client receives from the login service and sends in
    a cookie in place of a user ID and a password (@ug-first-token).],
  [UFS], [The file system of _UFSD_, with directories, files and permissions.
    The file services work on it (@ug-uss).],
  [UFSD], [The server that provides _UFS_. The file services of mvsMF need it
    (@ug-uss-ufsd).],
  [unsolicited message], [A message on the console that no command caused. The
    console services can wait for one (@ug-console-detect).],
  [z/OSMF], [The IBM product whose REST interface mvsMF clones.],
)
