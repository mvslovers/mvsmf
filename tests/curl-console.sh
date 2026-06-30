#!/bin/bash
# =========================================================================
# mvsMF Console services REST API - curl test suite
#
# Tests the console "issue command" endpoint (endpoint 1):
#   PUT /zosmf/restconsoles/consoles/{console-name}
#
# Covers: synchronous + asynchronous issue, single- and multi-line (MLWTO)
# responses, solicited-keyword detection, and the error cases.
#
# Prerequisites:
#   - Copy .env.example to .env at the repo root and fill in
#   - curl and jq must be installed
#
# Usage:
#   ./tests/curl-console.sh
# =========================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
	echo "ERROR: ${ENV_FILE} not found."
	echo "Copy .env.example to .env and fill in your values."
	exit 1
fi

# shellcheck source=../.env
. "$ENV_FILE"

BASE_URL="http://${MVSMF_HOST}:${MVSMF_PORT}"
AUTH="${MVSMF_USER}:${MVSMF_PASS}"
CONSOLE="${BASE_URL}/zosmf/restconsoles/consoles/defcn"

# --- state ---
PASSED=0
FAILED=0
SKIPPED=0
TOTAL=0

pass() { PASSED=$((PASSED + 1)); TOTAL=$((TOTAL + 1)); echo "  PASS: $1"; }
fail() {
	FAILED=$((FAILED + 1)); TOTAL=$((TOTAL + 1)); echo "  FAIL: $1"
	[ -n "${2:-}" ] && echo "        $2"
}

assert_http_status() {
	if [ "$2" = "$1" ]; then pass "$3 (HTTP $2)"
	else fail "$3" "expected HTTP $1, got $2"; fi
}

assert_json_field() {
	local actual
	actual=$(echo "$1" | jq -r "$2" 2>/dev/null) || actual=""
	if [ "$actual" = "$3" ]; then pass "$4 ($2=$actual)"
	else fail "$4" "$2: expected '$3', got '$actual'"; fi
}

assert_json_exists() {
	local val rc=0
	val=$(echo "$1" | jq -e "$2" 2>/dev/null) || rc=$?
	if [ $rc -eq 0 ] && [ "$val" != "null" ]; then pass "$3 ($2 present)"
	else fail "$3" "$2 missing or null"; fi
}

assert_json_absent() {
	local val rc=0
	val=$(echo "$1" | jq -e "$2" 2>/dev/null) || rc=$?
	if [ $rc -ne 0 ] || [ "$val" = "null" ]; then pass "$3 ($2 absent)"
	else fail "$3" "$2 unexpectedly present: $val"; fi
}

assert_contains() {
	# $1=json $2=jq-field $3=substring $4=label
	local actual
	actual=$(echo "$1" | jq -r "$2" 2>/dev/null) || actual=""
	case "$actual" in
		*"$3"*) pass "$4 ($2 contains '$3')" ;;
		*)      fail "$4" "$2 does not contain '$3': '$actual'" ;;
	esac
}

# PUT a command body, echo "BODY\nHTTP_CODE"
issue() {
	# $1 = json body, $2 = console url (optional, default $CONSOLE)
	curl -s -w '\n%{http_code}' -u "$AUTH" -X PUT \
		-H "Content-Type: application/json" \
		-d "$1" "${2:-$CONSOLE}"
}

echo ""
echo "========================================"
echo " mvsMF Console API - curl test suite"
echo " Host: ${MVSMF_HOST}:${MVSMF_PORT}"
echo " User: ${MVSMF_USER}"
echo "========================================"

# =========================================================================
# 1. Synchronous, single-line response (D T -> IEE136I)
# =========================================================================
echo ""
echo "--- sync: D T ---"
RESP=$(issue '{"cmd":"D T"}')
CODE=$(echo "$RESP" | tail -1); BODY=$(echo "$RESP" | sed '$d')
assert_http_status "200" "$CODE" "issue D T"
assert_json_exists  "$BODY" '.["cmd-response"]'     "D T: cmd-response present"
assert_contains     "$BODY" '.["cmd-response"]' "IEE136I" "D T: response has IEE136I"
assert_json_exists  "$BODY" '.["cmd-response-key"]' "D T: key present"
assert_json_exists  "$BODY" '.["cmd-response-url"]' "D T: url present"
assert_json_exists  "$BODY" '.["cmd-response-uri"]' "D T: uri present"

