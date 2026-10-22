#!/bin/bash
# =========================================================================
# mvsMF job spool authorization - curl test suite (#440)
#
# Who may see, read and purge which job of the JES2 spool:
#   - a job of the caller's own userid is always allowed
#   - a job of another owner needs the RACF class JESSPOOL, resource
#     <owner>.<jobname>.<jobid>:
#       no profile, NONE   hidden: the same 404 a missing job gets
#       READ               listed and read, purge refused (500, category 4)
#       UPDATE or better   also purged
#   - the owner filter of the job list: "*" needs READ on "..", another
#     userid needs READ on "<userid>.."
#
# The suite works with two users of the mbt target: the target's own user
# (MVSMF_USER, must be a RAKF administrator, group RAKFADM) owns the jobs and
# writes the profiles, and the further user test2 (MVSMF_USER2, an ordinary
# user) is the one the policy is applied to.
#
# It CHANGES the system under test: it writes SYS1.SECURE.CNTL(PROFILES), runs
# the RAKF procedure RAKFPROF to load it, and puts the member back the way it
# found it. Use a throwaway container, never a real system. It refuses to run
# when PROFILES already has JESSPOOL lines, and needs RAKF 2.0.0 (the class
# JESSPOOL does not exist before).
#
# Prerequisites:
#   - Run through mbt, which hands over the target's connection
#     (tests/lib/conn.sh); curl and jq must be installed
#
# Usage:
#   mbt run rest-tests -- curl-jesspool
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

if [ -z "${MVSMF_CURLRC2:-}" ]; then
	skip "jesspool: needs a further user test2 in the mbt target"
	exit 0
fi
command -v jq > /dev/null || { echo "ERROR: jq is required" >&2; exit 1; }

OWNER="$MVSMF_USER"     # RAKF administrator, owns JW440A
OTHER="$MVSMF_USER2"    # ordinary user, owns JW440B, is the one checked
PROF="SYS1.SECURE.CNTL(PROFILES)"
T=$(mktemp -d "${TMPDIR:-/tmp}/jesspool.XXXXXX")
mvsmf_on_exit "rm -rf -- $(printf '%q' "$T")"

# --- requests --------------------------------------------------------------
# req WHO METHOD PATH [curl args]: sets HTTP_STATUS and BODY.
# WHO is O (the owner, administrator) or U (the ordinary user).
req() {
	local who="$1" method="$2" path="$3" rc resp
	shift 3
	if [ "$who" = U ]; then rc="$MVSMF_CURLRC2"; else rc="$MVSMF_CURLRC"; fi
	resp=$(curl -s -w '\n%{http_code}' -X "$method" -K "$rc" \
		-H 'X-CSRF-ZOSMF-HEADER: 1' "$@" "${BASE_URL}${path}")
	HTTP_STATUS=$(echo "$resp" | tail -n1)
	BODY=$(echo "$resp" | sed '$d')
}

check_status() {   # expected label
	if [ "$HTTP_STATUS" = "$1" ]; then
		pass "$2 (HTTP $HTTP_STATUS)"
	else
		fail "$2" "expected HTTP $1, got $HTTP_STATUS: $(echo "$BODY" | head -c 200)"
	fi
}

# Does the job list in BODY hold job id $1?
listed() { echo "$BODY" | jq -e --arg id "$1" 'map(select(.jobid == $id)) | length > 0' > /dev/null 2>&1; }

# --- jobs ------------------------------------------------------------------
submit() {   # WHO JOBNAME: JOBNAME/JOBID is left in SUB_ID
	local who="$1" name="$2"
	req "$who" PUT /zosmf/restjobs/jobs -H "Content-Type: text/plain" \
		--data-binary "//${name} JOB (ACCT),'JESSPOOL 440',CLASS=A,MSGCLASS=H
//S1 EXEC PGM=IEFBR14"
	SUB_ID=""
	if [ "$HTTP_STATUS" = 200 ]; then
		SUB_ID=$(echo "$BODY" | jq -r '.jobid')
	fi
	[ -n "$SUB_ID" ] && [ "$SUB_ID" != null ]
}

wait_output() {   # WHO JOBNAME JOBID
	local n=0
	while [ $n -lt 60 ]; do
		req "$1" GET "/zosmf/restjobs/jobs/$2/$3"
		[ "$(echo "$BODY" | jq -r '.status' 2> /dev/null)" = OUTPUT ] && return 0
		sleep 1
		n=$((n + 1))
	done
	return 1
}

