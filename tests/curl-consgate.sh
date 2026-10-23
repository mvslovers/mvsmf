#!/bin/bash
# =========================================================================
# mvsMF console and test endpoint authorization - curl test suite (#460, #347)
#
# The console service (/zosmf/restconsoles/...) and the diagnostic endpoint
# (/zosmf/test, every fn= and the wildcard route) are served only to a caller
# who has READ on the RAKF resource FACILITY MVSMF.CONSOLE. The check is made
# in the handler, under the request's own ACEE, and only RACF rc 0 permits:
#
#   state                              ordinary user   administrator
#   no profile for the resource        refused         refused
#   profile, READ for the admin only   refused         served
#   profile, READ for both             served          served
#   profile removed again              refused         refused
#
# A refusal is HTTP 500 with category 4 (the report the data set handlers send
# for a denied OPEN); the same for "no profile" and "no READ".
#
# On a release build the /zosmf/test rows are left out: that endpoint is
# registered only by development builds (#508).
#
# Every route is asked with its normal path and with path variants. A variant
# that does not reach a handler is a 404 and serves nothing; one that does is
# refused like the normal path. The suite fails on anything else.
#
# The suite works with two users of the mbt target: the target's own user
# (MVSMF_USER, must be a RAKF administrator, group RAKFADM) writes the
# profile, and the further user test2 (MVSMF_USER2, an ordinary user) is the
# one the check is applied to.
#
# It CHANGES the system under test: it writes SYS1.SECURE.CNTL(PROFILES), runs
# the RAKF procedure RAKFPROF to load it, and puts the member back the way it
# found it. Use a throwaway container, never a real system. It does nothing
# unless MVSMF_CONSGATE_WRITE_PROFILES=yes is set in the environment: that is
# the owner of the container saying so. It refuses to run when PROFILES
# already has lines for the resource.
#
# Prerequisites:
#   - Run through mbt, which hands over the target's connection
#     (tests/lib/conn.sh); curl and jq must be installed
#
# Usage:
#   MVSMF_CONSGATE_WRITE_PROFILES=yes mbt run rest-tests -- curl-consgate
# =========================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/lib/conn.sh"

PASSED=0
FAILED=0
SKIPPED=0
TOTAL=0

pass() { PASSED=$((PASSED + 1)); TOTAL=$((TOTAL + 1)); echo "  PASS: $1"; }
fail() {
	FAILED=$((FAILED + 1)); TOTAL=$((TOTAL + 1)); echo "  FAIL: $1"
	[ -n "${2:-}" ] && echo "        $2"
}
skip() { SKIPPED=$((SKIPPED + 1)); TOTAL=$((TOTAL + 1)); echo "  SKIP: $1"; }

if [ "${MVSMF_CONSGATE_WRITE_PROFILES:-}" != yes ]; then
	skip "consgate: rewrites SYS1.SECURE.CNTL(PROFILES); set MVSMF_CONSGATE_WRITE_PROFILES=yes for a throwaway container"
	exit 0
fi
if [ -z "${MVSMF_CURLRC2:-}" ]; then
	skip "consgate: needs a further user test2 in the mbt target"
	exit 0
fi
command -v jq > /dev/null || { echo "ERROR: jq is required" >&2; exit 1; }

OWNER="$MVSMF_USER"     # RAKF administrator, gets READ first
OTHER="$MVSMF_USER2"    # ordinary user, is the one checked
PROF="SYS1.SECURE.CNTL(PROFILES)"
T=$(mktemp -d "${TMPDIR:-/tmp}/consgate.XXXXXX")
mvsmf_on_exit "rm -rf -- $(printf '%q' "$T")"

# --- requests --------------------------------------------------------------
# req WHO METHOD PATH [curl args]: sets HTTP_STATUS and BODY. The path goes out
# as written (--path-as-is).
# WHO is O (the owner, administrator) or U (the ordinary user).
req() {
	local who="$1" method="$2" path="$3" rc resp
	shift 3
	if [ "$who" = U ]; then rc="$MVSMF_CURLRC2"; else rc="$MVSMF_CURLRC"; fi
	resp=$(curl -s --path-as-is -w '\n%{http_code}' -X "$method" -K "$rc" \
		-H 'X-CSRF-ZOSMF-HEADER: 1' "$@" "${BASE_URL}${path}")
	HTTP_STATUS=$(echo "$resp" | tail -n1)
	BODY=$(echo "$resp" | sed '$d')
}

