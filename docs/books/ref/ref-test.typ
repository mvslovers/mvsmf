#import "../bookmaster/bookmaster.typ": *

= The Diagnostic Endpoint <ref-test>

#idx("/zosmf/test")
#idx("diagnostic endpoint")
The diagnostic endpoint is an internal route of mvsMF that is not part of
z/OSMF. It exists to look at the running system from outside: the build that is
loaded, the catalog, the Master Trace Table, the storage of the address space,
the JES2 spool, the security product. It also holds functions that cause
a failure on purpose, to test the recovery of mvsMF.

Read @ref-test-cmd and @ref-test-access before you decide to leave the
endpoint in a production system.

== The Request <ref-test-req>

#idx("fn")
The request is

#screen(raw("GET /zosmf/test?fn=NAME&parameter=value..."))

The query parameter #cmd("fn") selects the function. If it is missing, or if
its value is not a name in this chapter, the answer is the help text of
@ref-test-help. The other parameters depend on the function. The route is a
GET only. Like every route under #cmd("/zosmf/") it needs a credential
(@ref-auth-cred).

A second route, #cmd("GET /zosmf/test/wildcard/{*filepath}"), tests the
matching of a path with the rest of the path in one variable. It answers 200
with #cmd("application/json") and the body

#screen(raw("{ \"handler\": \"testWildcard\", \"filepath\": \"the/rest/of/the/path\" }"))

The value of #cmd("filepath") is the rest of the path after
#cmd("/zosmf/test/wildcard/"), or the text #cmd("(null)") if the variable is
empty.

== The Build Option <ref-test-build>

#idx("MVSMF_NO_TEST_ENDPOINT")
Both routes are registered unless mvsMF is compiled with the option
#cmd("-DMVSMF_NO_TEST_ENDPOINT"). Without the routes a request for
#cmd("/zosmf/test") is a request for an unknown route and gets the 404 of
@ref-conv-fixed. The shipped module is built without the option, so the
endpoint is present. This is on purpose: the functions #cmd("version") and
#cmd("storage") serve the operation of mvsMF (@ref-test-version,
@ref-test-storage).

== Who May Use It <ref-test-access>

#idx("security", "diagnostic endpoint")
The endpoint has no gate of its own. There is no setting that enables or
disables a single function. The functions #cmd("syslog"), #cmd("job") and
#cmd("spool") apply the spool policy of the job routes (see the jobs chapter),
and no other function checks authorization in mvsMF. Every user that HTTPD lets reach the route can call every function.
With the shipped route lines (@ref-httpd) that is every user with a valid
credential, or every user that holds the permission of the #cmd("RES=") profile
if the operator has put one on the route #cmd("/zosmf/*").

The only way to close the endpoint is to restrict the route in HTTPD or to
build mvsMF with #cmd("-DMVSMF_NO_TEST_ENDPOINT").

#note[*A defect* (mvsmf\#460): The console routes are gated by a route line of
their own with #cmd("RES=FACILITY:MVSMF.CONSOLE") (@ref-httpd). The functions
#cmd("cmd") and #cmd("mtt") of this endpoint do the work of the console routes,
but their route is #cmd("/zosmf/test"), which the catch-all line
#cmd("/zosmf/*") matches. HTTPD does not check the console profile for them.
A user without access to the console routes can issue an operator command
through #cmd("fn=cmd") and read the Master Trace Table through #cmd("fn=mtt").
A build with #cmd("-DMVSMF_NO_TEST_ENDPOINT") does not register the routes and
has no such path.]

Several functions show data of the system and the caller beyond the user's
own permissions:

- #cmd("mtt") and #cmd("cmd") return lines of the Master Trace Table,
  whoever wrote them.
- #cmd("listds") and #cmd("locate") read the catalog and #cmd("dscb") the
  volume table of contents, without a RACF check for the data set.
- #cmd("password") returns the password of the caller, if the caller asks for
  it.
- #cmd("env") lists the names of the environment variables of the server.

== Response Format <ref-test-resp>

