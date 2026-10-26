#import "../bookmaster/bookmaster.typ": *

= Configuring HTTPD for mvsMF <ref-httpd>

#idx("HTTPD", "configuration")#idx("HTTPPRM")
mvsMF (mvsmf) is a CGI module of HTTPD (httpd). HTTPD decides which requests
reach mvsMF, whether a login is needed first, and which RACF resource a caller
must hold. This chapter lists what HTTPD reads for that: the route lines in the
member of the data definition #cmd("HTTPPRM"), the options of a route, the rule
by which HTTPD picks a route, the gate in front of the route, the procedure and
its STEPLIB, and the HTTPD messages that concern mvsMF. The text describes
HTTPD 4.3.0. Where a function comes only with HTTPD 4.4.0, the text says so.
mvsMF 1.4.0 needs HTTPD 4.2.0 or later.

The steps that put the lines in place are in the chapter “Installing mvsMF” of
the _mvsMF User's Guide_. The profiles that #cmd("RES=") names are described in
“Setting Up Security” in the same book. The messages of mvsMF itself are in
@apx-messages.

== The Module <ref-httpd-module>

#idx("MVSMF", "load module")#idx("module name")
The load module is named #cmd("MVSMF"). It is the only program mvsMF adds. It
is link-edited reentrant (RENT) and reusable (REUS), and it contains the router
and all handlers. HTTPD runs it with the LINK SVC inside the worker task that
serves the request, once for each request. mvsMF does not run without
HTTPD: called from TSO or from a batch job it writes
#cmd("MVSMF005E MVSMF MUST BE CALLED BY THE HTTPD SERVER") and ends with the
return code 12.

The name in the route line is the name of the member that HTTPD searches in
the STEPLIB of its own address space. HTTPD folds the name to upper case and
uses its first eight characters.

== The Route Lines <ref-httpd-lines>

#idx("route", "MOD=")#idx("HTTPPRM", "route lines")
mvsMF uses four lines in the member of the data definition #cmd("HTTPPRM"). The
sample member of the product (member #cmd("MVSMFPRM") of the data set
#cmd("MVSMF.SAMPLIB")) carries them:

```
MOD=MVSMF /zosmf/info                    AUTH=NONE
MOD=MVSMF /zosmf/services/authenticate   AUTH=NONE
MOD=MVSMF /zosmf/restconsoles/*          AUTH=TOKEN RES=FACILITY:MVSMF.CONSOLE
MOD=MVSMF /zosmf/*                       AUTH=TOKEN
```

The sample #cmd("HTTPPRM0") of HTTPD has the first, the second and the last line
only. A member that was built from it needs the third line.

The order of the four lines is part of the configuration (@ref-httpd-match).
The three specific lines come before the line with the wild card.

#tab(caption: [The four route lines of mvsMF])[
  #table(columns: (2.0in, 0.8in, 1fr),
    [Path], [AUTH=], [Meaning],
    [#cmd("/zosmf/info")], [#cmd("NONE")], [HTTPD does not gate the route.
      mvsMF still answers 401 when the request carries no credential
      (@ref-httpd-gate).],
    [#cmd("/zosmf/services/authenticate")], [#cmd("NONE")], [The login and the
      logout of the token service. HTTPD does not gate the route. mvsMF lets
      the request reach its handler without a resolved credential, so that a
      failed login can answer with the error report of the service.],
    [#cmd("/zosmf/restconsoles/*")], [#cmd("TOKEN")], [The console services,
      which issue operator commands under the identity of the caller. HTTPD asks
      RAKF for READ access to #cmd("MVSMF.CONSOLE") in the class
      #cmd("FACILITY") (@ref-httpd-opts). A user without the access gets the
      plain text 403 of HTTPD, and mvsMF does not run. mvsMF checks the same
      access again in its console handlers (@ref-cons-auth).],
    [#cmd("/zosmf/*")], [#cmd("TOKEN")], [Every other path of mvsMF. A request
      without a valid credential gets a plain 401 from HTTPD (a text body, no challenge), before mvsMF runs.],
  )
]