# --- the routes ------------------------------------------------------------
# label|method|path. The body of the console command is added by route().
ROUTES=(
	"console issue|PUT|/zosmf/restconsoles/consoles/defcn"
	"console collect|GET|/zosmf/restconsoles/consoles/defcn/solmsgs/NOSUCHKEY"
	"console detect|GET|/zosmf/restconsoles/consoles/defcn/detections/NOSUCHKEY"
	"console log|GET|/zosmf/restconsoles/v1/log?timeRange=1m"
	"test help|GET|/zosmf/test"
	"test version|GET|/zosmf/test?fn=version"
	"test cmd|GET|/zosmf/test?fn=cmd&cmd=D%20T"
	"test env|GET|/zosmf/test?fn=env"
	"test wildcard|GET|/zosmf/test/wildcard/x"
)

# A release build does not register /zosmf/test (#508): there is nothing to
# gate, and the routes would answer 404 instead of the refusal asked for.
if ! mvsmf_dev_build; then
	echo "  NOTE: not a development build, /zosmf/test is not registered -- its routes are left out"
	KEEP=()
	for r in "${ROUTES[@]}"; do
		case "$r" in "test "*) ;; *) KEEP+=("$r") ;; esac
	done
	ROUTES=("${KEEP[@]}")
fi

# The path variants of a route, in the order they are asked.
variants() {   # PATH
	local p="$1" q="" lit
	case "$p" in *\?*) q="?${p#*\?}"; p="${p%%\?*}" ;; esac
	case "$p" in
	/zosmf/test*)         lit="test" ;;
	/zosmf/restconsoles*) lit="restconsoles" ;;
	esac
	printf '%s\n' \
		"${p/$lit/${lit%?}%$(printf '%02X' "'${lit: -1}")}${q}" \
		"${p/$lit/${lit%?}%25$(printf '%02X' "'${lit: -1}")}${q}" \
		"${p/\/zosmf\//\/zosmf\/\/}${q}"
}

route() {   # WHO LABEL METHOD PATH
	local who="$1" method="$3" path="$4"
	if [ "$method" = PUT ]; then
		req "$who" PUT "$path" -H "Content-Type: application/json" \
			--data '{"cmd":"D T"}'
	else
		req "$who" "$method" "$path"
	fi
}

category() { echo "$BODY" | jq -r '.category // empty' 2> /dev/null; }

# Refused: HTTP 500, category 4, and none of the endpoint's own output.
is_refused() { [ "$HTTP_STATUS" = 500 ] && [ "$(category)" = 4 ]; }

# Served: the handler ran. 200 for every route but the detection lookup, which
# answers 500 with its own report (category 5) for a key nobody registered.
is_served() {   # LABEL
	case "$1" in
	"console detect") [ "$HTTP_STATUS" = 500 ] && [ "$(category)" != 4 ] ;;
	*) [ "$HTTP_STATUS" = 200 ] ;;
	esac
}

TABLE="$T/table"
: > "$TABLE"

expect_refused() {   # WHO STATE
	local who="$1" state="$2" r label method path v
	for r in "${ROUTES[@]}"; do
		IFS='|' read -r label method path <<< "$r"
		route "$who" "$label" "$method" "$path"
		printf '%s|%s|%s|normal|%s|%s\n' "$state" "$who" "$label" "$HTTP_STATUS" "$(category)" >> "$TABLE"
		if is_refused; then
			pass "$state: $who refused on $label (HTTP $HTTP_STATUS, category 4)"
		else
			fail "$state: $who refused on $label" "HTTP $HTTP_STATUS: $(echo "$BODY" | head -c 200)"
		fi
	done
}

