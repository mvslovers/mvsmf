#import "../bookmaster/bookmaster.typ": *

= Authentication and System Information <ref-auth>

#idx("authentication")
This chapter describes how a request proves who sent it, the route that returns
the system information, and the two methods of the route that opens and closes a
token session. The conventions that hold for every route, such as headers, status
codes and error reports, are in @ref-conv.

The three requests of this chapter are:

#tab(caption: [Routes of this chapter])[
  #table(columns: (1.15in, 1fr),
    [Request], [Purpose],
    [#cmd("GET /zosmf/info")], [System information (@ref-auth-info).],
    [#cmd("POST /zosmf/services/authenticate")], [Log in and get a token
      (@ref-auth-login).],
    [#cmd("DELETE /zosmf/services/authenticate")], [Log out and end the token
      (@ref-auth-logout).],
  )
]

== How a Request Is Authenticated <ref-auth-cred>

#idx("credential")
mvsMF does not check passwords. HTTPD (httpd) resolves the credential of every
request before the request reaches mvsMF. HTTPD tries these sources in this
order and takes the first that gives a credential:

+ the cookie #cmd("Sec-Token"),
+ the cookie #cmd("LtpaToken2"),
+ the header #cmd("Authorization: Bearer token"),
+ the header #cmd("Authorization: Basic base64(user:password)").

A token in a cookie or in a Bearer header is the value that the login returns
(@ref-auth-cookie). A token that HTTPD does not know gives no credential, and
the lookup goes on with the next source. For Basic, HTTPD decodes the value and
splits it at the first colon. It keeps at most 255 bytes of the decoded text.
It folds the password to upper case and asks RACF. HTTPD keeps the resulting
credential and reuses it for the next request from the same client address
with the same user ID and password.

The route lines of HTTPD decide whether a credential is required (@ref-httpd).
The shipped configuration has four lines for mvsMF:

#screen(raw("MOD=MVSMF /zosmf/info                    AUTH=NONE
MOD=MVSMF /zosmf/services/authenticate   AUTH=NONE
MOD=MVSMF /zosmf/restconsoles/*          AUTH=TOKEN RES=FACILITY:MVSMF.CONSOLE
MOD=MVSMF /zosmf/*                       AUTH=TOKEN", block: true))

On a route with #cmd("AUTH=TOKEN") HTTPD answers a request without a credential
itself, with the plain 401 of @ref-conv-401 (a text body, no challenge). On a route with #cmd("AUTH=NONE")
HTTPD passes the request on with or without a credential.

mvsMF then runs its authentication middleware for every request. It takes the credential that
HTTPD resolved and makes it the identity of the task, so that the data set,
file and job operations run under the user. The middleware lets
#cmd("/zosmf/services/authenticate") through without a credential. For any other
route a request without a credential gets the 401 of mvsMF:

#deflist(width: 1.65in,
  [Status], [401.],
  [#cmd("WWW-Authenticate")], [#cmd("Basic realm=\"name\""), unless the request
    comes from the script of a web page (@ref-conv-401). The name is the
    #cmd("REALM") of the HTTPD parameters or the SMF system ID.],
  [Body], [None. #cmd("Content-Length: 0").],
)

mvsMF does not require the header #cmd("X-CSRF-ZOSMF-HEADER") on any request,
and it does not look at its value.

== System Information <ref-auth-info>

#idx("/zosmf/info")
#idx("system information")
#cmd("GET /zosmf/info") returns facts about the server in one JSON object.
The route needs a credential. It is not a liveness check: a request without a
credential gets the 401 of mvsMF described in @ref-auth-cred.

The route takes no query parameters and no body. It reads three request headers
(@ref-auth-host).

=== The response <ref-auth-inforesp>

The status is 200 and the body is JSON (#cmd("application/json")). The fields
come in this order:

#tab(caption: [Fields of the response of #cmd("/zosmf/info")])[
  #table(columns: (1.65in, 0.7in, 1fr),
    [Field], [Type], [Value],
    [#cmd("zosmf_hostname")], [string], [The host name from the #cmd("Host")
      header of the request (@ref-auth-host). #cmd("127.0.0.1") if there is
      none or it cannot be used.],
    [#cmd("zosmf_port")], [string], [The port from the #cmd("Host") header, or
      a port derived as described in @ref-auth-host. #cmd("8080") if the
      request has no #cmd("Host") header.],
    [#cmd("zosmf_version")], [string], [#cmd("1"). The major version of mvsMF.
      Real z/OSMF sends its own level here, such as #cmd("29").],
    [#cmd("zosmf_full_version")], [string], [The version of the build of mvsMF,
      for example #cmd("1.4.0"). It has the version only, no commit and no
      profile is needed. A development build ends in #cmd("-dev"). This
      field is the check of a release that has been deployed.],
    [#cmd("plugins")], [array], [Always empty: #cmd("[]").],
    [#cmd("zosmf_saf_realm")], [string], [Always #cmd("SAFRealm").],
    [#cmd("api_version")], [string], [Always #cmd("1").],
    [#cmd("zos_version")], [string], [Always #cmd("MVS 3.8j").],
  )
] <ref-auth-infotab>

The values of #cmd("zosmf_version"), #cmd("zosmf_saf_realm"), #cmd("api_version")
and #cmd("zos_version") are constants of the module. They do not reflect the
installation.

If the module cannot create its JSON builder, the answer is status 500 with no
body (#cmd("Content-Length: 0")). If a later step of the build fails, the module
sends no response of its own.

=== The Host header <ref-auth-host>

#idx("Host header")
The two fields #cmd("zosmf_hostname") and #cmd("zosmf_port") come from the
request headers and not from the configuration of the server. They fall back
independently of each other, and a header that cannot be used never fails the
request. The status stays 200.

*The host name.* The module takes the text of the #cmd("Host") header up to
the first colon. If that text is empty, or has 256 characters or more, the
host name is #cmd("127.0.0.1"). If the request has no #cmd("Host") header, the
host name is also #cmd("127.0.0.1").

*The port.* If the request has no #cmd("Host") header, the port is #cmd("8080").
Otherwise the module takes the text after the first colon. The port is used as
it is if the text consists of digits only and its value is between 1 and
65535. In every other case, including a missing colon, an empty text after the
colon and a text of more than 5 characters, the module derives the port:

+ If the header #cmd("X-Forwarded-Port") holds a valid port (digits only, 1 to
  65535), that is the port.
+ Otherwise the port is #cmd("443") if the request counts as https, and
  #cmd("80") if not.

A request counts as https if the header #cmd("X-Forwarded-Proto") begins with
#cmd("https") and the text ends there or continues with a comma or a blank.
Any other value, or no header, means http.

== Log In <ref-auth-login>

#idx("login")
#idx("/zosmf/services/authenticate")
#cmd("POST /zosmf/services/authenticate") turns a Basic credential into a token
session. The request carries a header #cmd("Authorization: Basic ...") and no
body. mvsMF reads no body and no query parameter.

HTTPD resolves the credential first (@ref-auth-cred). If it finds none, the
login fails. If it finds one, mvsMF asks HTTPD for a new session of its own for
that credential. Each login therefore returns a new token, also for the same
user from the same address. A logout with one token ends only that session.

=== Success

The status is 200. The body is

#screen(raw("{\"returnCode\":0,\"reasonCode\":0,\"message\":\"Success.\"}"))

The response carries the token as a cookie (@ref-auth-cookie), in one
#cmd("Set-Cookie") header. Before 1.4.0 the header was sent twice, with the same
value.

=== Failure

#tab(caption: [Failures of the login])[
  #table(columns: (0.55in, 1.5in, 1fr),
    [Status], [Cause], [Body and headers],
    [401], [No credential, or HTTPD could not resolve one: no
      #cmd("Authorization") header, a wrong password, an unknown user ID.],
    [#cmd("{\"returnCode\":8,\"reasonCode\":1,\"message\":\"Login failed. Check whether the user ID and password you use for the Basic Auth is correct, and if the user ID has the required SAF permissions.\"}"),
      with #cmd("Content-Type: application/json") and the header
      #cmd("WWW-Authenticate") of @ref-conv-401 (not for a web page script).],
    [500], [The credential is good, but HTTPD could not give it a session of its
      own. Causes: RACF refused the second logon (for example, the password has
      changed in RACF while HTTPD still holds the old one from an earlier
      request), the credential store is full,
      or the client already holds 16 sessions of the same user ID, password and
      address and none of them has been idle for 60 seconds. When one of them
      has, HTTPD ends the one used least recently and makes room.],
    [#cmd("{\"returnCode\":4,\"reasonCode\":40,\"message\":\"The request failed because an internal error occurred.\"}")],
  )
]

The login uses the response shape of @ref-conv-loginerr, not the error report
of the other areas.

Only a successful login sets a cookie. The 401 and the 500 carry no
#cmd("Set-Cookie") header. Before 1.4.0 the 500 carried the token of the
credential that HTTPD holds for the user ID, the password and the client
address (@ref-auth-cookie), and a request that sent it was accepted.

=== When HTTPD Refuses Every Login <ref-auth-open>

#idx("HTTPD042W")
HTTPD 4.5.1 and later test the security product at every start with one logon
of the reserved user ID #cmd("HTTPPRB") and a password that cannot be right. If
the product accepts it, HTTPD writes #cmd("HTTPD042W SECURITY SYSTEM ACCEPTS ANY
USERID, ALL LOGINS REFUSED") and accepts no Basic credential of any user until
it is started again. The user ID #cmd("STC") is refused in every case, too.

mvsMF has no part in this. It sees a request without a credential, and answers
as in @ref-auth-cred and in the table above. The login gets the 401 with the
body shown for the status 401 above, which is the answer for a wrong password. The services
under #cmd("/zosmf/") that HTTPD protects with #cmd("AUTH=TOKEN") get the plain
401 of HTTPD. Neither HTTPD nor RAKF writes a message for a refused login. RAKF
1.2.x with a missing or invalid user table is a product that does this (measured
on TK5; TK4- was not measured). The cure and the signs in the log are in the
_mvsMF User's Guide_, "Setting Up Security", and in the HTTPD documentation:
correct the tables of RAKF before the IPL and restart HTTPD.

== The Token and the Cookie <ref-auth-cookie>

#idx("token")
#idx("cookie", "LtpaToken2")
The token is the value that HTTPD uses to find a stored credential. It is 32
bytes long. mvsMF returns it as base64 text in this cookie:

#screen(raw("Set-Cookie: LtpaToken2=<base64 token>; Path=/; HttpOnly; SameSite=Strict"))

The cookie has no #cmd("Secure") attribute. A client sends it back in a
#cmd("Cookie: LtpaToken2=...") header. The header #cmd("Authorization: Bearer ...")
with the same base64 text also works.

A request with an #cmd("Authorization") header gets this cookie in every
response, on every route except the two of the authentication service, as long
as HTTPD holds a token for the credential of the request (@ref-conv-resphdr).
The login and the logout set only the cookie that this chapter names for them
(@ref-auth-login, @ref-auth-logout). For a Basic request the token is that of the
shared credential for the user ID, the password and the client address, and not
the token of a session of its own. A logout with that token ends the credential
for every holder of it. The token of a login (@ref-auth-login) is private to
that login.

A token stays valid until a logout removes it or HTTPD removes the credential.
The limits of the credential store and its timeouts belong to HTTPD (@ref-httpd).

== Log Out <ref-auth-logout>

#idx("logout")
#cmd("DELETE /zosmf/services/authenticate") ends the credential that HTTPD
resolved for the request. The request carries the token that the login
returned, in the cookie or in a Bearer header. The route takes no body and no
query parameter.

#tab(caption: [Answers of the logout])[
  #table(columns: (0.55in, 1.5in, 1fr),
    [Status], [Cause], [Response],
    [204], [HTTPD resolved a credential and removed it.], [No body. The header
      #cmd("Set-Cookie: LtpaToken2=deleted; Path=/; HttpOnly; SameSite=Strict; expires=Thu, 01 Jan 1970 00:00:00 GMT")
      tells the client to delete the cookie.],
    [401], [The request carries no credential that HTTPD accepts, or the token
      is already gone.], [No body, #cmd("Content-Length: 0"), and the
      #cmd("WWW-Authenticate") header of @ref-conv-401 (not for a web page
      script).],
  )
]

A second logout with the same token is a 401. The route is open at HTTPD
(#cmd("AUTH=NONE")), so a request without any credential reaches the handler
and gets the 401 of the table.

After a logout the token is no longer valid. A request that still sends it
gets no credential from the token. If it also carries a Basic header, HTTPD
tries that header next (@ref-auth-cred).

== Status Codes of This Chapter <ref-auth-status>

#tab(caption: [Status codes of the routes in this chapter])[
  #table(columns: (0.55in, 1fr),
    [Status], [Case],
    [200], [#cmd("GET /zosmf/info"), and the login.],
    [204], [The logout.],
    [401], [No credential (@ref-auth-cred), a failed login, a logout without a
      credential.],
    [405], [A method that the route does not have, such as a POST to
      #cmd("/zosmf/info"), with the error report of @ref-conv-methods. A method
      that mvsMF cannot parse gets no body.],
    [404], [A path that no route serves.],
    [500], [The module could not create its JSON builder, or the login could not
      create a session.],
  )
]