To require a RACF resource for the rest of the API, add #cmd("RES=") to the line
with the wild card. The console route does not check this resource: the first
line that matches decides, and a route has one #cmd("RES="):

```
MOD=MVSMF /zosmf/*  AUTH=TOKEN RES=FACILITY:MVSMF.ACCESS
```

The sample member carries this line as a comment. A line gates its route only
when the profile of its resource exists (@ref-httpd-opts).

For each registered route HTTPD writes
#cmd("HTTPD036I MODULE MVSMF REGISTERED FOR path") to the console.

== Syntax of a Route Line <ref-httpd-syntax>

#idx("MOD=")#idx("LOC=")#idx("AUTH=")#idx("RES=")
HTTPD reads the member line by line. A line that starts with #cmd("#") or
#cmd("*") is a comment. A route line has one of two forms:

```
MOD=program [path] [AUTH=mode] [RES=class:resource]
LOC=path [AUTH=mode] [RES=class:resource]
```

#deflist(width: 1.35in,
  [#cmd("MOD=")], [A route to a CGI module. The first word is the name of the
    program (@ref-httpd-module). The second word is the path. Without a path
    HTTPD derives one from the name of the program: the extension
    #cmd("*.mvsmf") for #cmd("MVSMF"). A route of mvsMF always names its path.],
  [#cmd("LOC=")], [A route without a program: a path that HTTPD serves as a static
    file from its document root, with the same #cmd("AUTH=") and #cmd("RES=")
    policy as a #cmd("MOD=") route. mvsMF has no #cmd("LOC=") line of its own.
    For each such route HTTPD writes #cmd("HTTPD417I LOCATION path REGISTERED").],
  [#cmd("path")], [A path, or a pattern with #cmd("*") and #cmd("?")
    (@ref-httpd-match).],
  [#cmd("AUTH=")], [The login policy of the route (@ref-httpd-opts).],
  [#cmd("RES=")], [A RACF resource that the caller must be allowed to read
    (@ref-httpd-opts).],
)

The words are separated by blanks or tabs. HTTPD reads at most eight words from
a line. The mode after #cmd("AUTH=") is not case sensitive. A line that starts
with an option where the program or the path belongs is refused, and HTTPD
writes a message that names the line.

== Route Matching and Precedence <ref-httpd-match>

#idx("route", "matching")#idx("route", "precedence")#idx("first match wins")
HTTPD keeps all routes, #cmd("MOD=") and #cmd("LOC="), in one table, in the
order of the lines of the member. For each request it tests the routes in that
order, and the first route that matches wins. There is no rule for the longest
or the most specific path. HTTPD never tests a route further down the member
once an earlier one matched.

#note[*Order matters.* A line with the wild card above a more specific line
swallows every request the specific line was meant for. In the sample member
the line #cmd("/zosmf/*") is the last of the four for this reason. A route that
must be gated differently from the rest of the API stands above the line
#cmd("/zosmf/*"), never below.]

The path of the request is the path of the request line, percent-decoded,
without the query string. HTTPD compares that path with the path of each route.
The comparison depends on the route:

#tab(caption: [How HTTPD compares a route path with the request path])[
  #table(columns: (1.6in, 1fr),
    [Path of the route], [Comparison],
    [No #cmd("*") and no #cmd("?")], [Exact match. Upper and lower case letters
      are equal: #cmd("/ZOSMF/INFO") matches the route #cmd("/zosmf/info").
      There is no prefix match.],
    [With #cmd("*") or #cmd("?")], [Pattern match. Upper and lower case letters
      differ: the route #cmd("/zosmf/*") does not match the request path
      #cmd("/ZOSMF/restjobs/jobs").],
  )
]

In a pattern, #cmd("?") stands for exactly one character. A trailing #cmd("*")
matches the rest of the path, also the empty rest. A #cmd("*") inside the
pattern matches at least one character. The #cmd("*") also matches the
character #cmd("/"), so #cmd("/zosmf/*") covers every path below #cmd("/zosmf/")
at any depth. The route #cmd("/zosmf/*") does not match the path
#cmd("/zosmf"), which has no slash after the name.

A request path that no route matches is a static request: HTTPD serves a file
of its document root, and no route gates it (@ref-httpd-gate).

#note[The comment of the HTTPD sample member says “URL prefix match” for the
form #cmd("MOD=program /url/pattern"). The code compares a path without a
wild card for equality. Write the #cmd("*") when you mean a prefix.]

== The Gate in Front of the Route <ref-httpd-gate>

#idx("gate", "HTTPD")#idx("401")#idx("403")#idx("credential")
HTTPD resolves the credential of a request before it looks for the route. It
tries, in this order: the cookie #cmd("Sec-Token"), the cookie #cmd("LtpaToken2"),
a bearer token, and Basic authentication. A session is valid only for the client
address it was issued to. Because the credential is resolved first, every route
accepts every kind of credential. The option #cmd("AUTH=") does not select a
kind of credential. It selects whether the route needs a login, and how HTTPD
answers a request that has none.

When a route matches, the gate works in two stages:

+ *Authentication.* If the route needs a login and the request has no valid
  credential, HTTPD answers 401. The mode of the route decides the shape of the
  answer (@ref-httpd-opts). The route runs only for an authenticated request.
+ *Resource check.* If the route has #cmd("RES="), HTTPD asks RACF whether the
  caller has READ access to the resource. When the answer is no, HTTPD answers
  403 with the body #cmd("403 Forbidden").

The bodies of both answers are plain text, and both answers carry
#cmd("Cache-Control: no-store"). The answer 401 of mode #cmd("BASIC") carries
#cmd("WWW-Authenticate: Basic realm=\"name\""). The name is the value of the
keyword #cmd("REALM") in the member or, without it, the SMF system identifier.
HTTPD leaves the header out when the request carries
#cmd("X-CSRF-ZOSMF-HEADER").

Two paths are handled by HTTPD before the gate: #cmd("/login") and
#cmd("/logout"). Assets of the login page, whose paths match #cmd("/login.*") or
#cmd("/favicon.*"), are reachable in every mode.

#note[*Two layers.* A route with #cmd("AUTH=NONE") is not gated by HTTPD. For
#cmd("/zosmf/info") the module still refuses a request that has no resolved
credential with 401: mvsMF exempts only the exact path
#cmd("/zosmf/services/authenticate") from this check. The same holds for every
other path of mvsMF, whatever the line in the member says.]

