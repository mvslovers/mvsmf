#import "../bookmaster/bookmaster.typ": *

= Conventions <ref-conv>

#idx("conventions")
This chapter describes what holds for every request that mvsMF answers: how
a URL is built, which methods and headers mean something, which status codes
appear, what an error report looks like, which codepage is used, and where the
limits are. The chapters for the single areas refer to it and do not repeat it.

mvsMF is a clone of the z/OSMF REST interface. It follows the z/OSMF shape of
requests, responses and error reports where the code does, and this chapter
says where it does not. "The server" in this chapter means HTTPD (httpd)
together with the mvsMF module that it starts for each request.

== URL Structure <ref-conv-url>

#idx("URL")
#idx("route")
Every URL has the form

#screen(raw("scheme://host:port/zosmf/area/...?query"))

The path always starts with #cmd("/zosmf/"). The next part names the area.
@ref-conv-routes lists every route that mvsMF registers, with the methods that
it accepts. The last column names the chapter that describes the route.

#tab(caption: [Routes of mvsMF])[
  #table(columns: (0.95in, 1fr, 0.8in),
    [Method], [Path], [Chapter],
    [GET], [#cmd("/zosmf/info")], [@ref-auth],
    [POST, DELETE], [#cmd("/zosmf/services/authenticate")], [@ref-auth],
    [GET], [#cmd("/zosmf/test")], [@ref-test],
    [GET], [#cmd("/zosmf/test/wildcard/{*filepath}")], [@ref-test],
    [GET], [#cmd("/zosmf/restfiles/ds")], [@ref-ds],
    [GET, PUT, POST, DELETE], [#cmd("/zosmf/restfiles/ds/{dataset-name}")], [@ref-ds],
    [GET], [#cmd("/zosmf/restfiles/ds/{dataset-name}/member")], [@ref-ds],
    [GET, PUT, DELETE], [#cmd("/zosmf/restfiles/ds/{dataset-name}({member-name})")], [@ref-ds],
    [GET], [#cmd("/zosmf/restfiles/fs")], [@ref-uss],
    [GET, PUT, POST, DELETE], [#cmd("/zosmf/restfiles/fs/{*filepath}")], [@ref-uss],
    [GET, PUT], [#cmd("/zosmf/restjobs/jobs")], [@ref-jobs],
    [GET, DELETE], [#cmd("/zosmf/restjobs/jobs/{job-name}/{jobid}")], [@ref-jobs],
    [GET], [#cmd("/zosmf/restjobs/jobs/{job-name}/{jobid}/files")], [@ref-jobs],
    [GET], [#cmd("/zosmf/restjobs/jobs/{job-name}/{jobid}/files/{ddid}/records")], [@ref-jobs],
    [PUT], [#cmd("/zosmf/restconsoles/consoles/{console-name}")], [@ref-cons],
    [GET], [#cmd("/zosmf/restconsoles/consoles/{console-name}/solmsgs/{cmd-response-key}")], [@ref-cons],
    [GET], [#cmd("/zosmf/restconsoles/consoles/{console-name}/detections/{detection-key}")], [@ref-cons],
    [GET], [#cmd("/zosmf/restconsoles/v1/log")], [@ref-cons],
  )
] <ref-conv-routes>

The table has 29 routes, counting each method. The two routes under
#cmd("/zosmf/test") exist only in a build without
#cmd("-DMVSMF_NO_TEST_ENDPOINT") (@ref-test-build). The HTTPD route lines that
decide who may reach the routes are in @ref-httpd.

A part of the path in braces is a variable. #cmd("{name}") takes the text up to
the next #cmd("/"), #cmd("(") or #cmd(")"). #cmd("{*name}") takes the rest of
the path, slashes included. Trailing blanks are cut from the value of a
variable.

The routes with a volume serial, such as
#cmd("/zosmf/restfiles/ds/-(volser)/{dataset-name}"), are not registered. A
request for one is a request for an unknown route (@ref-conv-errors).

=== Path decoding <ref-conv-path>

#idx("percent escape")
The router copies the path into a buffer of 1024 bytes, so it keeps at most
1023 characters. It decodes the percent escapes and translates the result from
ASCII to EBCDIC. A path variable can hold up to 1023 characters. The router
does not look at the query string. Each handler reads the parameters that it
knows.

=== Query parameters <ref-conv-query>

#idx("query parameter")
A handler ignores a query parameter that it does not know. Each area chapter
lists the parameters of its routes.

== Methods <ref-conv-methods>

#idx("method")
mvsMF knows four methods: GET, POST, PUT and DELETE. A route has one method
(@ref-conv-routes). Two rules follow from the router:

- A request with any other method, such as HEAD, OPTIONS or PATCH, gets status
  405 and no body. The router answers it before it looks at the credential, so
  a client that sent no credential gets the 405 and not a 401.
- A request with a known method for a path that is registered only under other
  methods, such as a PUT to #cmd("/zosmf/restfiles/ds"), gets 404 and the
  report of an unknown route (@ref-conv-fixed), not 405.

#note[*A defect* (mvsmf\#418): a method that is wrong for a known path answers
404 and not 405, and the 405 for an unknown method has no body.]

== Request Headers <ref-conv-headers>

#idx("request header")
HTTPD reads the headers of the request and passes them to mvsMF. mvsMF
evaluates the headers in @ref-conv-reqhdr. A header that is not in the table
has no effect, and the server does not reject a request for it. In particular
#cmd("X-CSRF-ZOSMF-HEADER") is accepted and ignored: mvsMF does not require it
and does not check its value.

#tab(caption: [Request headers that mvsMF evaluates])[
  #table(columns: (1.65in, 1fr),
    [Header], [Meaning],
    [#cmd("Authorization")], [#cmd("Basic") with a user ID and password, or
      #cmd("Bearer") with a token. HTTPD evaluates it before mvsMF runs
      (@ref-auth-cred). mvsMF reads the header to decide whether to set the
      session cookie (@ref-conv-resphdr).],
    [#cmd("Content-Type")], [Read by the routes that take a body: the console
      command, the job submit and the writes of data sets and files. The chapter
      of the area says what it must be.],
    [#cmd("Content-Length"), #cmd("Transfer-Encoding")], [Describe the request
      body. mvsMF reads a body with a length and a body with
      #cmd("Transfer-Encoding: chunked") (@ref-conv-limits).],
    [#cmd("Host")], [Read by #cmd("/zosmf/info") for the fields
      #cmd("zosmf_hostname") and #cmd("zosmf_port") (@ref-auth-info).],
    [#cmd("X-Forwarded-Proto"), #cmd("X-Forwarded-Port")], [Read by
      #cmd("/zosmf/info") when the #cmd("Host") header has no usable port
      (@ref-auth-info).],
    [#cmd("X-IBM-Data-Type")], [Data sets and UFS files: text or binary, and
      the encoding (@ref-conv-codepage).],
    [#cmd("X-IBM-Max-Items")], [Data set and UFS lists: the maximum number of
      items returned.],
    [#cmd("X-IBM-Return-Etag")], [Data sets, members and UFS files: ask for the
      ETag in the answer.],
    [#cmd("If-Match"), #cmd("If-None-Match")], [Data sets, members and UFS
      files: the ETag comparison.],
    [#cmd("X-IBM-Option")], [UFS routes: an option of the request.],
    [#cmd("X-IBM-Intrdr-Recfm"), #cmd("X-IBM-Intrdr-Lrecl"),
     #cmd("X-IBM-Intrdr-Mode")], [Job submit: the attributes of the
      internal reader.],
    [#cmd("X-MVSMF-Client"), #cmd("Sec-Fetch-Mode")], [They mark a request that
      comes from the script of a web page. They suppress the
      #cmd("WWW-Authenticate") header of a 401 (@ref-conv-401).],
  )
] <ref-conv-reqhdr>

The area chapters give the meaning of the area headers in full. HTTPD reads
more headers than these, for example #cmd("Cookie"). The table lists the
headers that mvsMF itself reads.

=== Response headers <ref-conv-resphdr>

#idx("response header")
Every response that mvsMF builds carries these headers:

#deflist(width: 2.1in,
  [#cmd("Cache-Control")], [#cmd("no-store")],
  [#cmd("Pragma")], [#cmd("no-cache")],
  [#cmd("X-Content-Type-Options")], [#cmd("nosniff")],
  [#cmd("Content-Language")], [#cmd("en")],
)

mvsMF sends no CORS header. A response with a body carries
#cmd("Content-Type") and #cmd("Content-Length"). A response that the handler
sends without a body has #cmd("Content-Length: 0"). A 204 and a 304 carry
neither header.

#idx("cookie", "LtpaToken2")
When the request has an #cmd("Authorization") header and HTTPD holds a token for
the credential, the response carries a cookie:

#screen(raw("Set-Cookie: LtpaToken2=<token>; Path=/; HttpOnly; SameSite=Strict"))

The cookie has no #cmd("Secure") attribute. The token stands for the credential
that HTTPD keeps for the user, the password and the client address.
@ref-auth-cookie describes it. A request that carries no #cmd("Authorization")
header, for example one that sends the token in a cookie, gets no cookie.

== Status Codes <ref-conv-status>

#idx("status code")
z/OSMF names a closed list of status codes for its REST services: 200, 204,
206, 304, 400, 401, 404, 405, 412, 413, 429, 500 and 503. mvsMF keeps within
that list, with one exception, status 201 for the create of a data set.
@ref-conv-statustab shows where each code appears.

#tab(caption: [Status codes that mvsMF sends])[
  #table(columns: (0.55in, 1fr),
    [Code], [Where mvsMF sends it],
    [200], [Success with a body. An empty list is also 200, with an empty
      #cmd("items") array. A list that was cut short is 200 and sets
      #cmd("moreRows").],
    [201], [Create of a data set (#cmd("POST /zosmf/restfiles/ds/{dataset-name}")).
      It is outside the z/OSMF list. mvsMF sends it because the reference
      system answers 201 for this request.],
    [204], [Success without a body: a write, a delete, and the logout.],
    [304], [A read whose ETag matches #cmd("If-None-Match"). The answer carries
      the ETag, also without #cmd("X-IBM-Return-Etag").],
    [400], [A request that the handler rejects: a missing or bad parameter, a
      bad body, a name that does not fit. An object that already exists and a
      directory that is not empty are also 400.],
    [401], [No credential, or a credential that RACF refuses
      (@ref-conv-401).],
    [404], [The object does not exist, the route does not exist, or the method
      is wrong for the route (@ref-conv-methods).],
    [405], [A method other than GET, POST, PUT or DELETE. No body.],
    [412], [An #cmd("If-Match") that does not match the ETag.],
    [413], [A request body of 16 MB or more (@ref-conv-limits).],
    [429], [Console: another command holds the correlation lock.],
    [500], [An error in the server, an I/O error, an abend, a denial by the
      security product, a full volume or a full file system.],
    [503], [Console: the server is quiescing. UFS routes: the UFSD subsystem is
      not available.],
  )
] <ref-conv-statustab>

mvsMF sends none of 206, 403, 409, 414 and 507:

- There is no 206. A list that exceeds the limit is cut, and the answer says
  so in #cmd("moreRows").
- There is no 403 from mvsMF. A user that the security product refuses gets a
  500 with category 4 (@ref-conv-fixed). HTTPD answers 403 itself for a route
  with a #cmd("RES=") check (@ref-conv-401).
- An object that already exists is 400, a full volume or file system is 500.

=== The 401 answer <ref-conv-401>

#idx("401")
#idx("WWW-Authenticate")
Two parties send a 401, and the two answers differ.

*HTTPD* sends the 401 for a route with #cmd("AUTH=TOKEN") (the route
#cmd("/zosmf/*") of the shipped configuration) when the request has no valid
credential. The answer has status 401, #cmd("Cache-Control: no-store"),
#cmd("Content-Type: text/plain") and the body #cmd("401 Unauthorized"). It has
no #cmd("WWW-Authenticate") header.

*mvsMF* sends the 401 for the routes with #cmd("AUTH=NONE") of the shipped
configuration (#cmd("/zosmf/info") and #cmd("/zosmf/services/authenticate")),
and for any route that reaches it without a credential. The answer has:

- status 401,
- #cmd("WWW-Authenticate: Basic realm=\"name\""), where the name is the
  #cmd("REALM") of the HTTPD parameters or, if there is none, the SMF system
  ID,
- no body and #cmd("Content-Length: 0"), except for a failed login, which has
  a JSON body (@ref-auth-login).

mvsMF leaves the #cmd("WWW-Authenticate") header out when the request comes
from the script of a web page: when it has the header #cmd("X-MVSMF-Client"),
or a #cmd("Sec-Fetch-Mode") header whose value is not #cmd("navigate"). The
header #cmd("X-CSRF-ZOSMF-HEADER") has no such effect.

When a #cmd("RES=") check of the route fails for an authenticated user, HTTPD
answers 403 with the body #cmd("403 Forbidden") as #cmd("text/plain"). mvsMF is
not involved. @ref-httpd describes the route lines.

== Error Reports <ref-conv-errors>

#idx("error report")
A failed request gets a JSON body. The shape depends on the area.

=== The report of data sets, files and jobs <ref-conv-report>

#idx("error report", "restfiles")
The data set routes, the UFS routes, the job routes and the router use one
shape:

#screen(raw("{\"rc\":4,\"category\":6,\"reason\":7,\"message\":\"Not Found\"}"))

#deflist(width: 1.35in,
  [#cmd("rc")], [A number. 4 is a warning, 8 an error, 16 a severe error.
    Two other values appear: 121 for an encoding error and 900 for a failed
    allocation.],
  [#cmd("category")], [A number that names the kind of error. The numbers are
    not a shared vocabulary (@ref-conv-categories).],
  [#cmd("reason")], [A number that names the error within its area.],
  [#cmd("message")], [A sentence. It is not always present.],
  [#cmd("details")], [An array of sentences. It is not always present.],
)

The fields come in this order. The report goes out with the HTTP status of
the error and with #cmd("Content-Type: application/json").

The writer of the report does not escape the text of #cmd("message"). A message
with a double quote in it, or one of more than about 250 characters, can give
a JSON document that does not parse. The messages of mvsMF itself avoid both.

=== Reports with a fixed content <ref-conv-fixed>

Some conditions have the same report in every area:

#tab(caption: [Reports that every area shares])[
  #table(columns: (1.45in, 0.5in, 0.4in, 0.35in, 0.6in, 1fr),
    [Condition], [Status], [Cat.], [rc], [Reason], [Message and details],
    [Unknown route, or wrong method for the route], [404], [6], [4], [7],
      [#cmd("Not Found")],
    [Authorization refused: a protected data set, or the abend S913], [500], [4], [8],
      [0], [#cmd("LMOPEN error"). #cmd("details") has one sentence:
      #cmd("Authorization failed - You may not use this protected data set."),
      and for the abend the same sentence followed by #cmd("Open 913 abend.")],
    [Encoding not supported], [500], [16], [121], [-1037303780],
      [#cmd("iconv_open() failed."), and a sentence in #cmd("details") that
      names the encoding from #cmd("X-IBM-Data-Type")],
    [Request body of 16 MB or more], [413], [6], [8], [0],
      [#cmd("The request body is too large")],
    [No storage for the request body], [500], [7], [16], [0],
      [#cmd("Storage for the request body could not be obtained")],
    [Abend in a handler], [500], [6], [8], [99],
      [#cmd("Internal server error (abend S0C4)"), see below],
  )
] <ref-conv-fixedtab>

The text for an abend names the code. A user abend appears as
#cmd("Internal server error (abend U0100)"), a system abend as
#cmd("Internal server error (abend S0C4)"). Three space abends carry an added
text: B37 gives #cmd("(abend SB37: out of space on the volume)"), D37 gives
#cmd("(abend SD37: primary extent full, no secondary allocation)") and E37 gives
#cmd("(abend SE37: extent limit reached)"). The abend is also written to the
operator console (@apx-messages). If the abend happens after mvsMF has begun
the response, no error report can follow. The client then sees a body that ends
early.

=== Category numbers <ref-conv-categories>

#idx("category")
The number in #cmd("category") does not mean the same in every area. The
names come from z/OSMF, and the areas of mvsMF fill them with their own
numbers. Read #cmd("category") together with the route that sent the report.

#tab(caption: [Category numbers as mvsMF emits them])[
  #table(columns: (0.55in, 1fr),
    [No.], [Use],
    [1], [UFS: a bad value of #cmd("X-IBM-Data-Type") (rc 4, reason 12), and the
      503 for a missing UFSD subsystem.],
    [2], [UFS: a bad request, such as a parameter that does not fit, a name that
      is too long, a path that is not a directory or is a directory.],
    [4], [Authorization, in the data set routes. In the UFS routes: a failed
      ETag check, an object that exists, a directory that is not empty, a
      read-only file system.],
    [6], [Service errors. Router (unknown route), the request body, abends,
      most errors of the data set routes and the job routes, the UFS "not found",
      the diagnostic endpoint.],
    [7], [Data set routes and the request body: unexpected error. Job routes:
      VSAM error.],
    [8], [Data set routes: failed dynamic allocation (rc 900, reason 7,
      message #cmd("Dynamic allocation Error")). Job routes: unexpected error.
      UFS: no space, no inodes.],
    [10], [UFS: I/O error, and any error without a category of its own.],
    [16], [An encoding that is not supported.],
  )
] <ref-conv-cattab>

The UFS routes use rc 8 and reason 1 for all errors that come from UFSD. The
message is one of #cmd("File or directory not found"),
#cmd("File or directory already exists") and the like; @ref-uss lists them.

The data set routes use these reasons, mostly with category 6:

#tab(caption: [Reasons of the data set routes])[
  #table(columns: (0.55in, 1fr),
    [Reason], [Meaning],
    [1], [The data set is partitioned. The request needs a sequential data set.],
    [3], [Invalid or missing allocation parameters.],
    [4], [The data set is not found.],
    [5], [The member is not found.],
    [6], [Unsupported or malformed rename request.],
    [7], [The rename target exists.],
    [8], [The rename failed.],
    [9], [The member pattern is too long.],
    [10], [The ETag does not match.],
    [11], [The delete failed.],
  )
] <ref-conv-dsreasons>

The reason 2 is not used. The reason 7 of the failed allocation (category 8,
rc 900) is another case than the reason 7 of the rename target.

The job routes use these reasons, mostly with category 6:

#tab(caption: [Reasons of the job routes])[
  #table(columns: (0.55in, 1fr),
    [Reason], [Meaning],
    [1], [Server error.],
    [2], [Job not found.],
    [3], [Invalid query.],
    [4], [Invalid request.],
    [5], [The job is a started task and cannot be purged.],
    [6], [The JES VSAM handle could not be opened.],
    [7], [The field #cmd("file") is missing from the submit request.],
    [8], [The data set for the submit cannot be opened.],
    [9], [JES2 is busy.],
    [10], [The spool data is gone.],
    [11], [The spool could not be read.],
    [12], [The JOB card is too long.],
  )
] <ref-conv-jobreasons>

An unknown job gets category 6, rc 4, reason 2 and the message
#cmd("Job 'NAME(ID)' not found"). The name and the ID in the message are cut
at 64 characters, and a double quote, a backslash and any byte below 0x40 in
them become a question mark.

=== The report of the console <ref-conv-consoleerr>

#idx("error report", "console")
The console routes use another shape, with hyphens in the names:

#screen(raw("{\"return-code\":8,\"reason-code\":16,\"reason\":\"...\"}"))

@ref-cons gives the values for each case. If the server cannot build the JSON
document, the answer has the status and no body.

=== The report of the login <ref-conv-loginerr>

The login of @ref-auth uses a third shape:

#screen(raw("{\"returnCode\":8,\"reasonCode\":1,\"message\":\"...\"}"))

== Character Sets <ref-conv-codepage>

#idx("codepage")
#idx("CP037")
#idx("IBM-1047")
mvsMF does not use one codepage for everything. The wire carries ASCII. The
payload of a request or a response is translated between ASCII and the
codepage of its area:

#tab(caption: [Codepage by area])[
  #table(columns: (1.5in, 1fr),
    [Area], [Codepage of the payload],
    [Data sets and members], [CP037. IBM-1047 when the request has
      #cmd("X-IBM-Data-Type: text;fileEncoding=IBM-1047").],
    [UFS files], [IBM-1047. CP037 when the request has
      #cmd("X-IBM-Data-Type: text;fileEncoding=IBM-037").],
    [Job JCL, spool and records], [CP037.],
    [JSON and headers], [Translated by HTTPD. Its default table is CP037.],
  )
] <ref-conv-cptab>

The two codes differ in a few characters, among them the square brackets, the
circumflex, the exclamation mark and the not sign. A payload translated with
the wrong table is still delivered with status 200, and these characters are
wrong. That is why each area has a fixed table.

Binary data (#cmd("X-IBM-Data-Type: binary")) is not translated.

A #cmd("fileEncoding") other than the two in the table gets the encoding report
of @ref-conv-fixedtab. mvsMF translates bytes with a table. It does not decode
UTF-8, so a character that is not in the table is not converted to its code
point (mvsmf\#234).

The tables are part of HTTPD. To change a codepage, change HTTPD; mvsMF has no
setting for it.

== JSON <ref-conv-json>

#idx("JSON")
Every JSON body that mvsMF sends has these properties:

- It goes out with #cmd("Content-Type: application/json") and with
  #cmd("Content-Length"). The diagnostic endpoint is the exception
  (@ref-test-resp).
- The numbers are integers.
- The fields come in a fixed order, as the tables of the area chapters list
  them.
- A request body in JSON is read by the handler that expects it. A body that
  does not parse is a 400 from that handler.

The JSON builders differ in how they treat text. The function for a plain
string copies it as it is, through a buffer of 256 bytes that holds the whole
field, so a long text is cut. The function for an
escaped string and the one for an array element escape the double quote, the
backslash, the carriage return, the line feed and the tab, and no other
control character (mvsmf\#215).

== Limits <ref-conv-limits>

#idx("limits")
@ref-conv-limtab lists the limits that apply to every route. The limits of one
area are in its chapter.

#tab(caption: [Limits that apply to every route])[
  #table(columns: (1.9in, 1fr),
    [Item], [Limit],
    [Length of the path], [1023 characters. A longer path is cut off.],
    [Value of a path variable], [1023 characters.],
    [Routes], [100 can be registered. mvsMF registers 29.],
    [Middleware], [10 can be registered. mvsMF registers one.],
    [Files that one request has open at the same time], [4. A fifth is not
      tracked, so the recovery after an abend does not close it (message
      MVSMF903W).],
    [Request body], [A request that declares a length of 16 MB (16,777,216
      bytes) or more gets 413. A smaller body is read into storage in one
      piece. If the storage is not there, the answer is 500.],
    [Wait for the request body], [mvsMF reads the body one byte at a time. It
      waits 50 ms for a byte and gives up after 200 waits, that is after 10
      seconds. The operator gets MVSMF007W.],
    [Wait for the client to receive], [A response that makes no progress is
      abandoned after 100 tries of 100 ms, that is after 10 seconds. The
      operator gets MVSMF008W.],
    [Stack of the module], [64 KB.],
    [Size of a UFS file], [About 4.06 MB (4,259,840 bytes). This is the limit
      of UFSD for a block size of 4096 bytes. mvsMF has no check of its own.],
  )
] <ref-conv-limtab>

@ref-ds, @ref-uss, @ref-jobs and @ref-cons give the limits of names, lists and
commands.
