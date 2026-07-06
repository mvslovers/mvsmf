#!/bin/bash
# =========================================================================
# mvsMF Authentication service REST API - curl test suite
#
# Tests the z/OSMF Authentication service:
#   POST   /zosmf/services/authenticate   (log in  -> LtpaToken2 cookie)
#   DELETE /zosmf/services/authenticate   (log out -> 204)
#
# Covers: login (200 + Set-Cookie + body), token replay on a gated endpoint,
# invalid credentials (401), logout (204), no-token logout, and that the token
# is rejected after logout.
#
# One assertion adapts to the httpd route policy: the z/OSMF-shaped JSON body on
# a bad login only appears when httpd forwards the authenticate route to mvsMF
# (rather than answering bad creds with its own 401). It is asserted when the
# body is present, else reported as SKIP.
#
# Prerequisites:
#   - Copy .env.example to .env at the repo root and fill in
#   - curl and jq must be installed
#
# Usage:
#   ./tests/curl-auth.sh
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
AUTH_URL="${BASE_URL}/zosmf/services/authenticate"
# A gated endpoint used to prove a token is (or is no longer) accepted.
GATED_URL="${BASE_URL}/zosmf/restfiles/ds?dslevel=SYS1.**"
AUTH="${MVSMF_USER}:${MVSMF_PASS}"

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
skip() { SKIPPED=$((SKIPPED + 1)); TOTAL=$((TOTAL + 1)); echo "  SKIP: $1"; }

assert_http_status() {
	if [ "$2" = "$1" ]; then pass "$3 (HTTP $2)"
	else fail "$3" "expected HTTP $1, got $2"; fi
}

assert_not_status() {
	if [ "$2" != "$1" ]; then pass "$3 (HTTP $2, not $1)"
	else fail "$3" "unexpected HTTP $1"; fi
}

assert_json_field() {
	local actual
	actual=$(echo "$1" | jq -r "$2" 2>/dev/null) || actual=""
	if [ "$actual" = "$3" ]; then pass "$4 ($2=$actual)"
	else fail "$4" "$2: expected '$3', got '$actual'"; fi
}

HDRS=$(mktemp)
BODYF=$(mktemp)
trap 'rm -f "$HDRS" "$BODYF"' EXIT

# POST a login; sets CODE, BODY, and writes response headers to $HDRS.
login() {
	# $1 = "user:pass"
	CODE=$(curl -s -X POST \
		-u "$1" \
		-H 'X-CSRF-ZOSMF-HEADER: *' \
		-D "$HDRS" -o "$BODYF" -w '%{http_code}' \
		"$AUTH_URL")
	BODY=$(cat "$BODYF")
}

# Extract the LtpaToken2 value from the saved response headers.
cookie_token() {
	grep -i '^set-cookie:[[:space:]]*LtpaToken2=' "$HDRS" \
		| head -1 | sed -e 's/.*LtpaToken2=//' -e 's/;.*//' | tr -d '\r\n'
}

echo ""
echo "========================================"
echo " mvsMF Authentication API - curl test suite"
echo " Host: ${MVSMF_HOST}:${MVSMF_PORT}"
echo " User: ${MVSMF_USER}"
echo "========================================"

# =========================================================================
# 1. Login with valid credentials -> 200 + LtpaToken2 cookie + body
# =========================================================================
echo ""
echo "--- login (valid credentials) ---"
login "$AUTH"
assert_http_status "200" "$CODE" "login returns 200"
assert_json_field  "$BODY" '.returnCode' "0" "login: returnCode 0"
assert_json_field  "$BODY" '.reasonCode' "0" "login: reasonCode 0"
assert_json_field  "$BODY" '.message'    "Success." "login: message Success."

TOKEN=$(cookie_token)
if [ -n "$TOKEN" ]; then pass "login: Set-Cookie LtpaToken2 present (${#TOKEN} chars)"
else fail "login: Set-Cookie LtpaToken2 present" "no LtpaToken2 in response headers"; fi