== The Options AUTH= and RES= <ref-httpd-opts>

#idx("AUTH=", "modes")#idx("RES=", "syntax")
#tab(caption: [The modes of AUTH=])[
  #table(columns: (0.8in, 1fr),
    [Mode], [Request without a valid credential],
    [#cmd("NONE")], [The route is public. HTTPD never challenges.],
    [#cmd("FORM")], [HTTPD answers with the login page.],
    [#cmd("BASIC")], [401 with #cmd("WWW-Authenticate: Basic"), so that a
      browser asks for the user ID and password.],
    [#cmd("TOKEN")], [A plain 401 with a text body and without a challenge. This is the mode for API
      clients and the mode of the sample line for #cmd("/zosmf/*").],
  )
]

#cmd("RES=class:resource") names a resource of a RACF class. HTTPD asks for READ
access. The class and the resource are separated by the first colon. A route
with #cmd("RES=") needs an identity to check, so it authenticates.

#tab(caption: [How HTTPD handles the options of a route line])[
  #table(columns: (2.4in, 1fr),
    [Line], [Result],
    [No #cmd("AUTH=") and no #cmd("RES=")], [Mode #cmd("NONE"): the route is
      public.],
    [#cmd("RES=") without #cmd("AUTH=")], [Mode #cmd("BASIC").],
    [#cmd("AUTH=NONE") with #cmd("RES=")], [#cmd("HTTPD414W AUTH=NONE IGNORES RES=class:resource (PUBLIC ROUTE)").
      The mode #cmd("NONE") wins; the resource is not checked.],
    [#cmd("AUTH=") with another value], [#cmd("HTTPD411E UNKNOWN AUTH MODE 'value' -- USE NONE, FORM, BASIC OR TOKEN").
      HTTPD refuses the route, writes #cmd("HTTPD419E") and #cmd("HTTPD420E"),
      and does not start.],
    [#cmd("RES=") without a colon, or with an empty resource], [#cmd("HTTPD412W IGNORING MALFORMED RES= 'value' (NEED CLASS:RESOURCE)").
      HTTPD ignores the option.],
    [A word that is none of the options], [#cmd("HTTPD413W IGNORING UNKNOWN ROUTE OPTION 'word'").],
    [#cmd("RECLAIM=")], [Retired. HTTPD ignores the option and writes a warning.],
    [#cmd("RES=") for a resource that no profile covers], [#cmd("HTTPD425W NO PROFILE FOR class:resource -- path NOT GATED").
      HTTPD checks this once at start. As long as no profile covers
      the resource, the route is #emph[not] gated by it. The console routes
      of mvsMF are still closed: mvsMF refuses a caller of the console
      services on its own (@ref-cons-auth).],
  )
]

#note[*A missing profile opens the route of HTTPD.* With #cmd("RES=FACILITY:MVSMF.ACCESS")
and no profile for #cmd("MVSMF.ACCESS") in the class #cmd("FACILITY"), HTTPD
starts, writes #cmd("HTTPD425W"), and lets every authenticated caller through.
This holds for the route of the whole API. The console services are the
exception, because mvsMF checks #cmd("MVSMF.CONSOLE") itself and refuses
without the profile (@ref-cons-auth). Check the start messages after you add a #cmd("RES=") option. HTTPD asks RAKF
on every request, so a profile that is defined later gates the route from the
next request on, without a restart of HTTPD.]

== Loading the Module: RESIDENT <ref-httpd-resident>

#idx("RESIDENT")#idx("module", "replacement")
HTTPD 4.3.0 fetches the module from the library for each request. It has no
keyword #cmd("RESIDENT"), and the messages of this section do not exist in it.

HTTPD 4.4.0 adds the keyword #cmd("RESIDENT"). #cmd("RESIDENT=YES") is the
default. HTTPD then loads each module named in a #cmd("MOD=") line once, when it
starts, and holds it until it ends. A request does not fetch the module from the
library. HTTPD searches the module in the STEPLIB first (BLDL) and holds it only
if it is reentrant or reusable. A module that is named by more than one route is
held once.

With HTTPD 4.4.0 a new level of #cmd("MVSMF") in the library takes effect when
HTTPD is restarted, not before. With #cmd("RESIDENT=NO") HTTPD fetches the module
for each request, as HTTPD 4.3.0 does.

#tab(caption: [Messages of the resident load (HTTPD 4.4.0)])[
  #table(columns: (0.8in, 1fr),
    [Message], [Meaning],
    [#cmd("HTTPD440W")], [#cmd("MODULE name NOT FOUND AT STARTUP, NOT HELD"). The
      module is in no library of the STEPLIB or the link list.],
    [#cmd("HTTPD441W")], [#cmd("MODULE name NOT REUSABLE, FETCHED PER REQUEST").
      The module is neither RENT nor REUS.],
    [#cmd("HTTPD442W")], [#cmd("MODULE name LOAD FAILED, ABEND CODE Snnn REASON rr, FETCHED PER REQUEST").
      The load failed. The message names the completion code and the reason
      code.],
    [#cmd("HTTPD443W")], [#cmd("INVALID RESIDENT VALUE \"value\" (YES|NO)"). The
      default stays.],
    [#cmd("HTTPD137I")], [#cmd("RESIDENT YES  MODULES HELD n"). The answer of
      #cmd("F HTTPD,D C") shows how many modules HTTPD holds. HTTPD 4.3.0
      does not write this line.],
  )
]

