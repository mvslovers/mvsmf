#import "../bookmaster/bookmaster.typ": *

= Connecting and Logging In <ug-first>

#idx("first session")
This chapter shows how to reach mvsMF, check that the connection works, log in,
and log out. It is the first of the chapters that describe what a user does.
Each section is a task, and each task has a session that was typed at a real
mvsMF.

You need a running mvsMF (@ug-ops), the address of its HTTPD, and a user ID that
HTTPD lets in (@ug-security).

== How to Read the Sessions <ug-first-read>

#idx("session")
Every session in this book was run with the command line client #cmd("curl")
(version 8.14.1) against the release build of mvsMF 1.4.0 on a test system.
Four things hold for all of them:

- The address of mvsMF, the user ID and the password are in three shell
  variables, and the sessions show the variables, not their values:

  #screen(raw("export MVSMF_URL=http://HOST:PORT
export MVSMF_USER=your-user-id
read -r -s MVSMF_PASS; export MVSMF_PASS", block: true))

  Set #cmd("MVSMF_URL") to the scheme, host and port of your HTTPD. The
  command #cmd("read -s") asks for the password without printing it, so the
  password does not stay in the history of the shell.
- A line that starts with #cmd("$") is typed by the reader. Every other line is
  printed by #cmd("curl"): the status line and the headers of the response when
  the command has the option #cmd("-i"), then the body of the response.
- The option #cmd("-s") keeps #cmd("curl") from printing its progress meter. The
  option #cmd("-i") adds the response headers to the output, which is how a
  session shows the status code. A command without #cmd("-i") shows the body
  only.
- Your user ID may not be allowed everything that a session shows. Where a
  session shows a success, you may get an error (@ug-errors).

#idx("curl", "options")
The sessions use these options of #cmd("curl") over and over:

#tab(caption: [Options of curl in the sessions])[
  #table(columns: (1.1in, 1fr),
    [Option], [Meaning],
    [#cmd("-u user:password")], [Send the user ID and the password as Basic
      authentication.],
    [#cmd("-i")], [Print the status line and the headers of the response.],
    [#cmd("-s")], [Do not print the progress meter.],
    [#cmd("-X METHOD")], [Use this HTTP method.],
    [#cmd("-c file")], [Write the cookies of the response to this file.],
    [#cmd("-b file")], [Send the cookies that are in this file.],
  )
]

The sessions that show a response show what the test system printed. The text
around them describes what mvsMF does by its design. A value such as a host
name, a time or the build that your system prints differs from the session.

== Choosing a Client <ug-first-client>

#idx("client")
Any program that sends HTTP requests works with mvsMF, and this book uses
#cmd("curl"). Two points apply to mvsMF in particular:

- *Send the credential with the first request.* A client may wait for the
  server to ask for a credential (a challenge) and send the credential only
  then. Some answers of mvsMF carry a challenge and some do not
  (@ug-first-401). A client that waits for one stops at the answers that have
  none. #cmd("curl") with #cmd("-u") sends the credential with the first
  request.
- *Basic authentication is not encrypted.* The user ID and the password go over
  the connection base64 encoded, which anybody who sees the traffic can undo.
  Use it on a network that you trust, or let a front end add the encryption.

mvsMF does not need the header #cmd("X-CSRF-ZOSMF-HEADER"), which real z/OSMF
wants. A client that sends it does no harm.

== Checking the Connection <ug-first-check>

#idx("/zosmf/info")
#idx("system information")
The request #cmd("GET /zosmf/info") tells whether mvsMF is reachable, whether
your credential is good, and which version runs:

#screen(raw(read("../ex/ug-first/info.txt"), block: true))

The first line of the response is the status line. The status 200 means that
HTTPD and mvsMF answered and that the credential was accepted. The body is a
JSON object with these fields, in this order:

#deflist(width: 1.9in,
  [#cmd("zosmf_hostname")], [The host name of the #cmd("Host") header that the
    client sent. #cmd("curl") sends the host name of the URL.],
  [#cmd("zosmf_port")], [The port of that header. If the header has no port,
    mvsMF takes the header #cmd("X-Forwarded-Port") of a proxy, and otherwise
    80 (443 for a request with the scheme https).],
  [#cmd("zosmf_version")], [Always #cmd("1").],
  [#cmd("zosmf_full_version")], [The version of mvsMF: #cmd("1.4.0") in the session
    above. A development build ends in #cmd("-dev").],
  [#cmd("plugins")], [Always an empty array.],
  [#cmd("zosmf_saf_realm")], [Always #cmd("SAFRealm").],
  [#cmd("api_version")], [Always #cmd("1").],
  [#cmd("zos_version")], [Always #cmd("MVS 3.8j").],
)

The name and the port come from the request and not from the configuration of
the server, so they show what the client typed. The response of a request with
Basic authentication carries a #cmd("Set-Cookie") header, too (see
@ug-first-leave). The _mvsMF Reference_ describes
the fields and the rules for the #cmd("Host") header in "Authentication and
System Information".

#note[*The request is not a liveness probe.* It needs a credential. Without one
mvsMF answers 401 (@ug-first-401). A monitor that only wants to know that the
server is up has to send a credential, too.]

=== Which build runs <ug-first-build>

#idx("build id")#idx("zosmf_full_version")
The field #cmd("zosmf_full_version") of the response is the way to see which
version is loaded. It has the version only, with no commit, and the request
needs no profile besides the credential. A release answers #cmd("1.4.0"), as in
the session above. A version that ends in #cmd("-dev") means that a development
build is installed. Give the version when you report a problem. The _mvsMF
Reference_ describes the diagnostic endpoint that shows the commit of a
development build, in "The Diagnostic Endpoint". A release does not have it.

== Connecting and Logging In <ug-first-login>

#idx("login")
#idx("Basic authentication")
mvsMF knows two ways to prove who you are. They end in the same place: HTTPD
asks the security product, and every later check is made for your user ID.

=== Basic authentication <ug-first-basic>

With Basic authentication every request carries the user ID and the password.
That is what the option #cmd("-u") does in the session of @ug-first-check. The
request needs no earlier step. HTTPD decodes the header, asks the security
product, and keeps the answer for the next request of the same client with the
same user ID and password. Three details:

- The decoded text #cmd("user:password") is limited to 255 bytes, the colon
  included.
- HTTPD folds the user ID and the password to upper case and uses their first
  eight characters. Whatever case you type, and whatever follows the eighth
  character, the check is made with the upper case form of the first eight.
- The user ID cannot contain a colon, because the first colon ends it.

=== Token login <ug-first-token>

#idx("token")
#idx("cookie", "LtpaToken2")
#idx("/zosmf/services/authenticate")
A client that does not want to send the password with every request can log in
once and use a token. The login is the request
#cmd("POST /zosmf/services/authenticate") with the Basic credential and no
body:

#screen(raw(read("../ex/ug-first/login.txt"), block: true))

The status 200 and the body

#screen(raw("{\"returnCode\":0,\"reasonCode\":0,\"message\":\"Success.\"}"))

say that the login worked. The token is in the header #cmd("Set-Cookie"):

#screen(raw("Set-Cookie: LtpaToken2=<token>; Path=/; HttpOnly; SameSite=Strict"))

The cookie has the name #cmd("LtpaToken2"). It has no #cmd("Secure") attribute,
so a client sends it over a connection without encryption, too. The header may
appear twice in the response, with the same value, as the session shows. The option #cmd("-c") of
#cmd("curl") writes the cookie to the file #cmd("cookies.txt"). Every login
returns a new token, also for the same user ID. HTTPD accepts a token only from
the address that logged in.

A request sends the token back as a cookie. The option #cmd("-b") does that, and
no user ID or password is needed:

#screen(raw(read("../ex/ug-first/cookie.txt"), block: true))

The token also works as a bearer token, in the header
#cmd("Authorization: Bearer <token>") with the same text as in the cookie. The
_mvsMF Reference_ describes the token and the cookie in "Authentication and
System Information".

#note[*Log in once, not for every request.* Each login creates a session in
HTTPD that stays until a logout ends it or HTTPD removes it. A script that logs
in for every request and never logs out leaves one session behind for each
request. Log in once, and log out when the work is done.]

=== Logging out <ug-first-logout>

#idx("logout")
The request #cmd("DELETE /zosmf/services/authenticate") ends the session that
the cookie or the bearer token stands for:

#screen(raw(read("../ex/ug-first/logout.txt"), block: true))

The status 204 has no body. The header #cmd("Set-Cookie") sets the cookie to the
value #cmd("deleted") with a date in the past, which tells a client to drop it.
The token is dead after that:

#screen(raw(read("../ex/ug-first/after-logout.txt"), block: true))

A logout with a token that is already dead, or without any credential, is a 401.

== When the Login Fails <ug-first-fail>

#idx("login", "failure")
A request can fail at three places: HTTPD refuses the credential, mvsMF refuses
the request, or HTTPD refuses the user after a good login. The three look
different, and the difference tells where to look.

=== The 401 answers <ug-first-401>

#idx("401")
#idx("WWW-Authenticate")
A status 401 means that the request has no credential that HTTPD accepts. The
cause is a missing header, a wrong password, an unknown user ID, or a token that
is gone. The shape of the answer depends on the route. With the route lines that
the installation ships (@ug-install), these cases exist:

#tab(caption: [The 401 answers of mvsMF and HTTPD])[
  #table(columns: (1.9in, 1.1in, 1fr),
    [Request], [Who answers], [The answer],
    [#cmd("GET /zosmf/info") without a good credential], [mvsMF], [No body, with
      the header #cmd("WWW-Authenticate: Basic realm=\"name\"").],
    [#cmd("POST /zosmf/services/authenticate") without a good credential],
      [mvsMF], [The JSON body of @ug-first-wrong, with the header
      #cmd("WWW-Authenticate").],
    [#cmd("DELETE /zosmf/services/authenticate") without a live token],
      [mvsMF], [No body, with the header #cmd("WWW-Authenticate").],
    [Every other request under #cmd("/zosmf/") without a good credential],
      [HTTPD], [The body #cmd("401 Unauthorized") as plain text, and no header
      #cmd("WWW-Authenticate").],
  )
]

A request that has no credential at all, and a request with a wrong password,
get the same answer, so the answer does not say which of the two it was.

The first case in a session:

#screen(raw(read("../ex/ug-first/info-noauth.txt"), block: true))

#idx("realm")
The name in the challenge is the realm. It is the parameter #cmd("REALM") of
HTTPD, or the SMF system ID if there is none. A browser shows the name in its
login dialog.

mvsMF leaves out the header #cmd("WWW-Authenticate") when the request comes from
the script of a web page: when the request has the header
#cmd("X-MVSMF-Client"), or the header #cmd("Sec-Fetch-Mode") with a value other
than #cmd("navigate"). The browser would otherwise open its own login dialog
over the page. A client such as #cmd("curl") sends neither header and always
gets the challenge from mvsMF.

The fourth case is the answer of HTTPD. A request after a logout shows it
(@ug-first-login): the cookie is dead, there is no other credential, and HTTPD
stops the request before it reaches mvsMF.

=== A wrong password <ug-first-wrong>

#idx("password", "wrong")
A wrong password at the login gives a 401 with a JSON body:

#screen(raw(read("../ex/ug-first/login-wrong.txt"), block: true))

The fields are #cmd("returnCode") 8 and #cmd("reasonCode") 1, and the message
says that the login failed and what to check: the user ID and the password of
the Basic credential, and whether the user ID has the SAF permissions that it
needs. The body has the same shape for a missing header. The message does not
say which of the checks failed.

If the password is right and the login still fails with a status 500 and the
message #cmd("The request failed because an internal error occurred."), the
credential was good but HTTPD could not create a session for it. Ask the
administrator to look at the console of HTTPD.

=== A user without access <ug-first-denied>

#idx("403")
#idx("RES=")
The administrator of HTTPD can tie a route line of mvsMF to a security profile
(the keyword #cmd("RES=") on the route line, described in @ug-security). A user
ID whose password is right, but which has no READ access to the profile of the
route, gets a 403 from HTTPD. The session was typed with a user ID that has no
access to #cmd("MVSMF.ACCESS"), the profile that the catch-all route line
#cmd("/zosmf/*") was tied to for this run (@ug-security-access):

#screen(raw(read("../ex/ug-first/denied.txt"), block: true))

The body is plain text, and it is not JSON. The 403 comes from HTTPD, not from
mvsMF: mvsMF does not run for this request and never answers with this status.
Which requests get it depends on the route lines:

- The sample route lines tie the console services to #cmd("MVSMF.CONSOLE")
  (@ug-security-console). The administrator may tie the catch-all to
  #cmd("MVSMF.ACCESS") as well. A user ID without the access to the catch-all gets the
  403 on every path under #cmd("/zosmf/") that the other lines do not cover. A
  user ID without access to #cmd("MVSMF.CONSOLE") gets it only under
  #cmd("/zosmf/restconsoles/"). The session above was typed with a user ID
  that has READ access to #cmd("MVSMF.CONSOLE") only, and it asked for a job
  list, so that the catch-all line answered.
- A route line whose profile does not exist is not checked by HTTPD at all.
  HTTPD reports that when it starts, and every user that got in passes that
  line. The console services are the exception: mvsMF checks
  #cmd("MVSMF.CONSOLE") itself, and without the profile it refuses every
  request for them with a 500 (@ug-security-console).
- A user ID that HTTPD lets through to the console services but that has no
  READ access to #cmd("MVSMF.CONSOLE") gets the 500 of mvsMF, an error report
  in JSON, and not this 403.

Ask the administrator for access to the profile that your 403 belongs to. A
user ID that has access does not meet this 403. It meets the checks of the data
sets, the files and the jobs instead (@ug-errors).

== Leaving <ug-first-leave>

A client that used Basic authentication has nothing to end: the next request
carries the credential again. A client that logged in with a token ends the
session with the logout of @ug-first-login.

#note[*A Basic request can set a cookie too.* HTTPD keeps a token for a Basic
credential, and mvsMF returns it as a cookie on a request that carries the
header #cmd("Authorization"). That token belongs to everybody who logs in with
the same user ID and password from the same address. A logout with it ends the
credential of all of them. Use the token that a login returned, not the cookie
of a Basic request.]
