#import "../bookmaster/bookmaster.typ": *

= Running mvsMF <ug-ops>

#idx("operating")#idx("started task")
mvsMF has no started task of its own. It is a module of HTTPD (httpd), and
HTTPD runs as a started task. The operator starts HTTPD, asks it questions and
stops it from the console, and mvsMF runs inside it. This chapter covers the
daily work: starting and stopping, how to see which build runs, the storage the
requests need, the replacement of the module, the places where messages go, and
what to check when requests fail. The installation is in @ug-install and the
removal in @ug-remove. The messages of mvsMF are listed in full in the _mvsMF
Reference_, in the appendix “Messages”. The procedure and the route lines are
described there in “Configuring HTTPD for mvsMF”.

== Starting and Stopping <ug-ops-start>

#idx("start")#idx("stop")#idx("procedure")
Start HTTPD from its cataloged procedure. The procedure of the sample has two
symbolic parameters for the configuration, #cmd("M") for the member and
#cmd("D") for the data set that holds it, and two for the identity of the task,
#cmd("STCUSER") and #cmd("STCGRP"):

```
/S HTTPD
/S HTTPD,M=HTTPPRM1
/S HTTPD,D='MY.PARMLIB'
```

Stop it with the command #cmd("/P HTTPD"). HTTPD answers
#cmd("HTTPD098I HTTPD SHUTTING DOWN") when it accepts the command and
#cmd("HTTPD099I HTTPD SHUTDOWN COMPLETE") when everything is released and the
address space ends.

A normal start of HTTPD 4.3.0 with the four route lines of mvsMF writes these
messages. The session reads them from the log of the console service
(@ug-console-log) and shows the last ten of them. The log reaches back only as
far as the master trace table does, so read it soon after the start. The user
needs READ access to the resource #cmd("MVSMF.CONSOLE")
(@ug-security-console):

#screen(raw(read("../ex/ug-ops/o-start.txt"), block: true))

The table explains them. #cmd("HTTPD000I") comes first and #cmd("HTTPD001I")
comes last:

#tab(caption: [The messages of a normal start of HTTPD with mvsMF])[
  #table(columns: (0.9in, 1fr),
    [Message], [Meaning],
    [#cmd("HTTPD000I")], [HTTPD is starting. The message has the version and the
      commit that HTTPD was built from.],
    [#cmd("HTTPD005I")], [The version of the C library that HTTPD is linked with.],
    [#cmd("HTTPD002I")], [How HTTPD got its authorization: by the library
      (module key 0) or by SVC 244 (module key 8). If neither works, HTTPD
      writes #cmd("HTTPD012E") and does not start (@ug-install-apf).],
    [#cmd("HTTPD004I")], [The identity of the started task. #cmd("HTTPD004W")
      means that the logon failed. HTTPD then runs with the identity it
      inherited.],
    [#cmd("HTTPD036I")], [One message for each line #cmd("MOD="). You expect four
      for mvsMF (@ug-install-routes).],
    [#cmd("HTTPD054I")], [HTTPD listens on the port.],
    [#cmd("HTTPD001I")], [HTTPD is ready. Clients can connect. The message has
      the version of HTTPD and the document root.],
  )
]

If one of the four #cmd("HTTPD036I") messages is missing, the request for its
path does not reach mvsMF. The messages #cmd("HTTPD411E") to #cmd("HTTPD425W")
come from the route lines. An unknown value after #cmd("AUTH=") ends the start
(#cmd("HTTPD420E ... HTTPD WILL NOT START")).

HTTPD 4.3.0 does not look for the module at the start. If it cannot load the
module, it finds out with the first request (@ug-ops-trouble). Look at the
STEPLIB before the first request.

#note[*Nothing starts mvsMF by itself.* A call of #cmd("MVSMF") from TSO or from
a batch job writes #cmd("MVSMF005E MVSMF MUST BE CALLED BY THE HTTPD SERVER")
and ends with the return code 12.]

The command #cmd("F HTTPD,HELP") lists the console commands of HTTPD. The
session sends the command through the console service of mvsMF and shows the
lines of HTTPD that come back:

#screen(raw(read("../ex/ug-ops/o-help.txt"), block: true))

Two of the commands help with mvsMF:

#tab(caption: [Commands of HTTPD that help with mvsMF])[
  #table(columns: (1.4in, 1fr),
    [Command], [Answer],
    [#cmd("F HTTPD,D C")], [The configuration that the running server uses: port
      and task limits (#cmd("HTTPD128I")), timeouts (#cmd("HTTPD129I"),
      #cmd("HTTPD130I"), #cmd("HTTPD135I")), document root, code page, realm,
      the SMF level, and the source of the configuration (#cmd("HTTPD133I")).],
    [#cmd("F HTTPD,D V")], [The version and the build of HTTPD
      (#cmd("HTTPD140I")).],
  )
]

#screen(raw(read("../ex/ug-ops/o-dc.txt"), block: true))

#screen(raw(read("../ex/ug-ops/o-dv.txt"), block: true))

The session shows HTTPD 4.3.0, which meets the floor of @ug-install-prereq. The
value #cmd("MAXTASK") in the first line of the configuration is the number of
worker tasks (@ug-ops-storage).

The procedure has these data definitions (the _mvsMF Reference_ lists them in
full): #cmd("STEPLIB") for the libraries, #cmd("HTTPPRM") for the configuration,
#cmd("HTTPDOUT") and #cmd("HTTPDERR") for the standard output and error, and the
optional #cmd("HASPCKPT") and #cmd("HASPACE1") for JES2 (@ug-install-jes). The
step of the sample runs with #cmd("REGION=8M") (@ug-ops-storage).

== Seeing the Running Build <ug-ops-build>

#idx("build")#idx("version")
After an install or a replacement you want to know which module serves the
requests. The request #cmd("GET /zosmf/info") answers #cmd("zosmf_full_version")
with the version that the module was built as. For a release this is the check:
a release has one version, and a module of another release shows another
version. A release does not register the diagnostic endpoint, so
#cmd("GET /zosmf/test?fn=version") answers 404 (@ug-first-build).

A development build, the module of #cmd("mbt deploy") whose version ends in
#cmd("-dev"), registers the endpoint. #cmd("GET /zosmf/test?fn=version") answers
the version and the build there. The build is the short commit that the module
was built from. A module built from a tree with uncommitted changes has the
suffix #cmd("-dirty"). This is the better check after a replacement of a
development build, because a rebuilt module has another build and the same
version.

The sessions of both builds are in @ug-first-build and in
@ug-install-verify.

#note[The version and the build are the answer of the module that ran. If it is
not the one you expect, another library comes first in the STEPLIB, or HTTPD has not been
restarted since the change (@ug-ops-replace).]

== Storage and Region <ug-ops-storage>

#idx("storage")#idx("region")#idx("U0801")
mvsMF runs in the address space of HTTPD. Its storage comes out of the region of
that started task, and each request needs a block of it for the C stack.

#deflist(width: 1.35in,
  [Region], [The sample procedure runs HTTPD with #cmd("REGION=8M"). Each request
    that runs at the same time needs a stack of its own, so the region has to
    hold the stacks of all the worker tasks that HTTPD runs together (the
    keyword #cmd("MAXTASK") of the HTTPD configuration, shown by
    #cmd("F HTTPD,D C")).],
  [Stack], [The module asks for a stack of 64 KB, plus the program properties
    area of the C library, when a request starts. The storage must be one
    contiguous block in subpool 0.],
  [When it fails], [The C library writes the message
    #cmd("@@CRT0 - No storage for C stack") and ends the module with the abend
    U0801. The client gets the answer 503, and HTTPD writes
    #cmd("HTTPD908E EXTERNAL PROGRAM MVSMF failed with U0801 ABEND").],
  [Other storage], [When mvsMF cannot get storage for a request, it writes
    #cmd("MVSMF006E STORAGE ALLOCATION FAILED FOR name"). The name says what the
    allocation was for.],
)

The remedy for a U0801 is more region or less fragmented storage. Free storage
that is split into pieces smaller than the stack does not help. The request
#cmd("GET /zosmf/test?fn=storage&sp=0") reports the largest contiguous free block
of a subpool. A release does not have the request: only a development build,
whose version ends in #cmd("-dev"), registers the test service, which the
_mvsMF Reference_ describes. The option
#cmd("total=1") makes the service hold all the free storage for a short time,
so use it between load runs and never during one.

mvsMF before 1.3.0 lost a block of 128 bytes of the C startup in subpool 0 at the
end of each request, so each request took a little storage from HTTPD for good.
The library under mvsMF 1.3.0 and 1.4.0 frees the block.

== Replacing the Module <ug-ops-replace>

#idx("restart")#idx("RESIDENT")#idx("module", "replacement")
HTTPD enters the module #cmd("MVSMF") with a LINK for each request. HTTPD
releases before 4.4.0 fetch the module from the library for every request.
HTTPD 4.4.0 loads every module of a #cmd("MOD=") line once at the start and
holds it until it ends. This is its default, #cmd("RESIDENT=YES"). With
#cmd("RESIDENT=NO") it fetches the module for every request, as the earlier
releases do. The STEPLIB of the started task is fixed when the task starts.
The procedure for a replacement is the same for every version: stop HTTPD and
start it again. The steps:

+ Put the new module in the library (the SMP install of @ug-install-job).
+ Stop HTTPD with #cmd("/P HTTPD") and wait for #cmd("HTTPD099I").
+ Start HTTPD with #cmd("/S HTTPD").
+ Check the build (@ug-ops-build).

Use the same order for an upgrade. @ug-install-upgrade lists the further steps for
the upgrade from 1.3.0. The route lines are also read at the start, so a change
of the HTTPD member takes effect with the same restart.

== Where the Log Is <ug-ops-log>

#idx("log")#idx("messages")#idx("HTTPDOUT")
mvsMF writes no log file. It reports to the operator through the console,
and to the client through the answer. A message of mvsMF starts with
#cmd("MVSMF") and a number, and ends with a letter for the severity: #cmd("I")
information, #cmd("W") warning, #cmd("E") error. The ranges are:

#tab(caption: [The ranges of mvsMF messages])[
  #table(columns: (1.0in, 1fr),
    [Range], [Area],
    [#cmd("MVSMF0xx")], [The router and the entry of the module.],
    [#cmd("MVSMF1xx")], [Data sets.],
    [#cmd("MVSMF2xx")], [Jobs and the JES2 interface.],
    [#cmd("MVSMF9xx")], [Recovery after an abend, and diagnostics.],
  )
]

The ranges #cmd("MVSMF3xx") for the UFS files and #cmd("MVSMF4xx") for the
console services hold no message in 1.4.0. A message of mvsMF is for what an
operator can act on. What a client causes, for
example a missing parameter or a data set that does not exist, goes into the
answer to the client and nowhere else. The _mvsMF Reference_ lists every message
in the appendix “Messages”.

Where you read the messages:

- The system log shows every message of mvsMF and of HTTPD.
- The data definitions #cmd("HTTPDOUT") and #cmd("HTTPDERR") of the HTTPD
  procedure are the standard output and the standard error of the server and of
  the modules that run in it. Look into them for HTTPD output that is not a
  message.
- The console service of mvsMF reads the master trace table, so the messages of
  mvsMF come back in the answers of that service and in its hardcopy log
  (@ug-console).

== When Requests Fail <ug-ops-trouble>

#idx("troubleshooting")#idx("503")#idx("401")#idx("403")
The table lists what you see, the likely cause, and where to look. Each row is
derived from the code of HTTPD and mvsMF. The status is what the client gets.

#tab(caption: [Symptoms and causes])[
  #table(columns: (1.9in, 1fr),
    [Symptom], [Cause and remedy],
    [503, body #cmd("External program MVSMF could not be loaded"), and
      #cmd("HTTPD908E") on the console], [HTTPD does not find the member
      #cmd("MVSMF") in its STEPLIB. Check that #cmd("MVSMF.LINKLIB") is in the
      STEPLIB of the running task, that it has the member, and that the library
      was not scratched. Read the STEPLIB from the job of the running HTTPD, not
      from the procedure library.],
    [503, #cmd("failed with U0801 ABEND")], [No contiguous storage for the stack
      of 64 KB (@ug-ops-storage). Give HTTPD more region, or restart it.],
    [503, #cmd("failed with Snnn ABEND") or #cmd("failed with Unnnn ABEND")], [An
      abend that mvsMF did not handle. Look at the messages #cmd("MVSMF901E") and
      #cmd("MVSMF913I") before it.],
    [503, #cmd("returned rc n")], [The module ended with a negative return code of
      its own. The code is the number in the message.],
    [A request for a path under #cmd("/zosmf/") is answered like a static file
      and not by mvsMF], [No route matched. Check that the four
      #cmd("HTTPD036I") messages appeared at the start, and that the path has
      lower case letters: the pattern #cmd("/zosmf/*") does not match
      #cmd("/ZOSMF/..."). Route lines are tested in order and the first match
      wins (@ug-install-routes).],
    [401 for a request with a user ID and password], [HTTPD or mvsMF found no
      valid credential. Check the user ID and password with another service of
      the system.],
    [401 on #cmd("/zosmf/info") without a credential], [This is the intended
      answer (@ug-install-verify).],
    [403, body #cmd("403 Forbidden")], [The route has a #cmd("RES=") option and
      the user has no READ access to the resource. Define the permission
      (@ug-security).],
    [A route with #cmd("RES=") lets everyone in], [The profile does not exist.
      HTTPD wrote #cmd("HTTPD425W") at the start, and does not gate the route
      without it.],
    [The jobs service fails; #cmd("MVSMF201E") on the console], [mvsMF cannot
      open the JES2 checkpoint and spool data sets (@ug-install-jes).],
    [A job is not submitted; #cmd("MVSMF204E"), #cmd("MVSMF205E") or
      #cmd("MVSMF206E")], [The internal reader of JES2 could not be opened,
      written or closed.],
    [Every request for a list of data sets waits and gets no answer;
      #cmd("MVSMF916W") on the console], [A list abended while it held the lock
      that makes the lists take turns, and the release of the lock abended too.
      The lock stays held, and each later list waits for it with no limit. Each
      waiting list occupies a worker of HTTPD. The other routes are not
      affected. Restart HTTPD.],
    [A user sees only the jobs of their own], [The class #cmd("JESSPOOL") has no
      profile that gives them READ access to the others (@ug-security).],
    [A request for a UFS file fails with 503], [UFSD is not running, or HTTPD
      started without UFS (@ug-uss).],
    [After an install the old behavior stays], [HTTPD has not been restarted, or the
      STEPLIB names another library first (@ug-ops-replace). With HTTPD 4.4.0 or
      later the running server also holds the module it loaded at the start.],
    [HTTPD does not start; #cmd("HTTPD012E")], [HTTPD is not authorized
      (@ug-install-apf).],
    [HTTPD does not start; #cmd("HTTPD411E") and #cmd("HTTPD420E")], [A route line
      has an #cmd("AUTH=") value that HTTPD does not know. Correct the line.],
  )
]
