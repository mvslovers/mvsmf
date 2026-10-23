#!/bin/bash
# =========================================================================
# mvsMF console services vs. a stopping server - curl test suite (#398)
#
# Issues `P HTTPD` through the console API and checks what the client is told.
#
#   1. The answer carries a body. Once HTTPD quiesces, mvsMF abandons the
#      response capture and answers 503 / 8 / 15 ("issued, capture
#      abandoned"). That report used to leave the server as headers only:
#      the send loop refused the body because the server was quiescing, so
#      the client saw a 503 with Content-Length and no content and could not
#      tell an issued P from a refused one.
#   2. A console command sent after that is refused before it is issued,
#      503 / 8 / 17 -- or the connection is gone because the address space
#      has ended. Never a 200: a command accepted in that window is lost with
#      the address space (an S HTTPD of a restart).
#
# THIS SUITE STOPS HTTPD. Nothing answers afterwards, mbt's own channel to the
# system included, so it is never part of a full run and belongs in a
# throwaway container only (mvsce-target). It is the last thing a container
# does before it is taken down.
#
# Prerequisites:
#   - Run through mbt (see Usage), which hands over the target's
#     connection (tests/lib/conn.sh)
#   - curl and jq must be installed
#
# Usage:
#   mbt run rest-tests -- curl-quiesce
# =========================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/lib/conn.sh"

CONSOLE_URL="${BASE_URL}/zosmf/restconsoles/consoles/defcn"

PASSED=0
FAILED=0
TOTAL=0

pass() { PASSED=$((PASSED + 1)); TOTAL=$((TOTAL + 1)); echo "  PASS: $1"; }
fail() {
	FAILED=$((FAILED + 1)); TOTAL=$((TOTAL + 1)); echo "  FAIL: $1"
	[ -n "${2:-}" ] && echo "        $2"
}

echo ""
echo "========================================"
echo " mvsMF console vs. a stopping server - curl"
echo " Host: ${MVSMF_HOST}:${MVSMF_PORT}"
echo " User: ${MVSMF_USER}"
echo "========================================"

# put_cmd CMD -> BODY on stdout, "\nHTTP_CODE" last; curl's exit status is kept
put_cmd() {
	curl -s --max-time 30 -w '\n%{http_code}' -K "$MVSMF_CURLRC" \
		-X PUT -H 'Content-Type: application/json' \
		-H 'X-CSRF-ZOSMF-HEADER: 1' \
		-d "{\"cmd\":\"$1\"}" "$CONSOLE_URL"
}

echo ""
echo "--- P HTTPD answers with a body ---"
RESP=$(put_cmd "P HTTPD")
CURL_RC=$?
CODE=$(printf '%s' "$RESP" | tail -n 1)
BODY=$(printf '%s' "$RESP" | sed '$d')

if [ "$CURL_RC" -ne 0 ]; then
	fail "P HTTPD was answered" "curl exit $CURL_RC, HTTP $CODE (connection dropped)"
elif [ -z "$BODY" ]; then
	fail "the answer has a body" "HTTP $CODE with an empty body"
elif ! printf '%s' "$BODY" | jq -e . >/dev/null 2>&1; then
	fail "the body is JSON" "HTTP $CODE: $BODY"
else
	pass "the answer has a JSON body (HTTP $CODE)"
	case "$CODE" in
	200)
		pass "the capture finished before the server began to quiesce"
		;;
	503)
		RC=$(printf '%s' "$BODY" | jq -r '."return-code"')
		RSN=$(printf '%s' "$BODY" | jq -r '."reason-code"')
		if [ "$RC" = "8" ] && [ "$RSN" = "15" ]; then
			pass "503 carries return-code 8 / reason-code 15 (issued, capture abandoned)"
		else
			fail "503 carries 8 / 15" "got $RC / $RSN"
		fi
		;;
	*)
		fail "status is 200 or 503" "got $CODE: $BODY"
		;;
	esac
fi

echo ""
echo "--- a command sent while the server stops is refused or unreachable ---"
if [ "$CODE" = "503" ]; then
	RESP=$(put_cmd "D T")
	CURL_RC=$?
	CODE2=$(printf '%s' "$RESP" | tail -n 1)
	BODY2=$(printf '%s' "$RESP" | sed '$d')
	if [ "$CURL_RC" -ne 0 ]; then
		pass "no answer: the address space has already ended (curl exit $CURL_RC)"
	elif [ "$CODE2" = "503" ] &&
	     [ "$(printf '%s' "$BODY2" | jq -r '."return-code"' 2>/dev/null)" = "8" ] &&
	     [ "$(printf '%s' "$BODY2" | jq -r '."reason-code"' 2>/dev/null)" = "17" ]; then
		pass "503 / 8 / 17: refused before it was issued, with a body"
	else
		fail "refused with 503 / 8 / 17 or unreachable" "HTTP $CODE2: $BODY2"
	fi
else
	echo "  SKIP: P HTTPD was not answered 503, so there is no stopping window to probe"
fi

echo ""
echo "========================================"
echo " Passed: ${PASSED} / ${TOTAL}   Failed: ${FAILED}"
echo "========================================"

[ "$FAILED" -eq 0 ]