== The Procedure and the STEPLIB <ref-httpd-proc>

#idx("procedure", "HTTPD")#idx("STEPLIB")
The sample procedure of HTTPD is the member #cmd("httpd") of its directory
#cmd("samplib"). It runs the program #cmd("HTTPD") with #cmd("REGION=8M") and
#cmd("TIME=1440"). The parameter is #cmd("PARM='STCUSER=user STCGROUP=group'"),
with the words separated by blanks.

#tab(caption: [The data definitions of the HTTPD procedure])[
  #table(columns: (1.2in, 1fr),
    [DD name], [Use],
    [#cmd("STEPLIB")], [The libraries that hold #cmd("HTTPD") and #cmd("MVSMF").
      See below.],
    [#cmd("HTTPPRM")], [The member with the configuration and the route lines.
      The sample reads the member #cmd("&M") of the data set #cmd("&D").],
    [#cmd("HTTPDOUT"), #cmd("HTTPDERR")], [The standard output and the standard
      error of HTTPD and of the modules that run in it.],
    [#cmd("HTTPDIN")], [Dummy.],
    [#cmd("SYSUDUMP"), #cmd("SNAP"), #cmd("HTTPDBG"), #cmd("HTTPSTAT")], [Sysout
      data sets for dumps, debug output and statistics.],
    [#cmd("HASPCKPT"), #cmd("HASPACE1")], [The JES2 checkpoint and spool data
      sets. The sample procedure allocates them with the site values
      #cmd("UNIT=3350") and #cmd("VOL=SER=MVS000") and #cmd("SPOOL1"). The jobs
      service of mvsMF uses them when they are present (@ref-httpd-jes).],
  )
]