#idx("response format", "diagnostic endpoint")
Except for #cmd("abend"), #cmd("jesabend") and #cmd("denyopen"), every function
answers 200 with the header #cmd("Content-Type: application/json") and a body
that is sent in chunks (#cmd("Transfer-Encoding: chunked")), not with a
#cmd("Content-Length"). The status 200 does not say that the function worked.
Errors of a function are in the body.

The body is a JSON object for most functions. The functions #cmd("syslog"),
#cmd("mtt") and #cmd("cmd") send plain text lines, although the header says
JSON. Their last line is #cmd("DONE step=N") (#cmd("DONE") for #cmd("cmd")). The
function #cmd("cmd") ends without it when it does not get the console lock
(@ref-test-cmd).

The three functions that fail on purpose answer before any byte of a response
is sent, so the router can send its error report (@ref-conv-fixed).

== The Functions <ref-test-fn>

@ref-test-fntab lists every function. The sections that follow describe them.

#tab(caption: [Functions of the diagnostic endpoint])[
  #table(columns: (0.95in, 1.9in, 1fr),
    [#cmd("fn")], [Parameters (default)], [Purpose],
    [#cmd("help")], [none], [List the functions (@ref-test-help).],
    [#cmd("version")], [none], [The version and the build id.],
    [#cmd("listds")], [#cmd("level") (#cmd("SYS1")), #cmd("filter")], [List
      cataloged non-VSAM data sets.],
    [#cmd("locate")], [#cmd("dsn") (#cmd("SYS1.MACLIB"))], [Catalog lookup.],
    [#cmd("dscb")], [#cmd("dsn") (#cmd("SYS1.MACLIB"))], [Format-1 DSCB.],
    [#cmd("userid")], [none], [The user ID of the request, read two ways.],
    [#cmd("token")], [none], [Whether a session token exists.],
    [#cmd("password")], [#cmd("reveal") (0)], [The password export of HTTPD.],
    [#cmd("env")], [none], [The environment of the module.],
    [#cmd("storage")], [#cmd("sp") (0), #cmd("total") (off)], [Free storage.],
    [#cmd("syslog")], [#cmd("step") (0)], [Probe the JES2 SYSLOG job.],
    [#cmd("mtt")], [#cmd("step") (3), #cmd("hdr") (0)], [Dump the Master Trace
      Table.],
    [#cmd("cmd")], [#cmd("cmd") (#cmd("D T"))], [Issue an operator command.],
    [#cmd("job")], [#cmd("jobname") (required)], [Completion data of the jobs
      with a name.],
    [#cmd("spool")], [#cmd("jobname"), #cmd("jobid") (required),
      #cmd("dsid") (1), #cmd("maxblk") (4), #cmd("len") (1024)], [Dump spool
      blocks.],
    [#cmd("intrdr")], [#cmd("n") (1)], [Open and close the internal reader.],
    [#cmd("checkauth")], [#cmd("dsn") (#cmd("SYS1.PARMLIB")), #cmd("class")
      (#cmd("DATASET")), #cmd("attr") (#cmd("read")), #cmd("via")
      (#cmd("raw"))], [Ask the security product.],
    [#cmd("textsum")], [none], [Checksums of the loaded module.],
    [#cmd("textdump")], [#cmd("off") (0), #cmd("len") (64)], [Bytes of the loaded
      module.],
    [#cmd("abend")], [none], [Fail with S0C1.],
    [#cmd("jesabend")], [none], [Fail with S0C1 with a JES handle open.],
    [#cmd("denyopen")], [#cmd("dsn") (#cmd("SYS1.SECURE.CNTL(PROFILES)"))],
      [Open a data set without a check, to provoke S913.],
  )
] <ref-test-fntab>

=== help <ref-test-help>

#idx("fn", "help")
The answer is a JSON object with the field #cmd("fn") (#cmd("help")) and the
field #cmd("usage"), an array of 19 sentences. Each sentence shows the form of
one request. The list does not contain #cmd("env"), #cmd("help") or #cmd("jesabend"). A value of #cmd("fn")
that mvsMF does not know gives the same answer.

=== version <ref-test-version>

#idx("fn", "version")
The answer is

#screen(raw("{ \"fn\": \"version\", \"version\": \"1.4.0\", \"build\": \"a1b2c3d\" }"))

The #cmd("version") is the version of the build. The #cmd("build") is the short
identifier of the source commit that the module was built from. It ends with
#cmd("-dirty") if a tracked file differed from the commit at build time. After a
deploy, the value shows which build is loaded.

=== listds <ref-test-listds>

#idx("fn", "listds")
The function lists the cataloged non-VSAM data sets whose names begin with
the high-level qualifier #cmd("level"), optionally cut down by the pattern
#cmd("filter"). The default level is #cmd("SYS1"). The answer is

#screen(raw("{ \"fn\": \"listds\", \"level\": \"SYS1\", \"filter\": \"(null)\", \"nomem\": 0,
  \"items\": [ { \"dsn\": ..., \"vol\": ..., \"dsorg\": ..., \"recfm\": ...,
                 \"lrecl\": ..., \"blksize\": ... }, ... ], \"count\": N }", block: true))

The field #cmd("filter") is the text #cmd("(null)") if the request has no
filter. The field #cmd("nomem") is 1 if the catalog search ended for lack of
storage, and 0 otherwise. An empty level and a lack of storage differ in this
field only. The function takes the lock that makes the data set lists take
turns (@ref-ds-list-turns).

=== locate <ref-test-locate>

#idx("fn", "locate")
The function looks up #cmd("dsn") in the catalog and answers

#screen(raw("{ \"fn\": \"locate\", \"dsn\": \"SYS1.MACLIB\", \"rc\": 0, \"volser\": \"...\" }"))

The field #cmd("rc") is the return code of the catalog search. The field
#cmd("volser") is the volume serial that it found.

=== dscb <ref-test-dscb>

#idx("fn", "dscb")
The function reads the format-1 DSCB of #cmd("dsn") from its volume. It
changes nothing. The answer has these fields, in this order:

#deflist(width: 1.8in,
  [#cmd("fn"), #cmd("dsn")], [As in the request.],
  [#cmd("locate_rc"), #cmd("dscb_rc")], [The return codes of the catalog search
    and of the read.],
  [#cmd("volser")], [The volume.],
  [#cmd("lrecl"), #cmd("blksize")], [Record length and block size.],
  [#cmd("extents"), #cmd("spacu")], [The number of extents and the space unit.],
  [#cmd("secondary")], [The secondary allocation.],
  [#cmd("lstar_tt"), #cmd("lstar_r")], [The last-written-record pointer.],
  [#cmd("dscb4_rc")], [The return code of the read of the format-4 DSCB.],
  [#cmd("devtk"), #cmd("devov"), #cmd("devk"), #cmd("devfg"),
   #cmd("dstrk")], [Device data from the format-4 DSCB.],
  [#cmd("blocks_per_track")], [The blocks per track for the block size on this
    device. The jobs and data set routes use the same computation.],
)

=== userid <ref-test-userid>

#idx("fn", "userid")
The function compares two ways to read the user ID of the request: the HTTPD
export and a direct decode of the ACEE. The answer has the fields
#cmd("acee") (#cmd("non-null") or #cmd("NULL")), #cmd("direct_from_acee") (the
user ID from the ACEE), #cmd("http_get_userid_ret"), #cmd("strlen") and
#cmd("hex") (the 64 bytes of the buffer in hex).

=== token <ref-test-token>

#idx("fn", "token")
The function tells whether HTTPD holds a token for the request. The answer has
the fields #cmd("toklen") (the length of the token, 0 if none),
#cmd("have_token"), #cmd("sent_authorization"), #cmd("sent_cookie") (true or
false) and #cmd("note"). The value of the token is never shown.

=== password <ref-test-password>

#idx("fn", "password")
The function exercises the export of HTTPD that returns the password of the
caller. The answer has the fields #cmd("http_get_password_ret"),
#cmd("strlen") and #cmd("value"). Without #cmd("reveal=1") the #cmd("value") is
a string of asterisks as long as the password, so the answer shows the length.
With #cmd("reveal=1") the #cmd("value") is the password of the caller in
plain text. The password then appears in the response, in any proxy log and in
the terminal of the caller. Any other value of #cmd("reveal") masks the
password.

=== env <ref-test-env>

#idx("fn", "env")
The function lists the environment that the module loaded for this request.
The answer has the fields #cmd("grt"), #cmd("grtenv"), #cmd("count") and
#cmd("items"), an array of objects with the field #cmd("name"). Objects for
variables whose name begins with #cmd("MVSMF_") have the field #cmd("value")
too. The values of all other variables are not shown.

=== storage <ref-test-storage>

#idx("fn", "storage")
#idx("storage", "free")
The function samples the free storage of the address space of HTTPD. It
finds the largest block that a GETMAIN in subpool #cmd("sp") would get, by
probing in steps of 4096 bytes. The subpool is a number from 0 to 127 (default
0). A value outside this range gives the answer

#screen(raw("{ \"fn\": \"storage\", \"error\": \"sp must be 0..127; subpools above 127 need supervisor state\" }"))

The answer for a valid subpool has these fields:

#deflist(width: 1.35in,
  [#cmd("sp")], [The subpool.],
  [#cmd("largest")], [The size in bytes of the largest block, in steps of
    4096.],
  [#cmd("largest_at")], [Its address, as hex text.],
  [#cmd("link_stack")], [The size in bytes of the block that the start of this
    request obtained for its C stack, read back from the running task. Every
    request needs one free block of this size. If #cmd("largest") is smaller,
    the next request fails with S80A before mvsMF starts.],
  [#cmd("granularity")], [4096.],
  [#cmd("stack_at")], [The address of the stack of this request.],
  [#cmd("total"), #cmd("blocks"), #cmd("truncated"), #cmd("sizes")], [Only
    with #cmd("total=1") (also #cmd("y") or #cmd("Y")). The total of all free
    blocks, their number, whether the count was cut (the function holds at most 256 blocks), and
    up to 32 block sizes.],
  [#cmd("probes"), #cmd("free_errors")], [The number of probes, and the number
    of blocks that could not be freed again.],
)

#note[With #cmd("total=1") the function holds all free storage of the address
space for a short time. Other requests that need storage fail in that time.
Never use it while the system is under load.]

=== syslog <ref-test-syslog>

#idx("fn", "syslog")
The function probes the JES2 job named #cmd("SYSLOG"), step by step. The
parameter #cmd("step") (0 to 5, default 0) says how far it goes. Each step
includes the steps before it. It prints plain text lines:

#tab(caption: [Steps of the SYSLOG probe])[
  #table(columns: (0.6in, 1fr),
    [Step], [Line printed],
    [0], [#cmd("syslog probe step=N: START"). Nothing else.],
    [1], [Opens JES2: #cmd("step1 jesopen -> OK") or #cmd("step1 jesopen -> NULL").],
    [2], [Looks for jobs named SYSLOG: #cmd("step2 jesjob -> OK count=N"). The
      count holds only the jobs that the user may read.],
    [3], [One line per job: #cmd("step3 entry N jobid=... jesdd=set"). The value
      is #cmd("NULL") if the job has no output data set list.],
    [4], [One line per output data set of each job:
      #cmd("step4 entry N dd M dsid=... mttr=... records=...").],
    [5], [The records of each output data set, between the marker line
      #cmd("----- jobid=... dd=... dsid=... -----") and a closing line
      #cmd("----- rc=... reason=... blocks=... lines=... mttr=... records=... -----").],
  )
]

The last line is #cmd("DONE step=N"). The spool policy of the job routes
applies: the probe shows only jobs that the user may read (see the jobs
chapter).

=== mtt <ref-test-mtt>

#idx("fn", "mtt")
The function takes a snapshot of the Master Trace Table and prints it as plain
text. The first line is #cmd("mtt probe step=N START"). The parameter
#cmd("step") (default 3) selects how far it goes: step 1 creates the snapshot
(#cmd("step1 cmtt_new -> OK")), step 2 prints the number of entries
(#cmd("step2 get_array -> OK count=N")) and step 3 prints every entry, one per
line. With #cmd("hdr=1") each entry line starts with the 8-byte header of the
entry in hex (in the groups 2, 2 and 4 bytes) and the length of the entry, then
a bar. The last line is #cmd("DONE step=N").

=== cmd <ref-test-cmd>

#idx("fn", "cmd")
#idx("operator command")
The function issues an operator command. This is a function of its own, outside
the console routes (@ref-cons). The command is the value of the parameter
#cmd("cmd"), default #cmd("D T"), cut at 100 characters.

mvsMF issues the command with SVC 34, in supervisor state with key 0 for the
duration of the SVC. It is the same mechanism as the console route. The
function takes the same lock as the console route, so a command of the console
route and this function do not mix their output. If it does not get the lock, it
prints #cmd("cmd probe: console lock busy, not issuing") and issues nothing.

The function prints #cmd("cmd probe: issuing 'TEXT' via SVC 34 (MGCR)"),
then polls the Master Trace Table up to 15 times until it finds the text of the
command in the last 40 entries. It prints the line
#cmd("MTT count=N after P poll(s), tail:") and the last 50 lines of the table.
The last line is #cmd("DONE").

Every user that reaches the route can issue any operator command with this
function. mvsMF makes no check of its own, and the user ID of the caller is
not used. The command runs with the authority of the address space, as for
the console routes (@ref-cons). The console routes have a gate in HTTPD for
this reason; this function does not (@ref-test-access).

=== job <ref-test-job>

#idx("fn", "job")
The function shows the raw completion data of the jobs with the name in
#cmd("jobname"). It reads only. Only jobs that the spool policy lets the user
read are shown. Without #cmd("jobname") the answer is
#cmd("{ \"fn\": \"job\", \"error\": \"jobname= required\" }"); if the JES2
access cannot be opened, the error is #cmd("jesopen failed").

The answer has the fields #cmd("fn"), #cmd("jobname"), #cmd("count") and
#cmd("items"). Each item has the fields #cmd("jobid"), #cmd("q_type"),
#cmd("q_flag1"), #cmd("q_flag2"), #cmd("completion") (8 hex digits),
#cmd("comp_hi"), #cmd("abend"), #cmd("maxcc"), #cmd("jtflg"), the flags
#cmd("JF"), #cmd("CF") and #cmd("ABD"), and #cmd("retcode"), the text that the
job status route would show (such as #cmd("CC 0000"), #cmd("JCL ERROR") or
#cmd("(null)")). The field #cmd("count") is the number of items, that is, of
the jobs that the user may read.

=== spool <ref-test-spool>

#idx("fn", "spool")
The function dumps blocks of the spool data set of one output data set of
one job, in hex. It reads only. The parameters:

#deflist(width: 1.35in,
  [#cmd("jobname"), #cmd("jobid")], [Required.],
  [#cmd("dsid")], [The data set id in the job. Default 1.],
  [#cmd("maxblk")], [The number of blocks. Default 4, at least 1, at most 16.],
  [#cmd("len")], [The number of bytes of each block. Default 1024, cut to the
    spool buffer size.],
)

The answer has the fields #cmd("fn"), #cmd("jobname"), #cmd("jobid"),
#cmd("jobkey"), #cmd("bufsize"), #cmd("dumped"), the object #cmd("dd") (fields
#cmd("ddname"), #cmd("dsid"), #cmd("recfm"), #cmd("lrecl"), #cmd("records"),
#cmd("mttr"), #cmd("flag")), the array #cmd("blocks") (each with #cmd("mttr"),
#cmd("next"), #cmd("jobkey"), #cmd("dsid") and #cmd("hex")) and
#cmd("blocks_read"). A block that cannot be read has the field #cmd("error")
with the text #cmd("spool_read failed").

The error answers are #cmd("jobname= and jobid= required"),
#cmd("jesopen failed"), #cmd("no checkpoint or spool handle"),
#cmd("job not found"), #cmd("no such dsid"), #cmd("implausible BUFSIZE N") and
#cmd("out of storage"). Only jobs that the spool policy lets the user read can
be found.

=== intrdr <ref-test-intrdr>

#idx("fn", "intrdr")
The function opens and closes the JES2 internal reader #cmd("n") times (1 to
25, default 1) and writes nothing to it, so JES2 creates no job. The answer is

#screen(raw("{ \"fn\": \"intrdr\", \"cycles\": N, \"ok\": N, \"open_rc\": 0, \"close_errors\": 0, \"first_close_rc\": 0 }"))

A failed open ends the loop. #cmd("ok") is the number of completed cycles.

=== checkauth <ref-test-checkauth>

#idx("fn", "checkauth")
The function asks the security product whether the caller may access a
resource. The parameters are the resource name #cmd("dsn"), the class
#cmd("class"), the access #cmd("attr") (#cmd("read"), #cmd("update"),
#cmd("control") or #cmd("alter")) and the path #cmd("via"): #cmd("raw") calls
the RACF interface of the C library, #cmd("vector") calls the check of HTTPD
and #cmd("both") calls both. An #cmd("attr") that is not one of the four values
is reported in the answer and is not treated as #cmd("read"). The answer has
the fields #cmd("class"), #cmd("resource"), #cmd("attr"), #cmd("attr_value"),
#cmd("via"), #cmd("acee"), #cmd("racf_auth_rc") and #cmd("http_check_auth_rc").
A call that was not made shows a marker value in its field: #cmd("-901") if
the call was not made (not requested by #cmd("via"), or an unknown #cmd("attr")), #cmd("-902") if there is no ACEE to
check against (#cmd("racf_auth_rc") only), and #cmd("-903") in
#cmd("attr_value") for an #cmd("attr") that is not known.
The function only asks. A denial is still logged by the security product.

=== textsum and textdump <ref-test-text>

#idx("fn", "textsum")
#idx("fn", "textdump")
These two functions look at the module as it is loaded, to find out if the copy
in storage is the copy that was linked.

#cmd("textsum") answers with the fields #cmd("build"), #cmd("load") (the load
address), #cmd("len"), #cmd("entry"), #cmd("cde"), #cmd("use") (the use count of
the module), #cmd("block") (4096) and #cmd("sums"), an array with one checksum
(FNV-1a, 8 hex digits) for each block of 4096 bytes. If there is no CDE for
the module, the answer is #cmd("{ \"fn\": \"textsum\", \"error\": \"no CDE for this copy of MVSMF\" }").

#cmd("textdump") answers with the fields #cmd("build"), #cmd("load"),
#cmd("off"), #cmd("len") and #cmd("hex"). The parameter #cmd("off") is a
hexadecimal offset from the load address. The parameter #cmd("len") is 1 to 256
(default 64). The function reads only inside the module, and a read that abends
costs this answer only. The error answers are the CDE error above,
#cmd("off (hex) and len (1..256) must lie inside the module, length N") and
#cmd("read abended, CODE").

=== abend <ref-test-abend>

#idx("fn", "abend")
The function writes the operator message MVSMF906W and then fails on purpose
with an operation exception (S0C1). The recovery of mvsMF catches it. The
client gets status 500 and the abend report of @ref-conv-fixed with the text
#cmd("Internal server error (abend S0C1)"). The operator also sees MVSMF901E
and, when the PSW is known, MVSMF913I and MVSMF914I (@apx-messages).

=== jesabend <ref-test-jesabend>

#idx("fn", "jesabend")
The function opens a JES2 handle, registers it, writes MVSMF906W and then
fails with S0C1. The recovery closes the handle and writes MVSMF908I. The
client sees the same report as for #cmd("abend"). If the JES2 handle cannot be
opened, the answer is status 500 with category 6, rc 16, reason 0 and the
message #cmd("jesopen() failed, nothing to leak").

=== denyopen <ref-test-denyopen>

#idx("fn", "denyopen")
The function opens the data set #cmd("dsn") for reading without the check for
authorization that the data set routes make. For a user that RACF refuses, the
open ends with the abend S913, and the client gets the authorization report of
@ref-conv-fixed. If the open works, the answer is status 400 with the message
#cmd("fn=denyopen: the data set opened, so nothing was denied. Use an id that may not read it."). If the open fails without an abend, the answer is status 400 with
the message #cmd("fn=denyopen: the open failed without abending, so it was not a denial.").