# The text of every spool file of a job of the owner's, for the RAKFPROF
# messages.
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
JW_DIRTY=0

compress_cntl() {
	local id
	req O PUT /zosmf/restjobs/jobs -H "Content-Type: text/plain" --data-binary "//JW440CMP JOB (ACCT),'JESSPOOL 440',CLASS=A,MSGCLASS=H
//C EXEC PGM=IEBCOPY
//SYSPRINT DD SYSOUT=*
//SYSUT3 DD UNIT=SYSDA,SPACE=(TRK,(5,5))
//SYSUT4 DD UNIT=SYSDA,SPACE=(TRK,(5,5))
//IN DD DSN=SYS1.SECURE.CNTL,DISP=OLD
//SYSIN DD *
 COPY INDD=IN,OUTDD=IN
/*"
	id=$(echo "$BODY" | jq -r '.jobid' 2> /dev/null)
	[ -n "$id" ] && wait_output O JW440CMP "$id" && req O DELETE "/zosmf/restjobs/jobs/JW440CMP/$id"
}

put_profiles() {   # local file
	if [ $((PUTS % 8)) = 0 ]; then
		compress_cntl
	fi
	PUTS=$((PUTS + 1))
	JW_DIRTY=1
	req O PUT "/zosmf/restfiles/ds/${PROF}" -H "Content-Type: text/plain" \
		--data-binary @"$1"
	[ "$HTTP_STATUS" = 204 ] || [ "$HTTP_STATUS" = 200 ]
}

reload_rakf() {
	local id out
	req O PUT /zosmf/restjobs/jobs -H "Content-Type: text/plain" --data-binary "//JW440PRF JOB (ACCT),'JESSPOOL 440',CLASS=A,MSGCLASS=H,GROUP=RAKFADM
//RAKFPROF EXEC RAKFPROF"
	id=$(echo "$BODY" | jq -r '.jobid' 2> /dev/null)
	[ -n "$id" ] && [ "$id" != null ] || return 1
	wait_output O JW440PRF "$id" || return 1
	out=$(job_text JW440PRF "$id")
	req O DELETE "/zosmf/restjobs/jobs/JW440PRF/$id"
	echo "$out" | grep -q 'RAKFPROF7  RAKF PROFILES UPDATED'
}

# Fixture lines: ENTITY|GROUP|ACCESS, an empty group is the universal line.
fx_lines() {
	case "$1" in
	0) ;;
	N) printf '%s\n' '*||NONE' ;;
	R) printf '%s\n' '*||NONE' "${OWNER}.*||READ" ;;
	A) printf '%s\n' '*||READ' ;;
	D) printf '%s\n' '*||NONE' '*|ADMIN|UPDATE' ;;
	W) printf '%s\n' '*||NONE' "${OWNER}.*||UPDATE" "${OTHER}.*||UPDATE" ;;
	*) echo "fx_lines: unknown fixture '$1'" >&2; return 1 ;;
	esac
}

FX_CUR=""
install_fixture() {
	local fx="$1"
	fx_lines "$fx" | awk -F'|' '{ printf "%-8s%-44s%-8s%s\n", "JESSPOOL", $1, $2, $3 }' > "$T/block"
	awk -v blk="$T/block" '
		BEGIN { while ((getline l < blk) > 0) b[++n] = l }
		!done && $0 !~ /^[*#]/ && substr($0, 1, 8) > "JESSPOOL" {
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
	FX_CUR="$fx"
}

restore_all() {
	[ "$JW_DIRTY" = 1 ] || return 0
	local ok=1
	put_profiles "$T/profiles.orig" || ok=0
	JW_DIRTY=0
	reload_rakf || ok=0
	req O GET "/zosmf/restfiles/ds/${PROF}"
	printf '%s\n' "$BODY" > "$T/profiles.now"
	if [ $ok = 1 ] && cmp -s "$T/profiles.orig" "$T/profiles.now"; then
		pass "the fixtures are removed: PROFILES is as it was"
	else
		fail "the fixtures could not be removed: restore ${PROF} by hand and run RAKFPROF"
	fi
}

purge_jobs() {
	[ -n "${OJ_ID:-}" ] && req O DELETE "/zosmf/restjobs/jobs/JW440A/${OJ_ID}"
	[ -n "${UJ_ID:-}" ] && req U DELETE "/zosmf/restjobs/jobs/JW440B/${UJ_ID}"
	return 0
}
OJ_ID=""
UJ_ID=""
mvsmf_on_exit "purge_jobs; restore_all"

# =========================================================================
# Setup
# =========================================================================
echo ""
echo "=== SETUP ==="

req O GET "/zosmf/restfiles/ds/${PROF}"
if [ "$HTTP_STATUS" != 200 ]; then
	skip "jesspool: ${PROF} cannot be read as ${OWNER} (HTTP $HTTP_STATUS): the target user must be a RAKF administrator"
	exit 0
fi
printf '%s\n' "$BODY" > "$T/profiles.orig"
if grep -q '^JESSPOOL' "$T/profiles.orig"; then
	fail "setup: PROFILES already has JESSPOOL lines; the suite needs a clean container"
	exit 1
fi

if ! submit O JW440A; then
	fail "setup: job JW440A of ${OWNER} was not submitted" "HTTP $HTTP_STATUS"
	exit 1
fi
OJ_ID="$SUB_ID"
if ! submit U JW440B; then
	fail "setup: job JW440B of ${OTHER} was not submitted" "HTTP $HTTP_STATUS"
	exit 1
fi
UJ_ID="$SUB_ID"
echo "  ${OWNER}: JW440A/${OJ_ID}   ${OTHER}: JW440B/${UJ_ID}"
wait_output O JW440A "$OJ_ID" || fail "setup: JW440A/${OJ_ID} did not reach OUTPUT"
wait_output U JW440B "$UJ_ID" || fail "setup: JW440B/${UJ_ID} did not reach OUTPUT"

# =========================================================================
# The cases
# =========================================================================
OPATH="/zosmf/restjobs/jobs/JW440A/${OJ_ID}"
UPATH="/zosmf/restjobs/jobs/JW440B/${UJ_ID}"

# A job the caller may not see: every way in answers 404, like a missing job.
hidden_for_U() {   # fixture label
	local l="$1"

	req U GET "$OPATH";                     check_status 404 "$l: status of a foreign job is hidden"
	local hidden_body="$BODY"
	req U GET "/zosmf/restjobs/jobs/JW440A/JOB99999"
	local missing_body="$BODY"
	if [ "$HTTP_STATUS" = 404 ] && [ "${hidden_body//${OJ_ID}/X}" = "${missing_body//JOB99999/X}" ]; then
		pass "$l: the hidden job answers exactly like a missing one"
	else
		fail "$l: the hidden job answers differently from a missing one" \
			"hidden: $hidden_body / missing: $missing_body"
	fi
	req U GET "${OPATH}/files";             check_status 404 "$l: spool files of a foreign job are hidden"
	req U GET "${OPATH}/files/2/records";   check_status 404 "$l: spool records of a foreign job are hidden"
	req U DELETE "$OPATH";                  check_status 404 "$l: purge of a foreign job is hidden"
	req O GET "$OPATH";                     check_status 200 "$l: the foreign purge did not purge"

	req U GET "/zosmf/restjobs/jobs?owner=${OWNER}&prefix=JW440*"
	if [ "$HTTP_STATUS" = 200 ] && [ "$(echo "$BODY" | jq 'length')" = 0 ]; then
		pass "$l: owner=${OWNER} lists nothing (empty 200)"
	else
		fail "$l: owner=${OWNER} lists nothing" "HTTP $HTTP_STATUS $(echo "$BODY" | head -c 200)"
	fi
	req U GET "/zosmf/restjobs/jobs?owner=*&prefix=JW440*"
	if [ "$HTTP_STATUS" = 200 ] && ! listed "$OJ_ID" && listed "$UJ_ID"; then
		pass "$l: owner=* shows only the caller's own jobs"
	else
		fail "$l: owner=* shows only the caller's own jobs" "HTTP $HTTP_STATUS $(echo "$BODY" | head -c 200)"
	fi
	req U GET "/zosmf/restjobs/jobs?prefix=JW440*"
	if [ "$HTTP_STATUS" = 200 ] && ! listed "$OJ_ID" && listed "$UJ_ID"; then
		pass "$l: the default list shows only the caller's own jobs"
	else
		fail "$l: the default list shows only the caller's own jobs" "HTTP $HTTP_STATUS"
	fi

	req U GET "/zosmf/test?fn=job&jobname=JW440A"
	if [ "$HTTP_STATUS" = 404 ]; then
		skip "$l: /zosmf/test is not in this build"
	elif echo "$BODY" | jq -e '.count == 0' > /dev/null 2>&1; then
		pass "$l: the test endpoint's job probe hides the foreign job"
	else
		fail "$l: the test endpoint's job probe hides the foreign job" "$(echo "$BODY" | head -c 200)"
	fi
}

# The caller's own jobs and the owner's own jobs, whatever the profiles say.
own_always() {   # label
	local l="$1"

	req U GET "$UPATH";                       check_status 200 "$l: ${OTHER} reads the own job"
	req U GET "${UPATH}/files";               check_status 200 "$l: ${OTHER} lists the own spool files"
	req O GET "$OPATH";                       check_status 200 "$l: ${OWNER} reads the own job"
	req O GET "/zosmf/restjobs/jobs?prefix=JW440*"
	if [ "$HTTP_STATUS" = 200 ] && listed "$OJ_ID"; then
		pass "$l: the owner's list shows the own job"
	else
		fail "$l: the owner's list shows the own job" "HTTP $HTTP_STATUS"
	fi
}

echo ""
echo "--- Fixture 0: no JESSPOOL profile at all ---"
FX_CUR=0
own_always "no profile"
hidden_for_U "no profile"
req O GET "$UPATH";  check_status 404 "no profile: even the administrator does not see a foreign job"
req O GET "/zosmf/restjobs/jobs?owner=*&prefix=JW440*"
if [ "$HTTP_STATUS" = 200 ] && listed "$OJ_ID" && ! listed "$UJ_ID"; then
	pass "no profile: owner=* of the administrator shows only the own jobs"
else
	fail "no profile: owner=* of the administrator shows only the own jobs" "HTTP $HTTP_STATUS"
fi

echo ""
echo "--- Fixture N: JESSPOOL * UACC(NONE) ---"
if install_fixture N; then
	own_always "UACC NONE"
	hidden_for_U "UACC NONE"
fi

echo ""
echo "--- Fixture R: ${OWNER}.* UACC(READ) ---"
if install_fixture R; then
	own_always "READ"
	req U GET "$OPATH";                     check_status 200 "READ: status of a readable foreign job"
	req U GET "${OPATH}/files";             check_status 200 "READ: spool files of a readable foreign job"
	req U GET "${OPATH}/files/2/records";   check_status 200 "READ: spool records of a readable foreign job"
	req U GET "/zosmf/restjobs/jobs?owner=${OWNER}&prefix=JW440*"
	if [ "$HTTP_STATUS" = 200 ] && listed "$OJ_ID"; then
		pass "READ: owner=${OWNER} lists the foreign job (READ on ${OWNER}..)"
	else
		fail "READ: owner=${OWNER} lists the foreign job" "HTTP $HTTP_STATUS $(echo "$BODY" | head -c 200)"
	fi
	req U GET "/zosmf/restjobs/jobs?owner=*&prefix=JW440*"
	if [ "$HTTP_STATUS" = 200 ] && ! listed "$OJ_ID" && listed "$UJ_ID"; then
		pass "READ: owner=* without READ on .. shows only the own jobs"
	else
		fail "READ: owner=* without READ on .. shows only the own jobs" "HTTP $HTTP_STATUS"
	fi
	req U GET "/zosmf/restjobs/jobs?owner=${OWNER:0:3}*&prefix=JW440*"
	if [ "$HTTP_STATUS" = 200 ] && [ "$(echo "$BODY" | jq 'length')" = 0 ]; then
		pass "READ: a prefix pattern as owner matches nothing"
	else
		fail "READ: a prefix pattern as owner matches nothing" "HTTP $HTTP_STATUS"
	fi
	req U GET "/zosmf/restjobs/jobs/JW440A/${OJ_ID%?}*"
	check_status 404 "READ: a wildcard job id does not match"
	req U DELETE "$OPATH"
	if [ "$HTTP_STATUS" = 500 ] && [ "$(echo "$BODY" | jq -r '.category')" = 4 ]; then
		pass "READ: purge needs UPDATE (HTTP 500, category 4)"
	else
		fail "READ: purge needs UPDATE" "HTTP $HTTP_STATUS $(echo "$BODY" | head -c 200)"
	fi
	req O GET "$OPATH";                     check_status 200 "READ: the refused purge did not purge"
	req U GET "/zosmf/test?fn=job&jobname=JW440A"
	if [ "$HTTP_STATUS" = 404 ]; then
		skip "READ: /zosmf/test is not in this build"
	elif echo "$BODY" | jq -e '.count == 1' > /dev/null 2>&1; then
		pass "READ: the test endpoint's job probe shows the readable job"
	else
		fail "READ: the test endpoint's job probe shows the readable job" "$(echo "$BODY" | head -c 200)"
	fi
	req O GET "$UPATH";                     check_status 404 "READ: ${OWNER} has no profile for ${OTHER}'s job"
fi

echo ""
echo "--- Fixture A: JESSPOOL * UACC(READ) ---"
if install_fixture A; then
	req U GET "/zosmf/restjobs/jobs?owner=*&prefix=JW440*"
	if [ "$HTTP_STATUS" = 200 ] && listed "$OJ_ID" && listed "$UJ_ID"; then
		pass "UACC READ: owner=* with READ on .. lists every owner"
	else
		fail "UACC READ: owner=* with READ on .. lists every owner" "HTTP $HTTP_STATUS"
	fi
	req U GET "$OPATH";                     check_status 200 "UACC READ: status of a foreign job"
	req O GET "$UPATH";                     check_status 200 "UACC READ: ${OWNER} reads ${OTHER}'s job"
	req O DELETE "$UPATH"
	if [ "$HTTP_STATUS" = 500 ]; then
		pass "UACC READ: ${OWNER} may not purge ${OTHER}'s job (HTTP 500)"
	else
		fail "UACC READ: ${OWNER} may not purge ${OTHER}'s job" "HTTP $HTTP_STATUS"
	fi
	req U GET "/zosmf/restjobs/jobs/JW440A/${OJ_ID%?}*"
	check_status 404 "UACC READ: a wildcard job id does not match"
fi

echo ""
echo "--- Fixture D: JESSPOOL * UACC(NONE), group ADMIN UPDATE ---"
if install_fixture D; then
	req O GET "/zosmf/restjobs/jobs?owner=*&prefix=JW440*"
	if [ "$HTTP_STATUS" = 200 ] && listed "$OJ_ID" && listed "$UJ_ID"; then
		pass "group UPDATE: owner=* of the administrator lists every owner"
	else
		fail "group UPDATE: owner=* of the administrator lists every owner" "HTTP $HTTP_STATUS"
	fi
	req O GET "$UPATH";                     check_status 200 "group UPDATE: ${OWNER} reads ${OTHER}'s job"
	req U GET "$OPATH";                     check_status 404 "group UPDATE: ${OTHER} is not in the group and sees nothing"
	req U GET "/zosmf/restjobs/jobs?owner=*&prefix=JW440*"
	if [ "$HTTP_STATUS" = 200 ] && ! listed "$OJ_ID" && listed "$UJ_ID"; then
		pass "group UPDATE: owner=* of ${OTHER} still shows only the own jobs"
	else
		fail "group UPDATE: owner=* of ${OTHER} still shows only the own jobs" "HTTP $HTTP_STATUS"
	fi
fi

echo ""
echo "--- Fixture W: ${OWNER}.* and ${OTHER}.* UACC(UPDATE) ---"
if install_fixture W; then
	req U DELETE "$OPATH";                  check_status 200 "UPDATE: ${OTHER} purges ${OWNER}'s job"
	req O GET "$OPATH";                     check_status 404 "UPDATE: the job is gone"
	OJ_ID=""
	req O DELETE "$UPATH";                  check_status 200 "UPDATE: ${OWNER} purges ${OTHER}'s job"
	req U GET "$UPATH";                     check_status 404 "UPDATE: the job is gone for its owner as well"
	UJ_ID=""
fi

# =========================================================================
echo ""
restore_all

echo ""
echo "=========================================="
echo " JESSPOOL: ${PASSED} passed, ${FAILED} failed, ${SKIPPED} skipped (${TOTAL})"
echo "=========================================="
[ "$FAILED" -eq 0 ]