*The STEPLIB.* The STEPLIB of the procedure names the library of HTTPD and the
library of mvsMF. The installation guide puts #cmd("MVSMF.LINKLIB") first:

```
//STEPLIB  DD  DISP=SHR,DSN=MVSMF.LINKLIB
//         DD  DISP=SHR,DSN=HTTPD.LINKLIB
```

HTTPD finds the module in the first library of the concatenation that has a
member of that name. A copy of #cmd("MVSMF") in #cmd("HTTPD.LINKLIB") that comes
first hides the one SMP installed. The library #cmd("MVSMF.DEV.LINKLIB") belongs
to the development deploy of mvsMF and has no place on a production system.

*Authorization.* HTTPD must run authorized, because it uses the LINK SVC and
the RACF services. It gets the authorization in one of two ways, and the
message #cmd("HTTPD002I") tells which:

#tab(caption: [How HTTPD becomes authorized])[
  #table(columns: (2.8in, 1fr),
    [Message], [Condition],
    [#cmd("HTTPD002I AUTHORIZED BY LIBRARY (MODULE KEY 0)")], [The job step
      started authorized: every library of the STEPLIB is in the APF list
      (#cmd("SYS1.PARMLIB(IEAAPF00)")), with the data set name and the volume.
      MVS 3.8j reads the list at IPL only.],
    [#cmd("HTTPD002I AUTHORIZED BY SVC (MODULE KEY 8)")], [The step started
      unauthorized, and HTTPD authorized itself with SVC 244 of RAKF.],
  )
]

If one library of the STEPLIB is missing from the APF list, the step starts
unauthorized and HTTPD falls back to SVC 244 without a warning. When neither
way works, HTTPD writes #cmd("HTTPD012E name UNABLE TO DYNAMICALLY OBTAIN APF AUTHORIZATION")
and does not start. mvsMF needs an authorized task. It does not need an
authorized library of its own.

*The identity of the task.* HTTPD logs on as the user and group of the
parameters #cmd("STCUSER") and #cmd("STCGROUP"), so that the task does not keep the
account that RAKF gives every started task. #cmd("HTTPD004I STC IDENTITY SET TO user/group VIA RACINIT")
confirms it. When the logon fails, HTTPD writes
#cmd("HTTPD004W RACINIT ENVIR=CREATE FAILED FOR user/group RC=n") and runs with the
inherited identity.