# Path=/ so the cookie is sent across the whole /zosmf API
if grep -iq '^set-cookie:.*LtpaToken2=.*[Pp]ath=/' "$HDRS"; then
	pass "login: cookie has Path=/"
else fail "login: cookie has Path=/" "missing Path=/"; fi

# =========================================================================
# 2. Replay the token on a gated endpoint (no Basic auth) -> not 401
# =========================================================================
echo ""
echo "--- token replay (cookie only) ---"
if [ -n "$TOKEN" ]; then
	CODE=$(curl -s -o /dev/null -w '%{http_code}' \
		-H "Cookie: LtpaToken2=${TOKEN}" "$GATED_URL")
	assert_not_status "401" "$CODE" "gated endpoint accepts the LtpaToken2 cookie"
else
	SKIPPED=$((SKIPPED + 1)); TOTAL=$((TOTAL + 1))
	echo "  SKIP: token replay (no token captured)"
fi

# =========================================================================
# 3. Login with invalid credentials -> 401 (z/OSMF body only if httpd forwards)
# =========================================================================
echo ""
echo "--- login (invalid credentials) ---"
login "NOSUCHUSER:WRONGPW"
assert_http_status "401" "$CODE" "bad login returns 401"
# mvsMF's z/OSMF-shaped body {returnCode:8,reasonCode:1} only appears if httpd
# lets the request reach the CGI. While httpd gates /zosmf/* it answers bad creds
# with its own text/plain 401 (no JSON) -- see httpd#114. Assert the fields only
# when the body is actually mvsMF's JSON.
if [ -n "$(echo "$BODY" | jq -r '.returnCode // empty' 2>/dev/null)" ]; then
	assert_json_field "$BODY" '.returnCode' "8" "bad login: returnCode 8"
	assert_json_field "$BODY" '.reasonCode' "1" "bad login: reasonCode 1"
else
	skip "bad login z/OSMF JSON body -- httpd front-gated the 401 (httpd#114)"
fi

# =========================================================================
# 4. Logout with the token -> 204, no body
# =========================================================================
echo ""
echo "--- logout ---"
if [ -n "$TOKEN" ]; then
	CODE=$(curl -s -o "$BODYF" -w '%{http_code}' -X DELETE \
		-H 'X-CSRF-ZOSMF-HEADER: *' \
		-H "Cookie: LtpaToken2=${TOKEN}" "$AUTH_URL")
	assert_http_status "204" "$CODE" "logout returns 204"
	if [ ! -s "$BODYF" ]; then pass "logout: empty body"
	else fail "logout: empty body" "got: $(cat "$BODYF")"; fi
else
	SKIPPED=$((SKIPPED + 2)); TOTAL=$((TOTAL + 2))
	echo "  SKIP: logout (no token captured)"
fi

# =========================================================================
# 5. Logout without a token -> 401
# =========================================================================
echo ""
echo "--- logout (no token) ---"
# The z/OSMF spec requires a valid token to log out. mvsMF's handler returns 401
# when no credential was resolved, so the result is 401 whether httpd forwards
# the request to the CGI or gates it (rejecting first).
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE \
	-H 'X-CSRF-ZOSMF-HEADER: *' "$AUTH_URL")
assert_http_status "401" "$CODE" "logout without a token is rejected"

# =========================================================================
# 6. The token is rejected after logout
# =========================================================================
echo ""
echo "--- token invalid after logout ---"
if [ -n "$TOKEN" ]; then
	CODE=$(curl -s -o /dev/null -w '%{http_code}' \
		-H "Cookie: LtpaToken2=${TOKEN}" "$GATED_URL")
	assert_http_status "401" "$CODE" "logged-out token is rejected"
else
	skip "post-logout replay (no token captured)"
fi

# =========================================================================
# Summary
# =========================================================================
echo ""
echo "========================================"
echo " Total: ${TOTAL}  Passed: ${PASSED}  Failed: ${FAILED}  Skipped: ${SKIPPED}"
echo "========================================"
[ "$FAILED" -eq 0 ]