# =========================================================================
# 2. Synchronous, multi-line MLWTO response (D A,L -> IEE102I + continuations)
# =========================================================================
echo ""
echo "--- sync: D A,L (multi-line) ---"
RESP=$(issue '{"cmd":"D A,L"}')
CODE=$(echo "$RESP" | tail -1); BODY=$(echo "$RESP" | sed '$d')
assert_http_status "200" "$CODE" "issue D A,L"
assert_contains    "$BODY" '.["cmd-response"]' "IEE102I" "D A,L: response has IEE102I header"
# the response should span more than one line (\r separators)
LINES=$(echo "$BODY" | jq -r '.["cmd-response"]' 2>/dev/null | tr '\r' '\n' | grep -c .)
if [ "${LINES:-0}" -ge 2 ]; then pass "D A,L: multi-line (${LINES} lines)"
else fail "D A,L: multi-line" "got ${LINES} line(s)"; fi

# =========================================================================
# 3. Asynchronous issue (no cmd-response, key returned)
# =========================================================================
echo ""
echo "--- async: D T ---"
RESP=$(issue '{"cmd":"D T","async":"Y"}')
CODE=$(echo "$RESP" | tail -1); BODY=$(echo "$RESP" | sed '$d')
assert_http_status "200" "$CODE" "issue D T async"
assert_json_exists "$BODY" '.["cmd-response-key"]' "async: key present"
assert_json_absent "$BODY" '.["cmd-response"]'     "async: no cmd-response"

# =========================================================================
# 4. Solicited keyword detection
# =========================================================================
echo ""
echo "--- sol-key ---"
RESP=$(issue '{"cmd":"D T","sol-key":"DATE"}')
BODY=$(echo "$RESP" | sed '$d')
assert_json_field "$BODY" '.["sol-key-detected"]' "true"  "sol-key DATE detected"
RESP=$(issue '{"cmd":"D T","sol-key":"ZZNOMATCH"}')
BODY=$(echo "$RESP" | sed '$d')
assert_json_field "$BODY" '.["sol-key-detected"]' "false" "sol-key ZZNOMATCH not detected"

# =========================================================================
# 5. Collect (async issue -> poll deltas -> empty when done)
# =========================================================================
echo ""
echo "--- collect ---"

# async issue D A,L (no cmd-response in the issue reply); grab the key
RESP=$(issue '{"cmd":"D A,L","async":"Y"}')
BODY=$(echo "$RESP" | sed '$d')
KEY=$(echo "$BODY" | jq -r '.["cmd-response-key"]' 2>/dev/null)

if [ -n "$KEY" ] && [ "$KEY" != "null" ]; then
	sleep 5   # let the multi-line response land in the trace table
	# first collect: the full response block
	RESP=$(curl -s -w '\n%{http_code}' -u "$AUTH" "${CONSOLE}/solmsgs/${KEY}")
	CODE=$(echo "$RESP" | tail -1); CBODY=$(echo "$RESP" | sed '$d')
	assert_http_status "200" "$CODE" "collect #1"
	assert_contains "$CBODY" '.["cmd-response"]' "IEE102I" "collect #1: returns the response"
	# second collect: empty (cursor advanced -> done)
	CBODY=$(curl -s -u "$AUTH" "${CONSOLE}/solmsgs/${KEY}")
	assert_json_field "$CBODY" '.["cmd-response"]' "" "collect #2: empty (done)"
else
	fail "async issue returned no cmd-response-key"
fi

# sync issue already delivered its response -> its first collect is empty
RESP=$(issue '{"cmd":"D T"}')
BODY=$(echo "$RESP" | sed '$d')
KEY=$(echo "$BODY" | jq -r '.["cmd-response-key"]' 2>/dev/null)
CBODY=$(curl -s -u "$AUTH" "${CONSOLE}/solmsgs/${KEY}")
assert_json_field "$CBODY" '.["cmd-response"]' "" "collect after sync issue: empty"

# unknown / stale key -> empty, HTTP 200 (not an error)
RESP=$(curl -s -w '\n%{http_code}' -u "$AUTH" "${CONSOLE}/solmsgs/DEADBEEFCAFE0000")
CODE=$(echo "$RESP" | tail -1); CBODY=$(echo "$RESP" | sed '$d')
assert_http_status "200" "$CODE" "collect bogus key"
assert_json_field "$CBODY" '.["cmd-response"]' "" "collect bogus: empty"

# =========================================================================
# 6. Unsolicited keyword detection
# =========================================================================
echo ""
echo "--- detection ---"

