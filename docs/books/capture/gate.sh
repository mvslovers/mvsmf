#!/bin/sh
# Sessions of the section "Protecting the Console Services" of
# guide/ug-security.typ.
#
#   MVSMF_URL=http://localhost:8080 MVSMF_USER=... MVSMF_PASS=... \
#       MVSMF_USER2=... MVSMF_PASS2=... sh capture/gate.sh PHASE
#
# PHASE is one of: gated consonly test order noprofile.  The phases are run one after
# the other and HTTPD is restarted between them with the HTTPPRM member the
# phase names (the script does not restart HTTPD, it does not edit the member).
#
#   MVSMF_USER   a user ID that may use mvsMF and has READ on the resource
#                FACILITY MVSMF.CONSOLE (through the group CONSOPS).
#   MVSMF_USER2  a user ID that may use mvsMF and has NO READ on it.
#
#   gated      MOD=MVSMF /zosmf/restconsoles/* AUTH=TOKEN RES=FACILITY:MVSMF.CONSOLE
#              listed before /zosmf/*, and the profile loaded (see rakf.sh console).
#   consonly   (after gated, with MVSMF_USER3 and MVSMF_PASS3: a user who has READ on
#              MVSMF.CONSOLE and none on MVSMF.ACCESS; rakf.sh consonly)
#   test       (after gated) the diagnostic endpoint, which the route does not cover.
#   order      the same route listed AFTER /zosmf/*.
#   noprofile  the route in the right place, the profile deleted (rakf.sh noconsole).
#
# The console name defcn is only a label in the returned addresses.

. "$(dirname "$0")/lib.sh"

for v in MVSMF_URL MVSMF_USER MVSMF_PASS MVSMF_USER2 MVSMF_PASS2; do
	eval "val=\${$v:-}"
	if [ -z "$val" ]; then
		echo "gate.sh: $v is not set" >&2
		exit 1
	fi
done
export MVSMF_URL MVSMF_USER MVSMF_PASS MVSMF_USER2 MVSMF_PASS2

# issue USER PASS FILE: the command D T as the given user
issue() {
	ses "ug-security/$3" "$(cat <<EOT
curl -si -X PUT -u "\$$1:\$$2" \\
  -H 'Content-Type: application/json' \\
  -d '{"cmd":"D T"}' \\
  "\$MVSMF_URL/zosmf/restconsoles/consoles/defcn"
EOT
)"
}

# routes FILE: the route lines of the latest start, as HTTPD logged them
routes() {
	ses "ug-security/$1" 'curl -s -u "$MVSMF_USER:$MVSMF_PASS" "$MVSMF_URL/zosmf/restconsoles/v1/log?timeRange=10m" | grep -o "HTTPD036I[^\"]*" | tail -4'
}

case "${1:-}" in
gated)
	issue MVSMF_USER2 MVSMF_PASS2 g-refused.txt
	issue MVSMF_USER MVSMF_PASS g-allowed.txt
	ses ug-security/g-log.txt 'curl -si -u "$MVSMF_USER2:$MVSMF_PASS2" "$MVSMF_URL/zosmf/restconsoles/v1/log?timeRange=10m"'
	routes g-routes-gated.txt
	ses ug-security/g-rest.txt 'curl -si -u "$MVSMF_USER2:$MVSMF_PASS2" "$MVSMF_URL/zosmf/restjobs/jobs?owner=*&prefix=NOSUCH*"'
	;;
consonly)
	# MVSMF_USER3: READ on FACILITY MVSMF.CONSOLE (group CONSOPS), none on MVSMF.ACCESS
	issue MVSMF_USER3 MVSMF_PASS3 g-consonly.txt
	ses ug-security/g-consonly-jobs.txt 'curl -si -u "$MVSMF_USER3:$MVSMF_PASS3" "$MVSMF_URL/zosmf/restjobs/jobs?prefix=NOSUCH*"'
	;;
test)
	ses ug-security/g-test.txt 'curl -si -u "$MVSMF_USER2:$MVSMF_PASS2" "$MVSMF_URL/zosmf/test?fn=cmd&cmd=D%20T" | head -9'
	;;
order)
	issue MVSMF_USER2 MVSMF_PASS2 g-order.txt
	routes g-routes-order.txt
	;;
noprofile)
	issue MVSMF_USER2 MVSMF_PASS2 g-noprofile.txt
	ses ug-security/g-warn.txt 'curl -s -u "$MVSMF_USER:$MVSMF_PASS" "$MVSMF_URL/zosmf/restconsoles/v1/log?timeRange=10m" | grep -o "HTTPD425W[^\"]*" | tail -1'
	;;
*)
	echo "usage: gate.sh gated|consonly|test|order|noprofile" >&2
	exit 1
	;;
esac