# path variants: refused like the normal path, or not routed at all.
expect_refused_variants() {   # WHO STATE
	local who="$1" state="$2" r label method path v
	for r in "${ROUTES[@]}"; do
		IFS='|' read -r label method path <<< "$r"
		while read -r v; do
			route "$who" "$label" "$method" "$v"
			printf '%s|%s|%s|%s|%s|%s\n' "$state" "$who" "$label" "$v" "$HTTP_STATUS" "$(category)" >> "$TABLE"
			if is_refused || [ "$HTTP_STATUS" = 404 ]; then
				pass "$state: $who, path variant of $label: HTTP $HTTP_STATUS $v"
			else
				fail "$state: $who, path variant of $label: $v" "HTTP $HTTP_STATUS: $(echo "$BODY" | head -c 200)"
			fi
		done < <(variants "$path")
	done
}

expect_served() {   # WHO STATE
	local who="$1" state="$2" r label method path
	for r in "${ROUTES[@]}"; do
		IFS='|' read -r label method path <<< "$r"
		route "$who" "$label" "$method" "$path"
		printf '%s|%s|%s|normal|%s|%s\n' "$state" "$who" "$label" "$HTTP_STATUS" "$(category)" >> "$TABLE"
		if is_served "$label"; then
			pass "$state: $who served on $label (HTTP $HTTP_STATUS)"
		else
			fail "$state: $who served on $label" "HTTP $HTTP_STATUS: $(echo "$BODY" | head -c 200)"
		fi
	done
}

# --- jobs ------------------------------------------------------------------
wait_output() {   # JOBNAME JOBID
	local n=0
	while [ $n -lt 60 ]; do
		req O GET "/zosmf/restjobs/jobs/$1/$2"
		[ "$(echo "$BODY" | jq -r '.status' 2> /dev/null)" = OUTPUT ] && return 0
		sleep 1
		n=$((n + 1))
	done
	return 1
}

job_text() {   # JOBNAME JOBID
	local ids id
	req O GET "/zosmf/restjobs/jobs/$1/$2/files"
	ids=$(echo "$BODY" | jq -r '.[].id' 2> /dev/null)
	for id in $ids; do
		req O GET "/zosmf/restjobs/jobs/$1/$2/files/$id/records"
		echo "$BODY"
	done
}

# --- RAKF ------------------------------------------------------------------
PUTS=0
CG_DIRTY=0

