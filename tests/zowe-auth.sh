#!/bin/bash
# =========================================================================
# mvsMF Authentication service REST API - Zowe SDK test suite
#
# Mirrors tests/curl-auth.sh case for case, but through a real Zowe client
# stack: POST /zosmf/services/authenticate to obtain an LtpaToken2, replay it
# on a files request, log out, and confirm the token dies with the session.
#
# It does NOT use `zowe auth login zosmf`, because that command does not exist.
# Zowe CLI v8 offers only `auth login apiml`, and the SDK only apimlLogin /
# apimlLogout -- so every argument the old suite passed came back "Unknown
# argument", the `zosmf` subcommand included, and three of six assertions
# failed with nothing wrong on the server (#206). The driver in
# tests/zowe-auth-flow.js uses ZosmfRestClient and Session directly, which is
# what the CLI itself runs on.
#
# Prerequisites:
#   - Zowe CLI installed (npm i -g @zowe/cli) for its SDK packages, node, jq.
#   - Copy .env.example to .env at the repo root and fill in (host/port/user/pass).
#
# Usage:
#   ./tests/zowe-auth.sh
# =========================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
FLOW="${SCRIPT_DIR}/zowe-auth-flow.js"

if [ ! -f "$ENV_FILE" ]; then
	echo "ERROR: ${ENV_FILE} not found."
	echo "Copy .env.example to .env and fill in your values."
	exit 1
fi

# shellcheck source=../.env
. "$ENV_FILE"

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

# A missing node or an unresolvable SDK is a client capability the suite cannot
# supply, so it is a skip. Anything the driver reports back is an assertion.
require_driver() {
	if ! command -v node >/dev/null 2>&1; then
		echo "  (node not found — the SDK driver cannot run)"
		return 1
	fi
	if ! command -v zowe >/dev/null 2>&1 && [ -z "${ZOWE_CLI_DIR:-}" ]; then
		echo "  (zowe CLI not installed — its SDK packages are what the driver loads)"
		return 1
	fi
	return 0
}

assert_eq() {
	local expected="$1" actual="$2" label="$3"
	if [ "$actual" = "$expected" ]; then pass "$label ($actual)"
	else fail "$label" "expected '$expected', got '$actual'"; fi
}

echo ""
echo "========================================"
echo " mvsMF Authentication API - Zowe SDK test suite"
echo " Host: ${MVSMF_HOST}:${MVSMF_PORT}"
echo " User: ${MVSMF_USER}"
echo "========================================"

if ! require_driver; then
	echo ""
	for c in "login (valid credentials)" "login: LtpaToken2 cookie" \
	         "login: token value present" "login: cookie is scoped Path=/" \
	         "login (invalid credentials)" "token replay on a files request" \
	         "logout" "token invalid after logout" "logout without a valid token"; do
		skip "$c (no node or Zowe SDK available)"
	done
	echo ""
	echo "========================================"
	echo " Total: ${TOTAL}  Passed: ${PASSED}  Failed: ${FAILED}  Skipped: ${SKIPPED}"
	echo "========================================"
	exit 0
fi

OUT=$(MVSMF_HOST="$MVSMF_HOST" MVSMF_PORT="$MVSMF_PORT" \
      MVSMF_PROTOCOL="${MVSMF_PROTOCOL:-http}" \
      MVSMF_USER="$MVSMF_USER" MVSMF_PASS="$MVSMF_PASS" \
      node "$FLOW" 2>&1) || true

get() { echo "$OUT" | sed -n "s/^$1=//p" | head -1; }

if [ -n "$(get error)" ] || [ -z "$(get login_status)" ]; then
	echo ""
	fail "authentication flow driver" "$(echo "$OUT" | head -3)"
	echo ""
	echo "========================================"
	echo " Total: ${TOTAL}  Passed: ${PASSED}  Failed: ${FAILED}  Skipped: ${SKIPPED}"
	echo "========================================"
	exit 1
fi

# =========================================================================
# 1. Login with valid credentials -> 200 and an LtpaToken2 cookie
# =========================================================================
echo ""
echo "--- login (valid credentials) ---"
assert_eq "200" "$(get login_status)" "login succeeds"
assert_eq "LtpaToken2" "$(get login_token_type)" "login: tokenType LtpaToken2"
if [ "$(get login_token_len)" -gt 0 ] 2>/dev/null; then
	pass "login: tokenValue present ($(get login_token_len) chars)"
else
	fail "login: tokenValue present" "empty token"
fi
# Path=/ scopes the cookie to the whole /zosmf API -- a narrower path would
# silently break every request outside /zosmf/services.
assert_eq "/" "$(get login_cookie_path)" "login: cookie is scoped Path=/"

# =========================================================================
# 2. Login with invalid credentials -> 401
# =========================================================================
echo ""
echo "--- login (invalid credentials) ---"
assert_eq "401" "$(get bad_login_status)" "bad password is rejected"

# =========================================================================
# 3. Replay the token on a files request -> accepted, no credentials sent
# =========================================================================
echo ""
echo "--- token replay (files list) ---"
assert_eq "200" "$(get replay_status)" "files list accepts the LtpaToken2"

# =========================================================================
# 4. Logout, and the token dies with it
# =========================================================================
echo ""
echo "--- logout ---"
assert_eq "204" "$(get logout_status)" "logout succeeds"
assert_eq "401" "$(get replay_after_logout_status)" "logged-out token is rejected"
assert_eq "401" "$(get logout_bogus_status)" "logout without a valid token is rejected"

# =========================================================================
# Summary
# =========================================================================
echo ""
echo "========================================"
echo " Total: ${TOTAL}  Passed: ${PASSED}  Failed: ${FAILED}  Skipped: ${SKIPPED}"
echo "========================================"
[ "$FAILED" -eq 0 ]