# async: watch for IEE136I (which D T produces) -> detection-key + detected
RESP=$(issue '{"cmd":"D T","unsol-key":"IEE136I"}')
BODY=$(echo "$RESP" | sed '$d')
DKEY=$(echo "$BODY" | jq -r '.["detection-key"]' 2>/dev/null)
assert_json_exists "$BODY" '.["detection-key"]' "async detect: detection-key present"
assert_json_exists "$BODY" '.["detection-url"]' "async detect: detection-url present"
if [ -n "$DKEY" ] && [ "$DKEY" != "null" ]; then
	sleep 3
	RESP=$(curl -s -u "$AUTH" "${CONSOLE}/detections/${DKEY}")
	assert_json_field "$RESP" '.status' "detected" "detection: detected"
	assert_contains   "$RESP" '.msg' "IEE136I" "detection: msg has IEE136I"
fi

# waiting: a keyword that will not appear, long window
RESP=$(issue '{"cmd":"D T","unsol-key":"ZZNOMATCH99","detect-time":"60"}')
BODY=$(echo "$RESP" | sed '$d')
DKEY=$(echo "$BODY" | jq -r '.["detection-key"]' 2>/dev/null)
if [ -n "$DKEY" ] && [ "$DKEY" != "null" ]; then
	RESP=$(curl -s -u "$AUTH" "${CONSOLE}/detections/${DKEY}")
	assert_json_field "$RESP" '.status' "waiting" "detection: waiting (no match yet)"
fi

# unknown detection key -> 500 / 5 / 9
RESP=$(curl -s -w '\n%{http_code}' -u "$AUTH" "${CONSOLE}/detections/DBADBAD0")
CODE=$(echo "$RESP" | tail -1); CBODY=$(echo "$RESP" | sed '$d')
assert_http_status "500" "$CODE" "detection unknown key"
assert_json_field  "$CBODY" '.["reason-code"]' "9" "unknown detection: reason-code 9"

# sync: issue + wait inline for IEE136I
RESP=$(issue '{"cmd":"D T","unsol-key":"IEE136I","unsol-detect-sync":"Y","unsol-detect-timeout":"10"}')
BODY=$(echo "$RESP" | sed '$d')
assert_json_field "$BODY" '.status' "detected" "sync detect: detected"
assert_contains   "$BODY" '.msg' "IEE136I" "sync detect: msg has IEE136I"

# =========================================================================
# 7. Error cases
# =========================================================================
echo ""
echo "--- errors ---"

# missing cmd -> 400 / 1 / 13
RESP=$(issue '{}')
CODE=$(echo "$RESP" | tail -1); BODY=$(echo "$RESP" | sed '$d')
assert_http_status "400" "$CODE" "missing cmd"
assert_json_field  "$BODY" '.["return-code"]' "1"  "missing cmd: return-code 1"
assert_json_field  "$BODY" '.["reason-code"]' "13" "missing cmd: reason-code 13"

# bad Content-Type -> 400 / 1 / 6
RESP=$(curl -s -w '\n%{http_code}' -u "$AUTH" -X PUT \
	-H "Content-Type: text/plain" -d '{"cmd":"D T"}' "$CONSOLE")
CODE=$(echo "$RESP" | tail -1); BODY=$(echo "$RESP" | sed '$d')
assert_http_status "400" "$CODE" "bad content-type"
assert_json_field  "$BODY" '.["reason-code"]' "6" "bad content-type: reason-code 6"

# console name too short -> 400 / 1 / 14
RESP=$(issue '{"cmd":"D T"}' "${BASE_URL}/zosmf/restconsoles/consoles/x")
CODE=$(echo "$RESP" | tail -1); BODY=$(echo "$RESP" | sed '$d')
assert_http_status "400" "$CODE" "console name too short"
assert_json_field  "$BODY" '.["reason-code"]' "14" "short name: reason-code 14"

# command too long (>126) -> 400 / 1 / 17
LONGCMD=$(printf 'D %0.s' $(seq 1 130))
RESP=$(issue "{\"cmd\":\"${LONGCMD}\"}")
CODE=$(echo "$RESP" | tail -1); BODY=$(echo "$RESP" | sed '$d')
assert_http_status "400" "$CODE" "command too long"
assert_json_field  "$BODY" '.["reason-code"]' "17" "long cmd: reason-code 17"

# foreign system -> 400 / 1 / 5
RESP=$(issue '{"cmd":"D T","system":"NOTASYS"}')
CODE=$(echo "$RESP" | tail -1); BODY=$(echo "$RESP" | sed '$d')
assert_http_status "400" "$CODE" "foreign system"
assert_json_field  "$BODY" '.["reason-code"]' "5" "foreign system: reason-code 5"

# =========================================================================
# Summary
# =========================================================================
echo ""
echo "========================================"
echo " Total: ${TOTAL}  Passed: ${PASSED}  Failed: ${FAILED}  Skipped: ${SKIPPED}"
echo "========================================"
[ "$FAILED" -eq 0 ]