compress_cntl() {
	local id
	req O PUT /zosmf/restjobs/jobs -H "Content-Type: text/plain" --data-binary "//CG460CMP JOB (ACCT),'CONSGATE 460',CLASS=A,MSGCLASS=H
//C EXEC PGM=IEBCOPY
//SYSPRINT DD SYSOUT=*
//SYSUT3 DD UNIT=SYSDA,SPACE=(TRK,(5,5))
//SYSUT4 DD UNIT=SYSDA,SPACE=(TRK,(5,5))
//IN DD DSN=SYS1.SECURE.CNTL,DISP=OLD
//SYSIN DD *
 COPY INDD=IN,OUTDD=IN
/*"
	id=$(echo "$BODY" | jq -r '.jobid' 2> /dev/null)
	[ -n "$id" ] && wait_output CG460CMP "$id" && req O DELETE "/zosmf/restjobs/jobs/CG460CMP/$id"
}

put_profiles() {   # local file
	if [ $((PUTS % 8)) = 0 ]; then
		compress_cntl
	fi
	PUTS=$((PUTS + 1))
	CG_DIRTY=1
	req O PUT "/zosmf/restfiles/ds/${PROF}" -H "Content-Type: text/plain" \
		--data-binary @"$1"
	[ "$HTTP_STATUS" = 204 ] || [ "$HTTP_STATUS" = 200 ]
}

reload_rakf() {
	local id out
	req O PUT /zosmf/restjobs/jobs -H "Content-Type: text/plain" --data-binary "//CG460PRF JOB (ACCT),'CONSGATE 460',CLASS=A,MSGCLASS=H,GROUP=RAKFADM
//RAKFPROF EXEC RAKFPROF"
	id=$(echo "$BODY" | jq -r '.jobid' 2> /dev/null)
	[ -n "$id" ] && [ "$id" != null ] || return 1
	wait_output CG460PRF "$id" || return 1
	out=$(job_text CG460PRF "$id")
	req O DELETE "/zosmf/restjobs/jobs/CG460PRF/$id"
	echo "$out" | grep -q 'RAKFPROF7  RAKF PROFILES UPDATED'
}

# Fixture lines: GROUP-or-USER|ACCESS, an empty id is the universal line.
fx_lines() {
	case "$1" in
	O) printf '%s\n' '|NONE' "${OWNER}|READ" ;;
	B) printf '%s\n' '|NONE' "${OWNER}|READ" "${OTHER}|READ" ;;
	*) echo "fx_lines: unknown fixture '$1'" >&2; return 1 ;;
	esac
}

install_fixture() {
	local fx="$1"
	fx_lines "$fx" | awk -F'|' '{ printf "%-8s%-44s%-8s%s\n", "FACILITY", "MVSMF.CONSOLE", $1, $2 }' > "$T/block"
	awk -v blk="$T/block" '
		BEGIN { while ((getline l < blk) > 0) b[++n] = l
		        key = sprintf("%-8s%-44s", "FACILITY", "MVSMF.CONSOLE") }
		!done && $0 !~ /^[*#]/ && substr($0, 1, 52) > key {
			for (i = 1; i <= n; i++) print b[i]
			done = 1
		}
		{ print }
		END { if (!done) for (i = 1; i <= n; i++) print b[i] }' "$T/profiles.orig" > "$T/profiles.new"
	if ! put_profiles "$T/profiles.new"; then
		fail "fixture $fx: PROFILES could not be written" "HTTP $HTTP_STATUS"
		return 1
	fi
	if ! reload_rakf; then
		fail "fixture $fx: the reload (RAKFPROF) did not report RAKFPROF7"
		return 1
	fi
}

restore_all() {
	[ "$CG_DIRTY" = 1 ] || return 0
	local ok=1
	put_profiles "$T/profiles.orig" || ok=0
	CG_DIRTY=0
	reload_rakf || ok=0
	req O GET "/zosmf/restfiles/ds/${PROF}"
	printf '%s\n' "$BODY" > "$T/profiles.now"
	if [ $ok = 1 ] && cmp -s "$T/profiles.orig" "$T/profiles.now"; then
		pass "the fixtures are removed: PROFILES is as it was"
	else
		fail "the fixtures could not be removed: restore ${PROF} by hand and run RAKFPROF"
	fi
}
mvsmf_on_exit "restore_all"

# =========================================================================
# Setup
# =========================================================================
echo ""
echo "=== SETUP ==="

req O GET "/zosmf/restfiles/ds/${PROF}"
if [ "$HTTP_STATUS" != 200 ]; then
	skip "consgate: ${PROF} cannot be read as ${OWNER} (HTTP $HTTP_STATUS): the target user must be a RAKF administrator"
	exit 0
fi
printf '%s\n' "$BODY" > "$T/profiles.orig"
if grep -q '^FACILITYMVSMF.CONSOLE' "$T/profiles.orig"; then
	fail "setup: PROFILES already has lines for FACILITY MVSMF.CONSOLE; the suite needs a clean container"
	exit 1
fi

# =========================================================================
echo ""
echo "=== NO PROFILE: nobody is served ==="
expect_refused O "no profile"
expect_refused U "no profile"
expect_refused_variants O "no profile"
expect_refused_variants U "no profile"

# =========================================================================
echo ""
echo "=== READ for ${OWNER} only ==="
if install_fixture O; then
	expect_served O "profile, READ for ${OWNER}"
	expect_refused U "profile, READ for ${OWNER}"
	expect_refused_variants U "profile, READ for ${OWNER}"
fi

# =========================================================================
echo ""
echo "=== READ for ${OWNER} and ${OTHER} ==="
if install_fixture B; then
	expect_served O "profile, READ for both"
	expect_served U "profile, READ for both"
fi

# =========================================================================
echo ""
echo "=== PROFILE REMOVED, RAKF RELOADED: nobody is served ==="
restore_all
expect_refused O "profile removed"
expect_refused U "profile removed"
expect_refused_variants O "profile removed"
expect_refused_variants U "profile removed"

# =========================================================================
echo ""
echo "=== MEASURED ==="
echo "  state|user|route|path|HTTP|category"
sed 's/^/  /' "$TABLE"

echo ""
echo "=========================================="
echo " Results: ${PASSED} passed, ${FAILED} failed, ${SKIPPED} skipped (${TOTAL} total)"
echo "=========================================="
[ "$FAILED" -eq 0 ]
