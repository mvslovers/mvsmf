#!/bin/sh
# Sessions of guide/ug-first.typ ("Connecting and Logging In").
#
#   MVSMF_URL=http://localhost:8080 MVSMF_USER=... MVSMF_PASS=... sh capture/first.sh
#
# Needs, on the system under test:
#
#   - HTTPD with the shipped route lines of mvsMF (samplib/mvsmfprm):
#       /zosmf/info                   AUTH=NONE
#       /zosmf/services/authenticate  AUTH=NONE
#       /zosmf/*                      AUTH=TOKEN
#     The sessions info-noauth, login-wrong and after-logout show the three
#     kinds of 401 that these lines produce, so do not run the script against
#     a configuration with other AUTH= values.
#   - a user ID with a good password (MVSMF_USER, MVSMF_PASS) that HTTPD lets
#     in. If the /zosmf/* line has RES=FACILITY:MVSMF.ACCESS (the security
#     chapter), this user ID must have READ access to MVSMF.ACCESS.
#   - a release build of mvsMF (the version does not end in -dev). The sessions
#     cookie and after-logout call GET /zosmf/restjobs/jobs?prefix=NOSUCH*, a
#     request that every user ID that mvsMF lets in may send and that no job
#     matches (the answer is an empty array).
#   - nothing else: no data sets, no UFS files, no side effects for other
#     chapters. The script only reads, logs in and logs out.
#
# The session denied needs a second user ID that has a good password and NO
# access to the profile of the RES= keyword. Set it with
#
#   MVSMF_DENY_USER=... MVSMF_DENY_PASS=...
#
# and put RES=FACILITY:MVSMF.ACCESS on the /zosmf/* line (HTTPD restart) for
# the run of this session. Without MVSMF_DENY_USER the session is skipped and
# its file stays as it is. The book shows the command with MVSMF_USER and
# MVSMF_PASS, so the second user ID is exported under these names for the one
# session.
#
# The cookie jar cookies.txt of login, cookie and logout is written to a
# directory of its own, which is removed at the end. login must run before
# cookie, logout and after-logout.
#
# The wrong password of login-wrong is the literal text wrong-password: a
# user ID that the security product counts failed attempts for (a revoke after
# some tries) can be revoked by repeated runs. Use a test user ID.
#
# Output to expect: the Host header of info shows the host and port of
# MVSMF_URL, and the realm of the 401 answers is the REALM of HTTPD or the SMF
# system ID. The book shows a host and port as variables.

. "$(dirname "$0")/lib.sh"

WORK=$(mktemp -d) || exit 1
cd "$WORK" || exit 1
trap 'cd /; rm -rf "$WORK"' EXIT

# ---- 1. check the connection ----------------------------------------------

ses ug-first/info.txt 'curl -si -u "$MVSMF_USER:$MVSMF_PASS" "$MVSMF_URL/zosmf/info"'

# ---- 2. token login, use, logout -------------------------------------------

hid 'rm -f cookies.txt'

ses ug-first/login.txt 'curl -si -c cookies.txt -X POST -u "$MVSMF_USER:$MVSMF_PASS" "$MVSMF_URL/zosmf/services/authenticate"'

ses ug-first/cookie.txt 'curl -s -b cookies.txt "$MVSMF_URL/zosmf/restjobs/jobs?prefix=NOSUCH*"'

ses ug-first/logout.txt 'curl -si -X DELETE -b cookies.txt "$MVSMF_URL/zosmf/services/authenticate"'

ses ug-first/after-logout.txt 'curl -si -b cookies.txt "$MVSMF_URL/zosmf/restjobs/jobs?prefix=NOSUCH*"'

# ---- 3. when it fails -------------------------------------------------------

# no credential on /zosmf/info: the 401 of mvsMF, with the challenge
ses ug-first/info-noauth.txt 'curl -si "$MVSMF_URL/zosmf/info"'

# wrong password at the login: the 401 with the JSON body
ses ug-first/login-wrong.txt 'curl -si -X POST -u "$MVSMF_USER:wrong-password" "$MVSMF_URL/zosmf/services/authenticate"'

# a user ID without access to the RES= profile: the 403 of HTTPD
if [ -n "$MVSMF_DENY_USER" ]; then
	(
		MVSMF_USER=$MVSMF_DENY_USER
		MVSMF_PASS=$MVSMF_DENY_PASS
		export MVSMF_USER MVSMF_PASS
		ses ug-first/denied.txt 'curl -si -u "$MVSMF_USER:$MVSMF_PASS" "$MVSMF_URL/zosmf/restjobs/jobs?prefix=NOSUCH*"'
	)
else
	echo "skipped ug-first/denied.txt (MVSMF_DENY_USER not set)" >&2
fi