== Access to the JES2 Data Sets <ref-httpd-jes>

#idx("HASPCKPT")#idx("HASPACE1")#idx("JES2", "checkpoint and spool")
The jobs service opens the JES2 checkpoint and spool data sets through the C
library (libc370 2.25.1 in mvsMF 1.4.0). The C library uses the data
definitions #cmd("HASPCKPT") and #cmd("HASPACE1") when the address space has
them. When it has not, the C library allocates the data sets
#cmd("SYS1.HASPCKPT") and #cmd("SYS1.HASPACE") by name. A JES2 with another
#cmd("DSNPRFX"), or a checkpoint that is neither cataloged nor on an online
volume, needs the two statements with the right values. Wrong values in the
statements break the jobs service. When mvsMF cannot open the data sets it
writes #cmd("MVSMF201E UNABLE TO OPEN THE JES2 CHECKPOINT AND SPOOL DATA SETS").

#note[*Change from mvsMF 1.3.0.* Version 1.3.0 needed the two data definitions
for the jobs service. Version 1.4.0 is linked with a C library that allocates
the two data sets by name when the statements are missing.]

== Failure of the Link <ref-httpd-link>

#idx("HTTPD908E")#idx("503")
When HTTPD cannot run the module, it answers 503 with a plain-text body
#cmd("External program MVSMF reason") (HTTPD sends the status line and the
headers only when the module has not begun an answer) and writes
#cmd("HTTPD908E EXTERNAL PROGRAM MVSMF reason") to the console.

#tab(caption: [The reasons of HTTPD908E])[
  #table(columns: (2.2in, 1fr),
    [Reason], [Cause],
    [#cmd("was not found")], [HTTPD 4.4.0: the LINK found the module in neither
      the STEPLIB nor the link list (completion code S806).],
    [#cmd("could not be loaded")], [HTTPD 4.3.0: the LINK could not load the
      module, for instance because no member #cmd("MVSMF") is in the STEPLIB.
      HTTPD 4.4.0 uses this text for every other load error. The message does not
      tell which library or why.],
    [#cmd("was dispatched without a program name")], [The route has no program.],
    [#cmd("could not be started, ESTAE create failed")], [HTTPD could not set up
      its recovery for the call.],
    [#cmd("returned rc n")], [The module returned a negative return code of its own, n.
      The launcher of a CGI module sets a negative return code of #cmd("main") to 0, so mvsMF does not
      cause this row.],
    [#cmd("failed with Snnn ABEND")], [A system abend that mvsMF did not
      handle itself.],
    [#cmd("failed with Unnnn ABEND")], [A user abend, for instance #cmd("U0801")
      when the C library cannot get the 64 KB stack of mvsMF (see “Running mvsMF”
      in the _mvsMF User's Guide_).],
  )
]

== HTTPD Messages at Start <ref-httpd-msgs>

#idx("messages", "HTTPD")
A start of HTTPD with the four routes of mvsMF writes these messages in this
order, and a stop writes the last two. The full list of messages is in the HTTPD
documentation.

#tab(caption: [HTTPD messages that show the state of mvsMF])[
  #table(columns: (0.8in, 1fr),
    [Message], [Meaning],
    [#cmd("HTTPD000I")], [HTTPD is starting. The message has the version and the
      commit of the build.],
    [#cmd("HTTPD005I")], [The version of the C library in HTTPD.],
    [#cmd("HTTPD002I")], [How HTTPD got its authorization.],
    [#cmd("HTTPD004I")], [The identity of the started task.],
    [#cmd("HTTPD036I")], [One message for each route of #cmd("MOD="): four
      messages, in the order of the route lines.],
    [#cmd("HTTPD054I")], [The port on which HTTPD listens.],
    [#cmd("HTTPD001I")], [HTTPD is ready. The listener works.],
    [#cmd("HTTPD098I")], [A #cmd("P HTTPD") was accepted. The quiesce has begun.],
    [#cmd("HTTPD099I")], [The shutdown is complete.],
  )
]
