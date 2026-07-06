#!/bin/bash
# =========================================================================
# mvsMF Authentication service REST API - Zowe CLI test suite
#
# Tests the z/OSMF Authentication service through Zowe CLI:
#   zowe auth login  zosmf --show-token   (POST   /zosmf/services/authenticate)
#   zowe auth logout zosmf                (DELETE /zosmf/services/authenticate)
#
# Covers: login (obtain an LtpaToken2), token replay on a files command,
# invalid credentials, and logout.
#
# `--show-token` prints the token WITHOUT storing it in the Zowe config, so
# this suite does not disturb the user's profiles.
#
# Prerequisites:
#   - Zowe CLI installed (npm i -g @zowe/cli) and jq.
#   - Copy .env.example to .env at the repo root and fill in (host/port/user/pass).
#
# Usage:
#   ./tests/zowe-auth.sh
# =========================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

if ! command -v zowe >/dev/null 2>&1; then
	echo "ERROR: zowe CLI not found (npm i -g @zowe/cli)"
	exit 1
fi

if [ ! -f "$ENV_FILE" ]; then
	echo "ERROR: ${ENV_FILE} not found."
	echo "Copy .env.example to .env and fill in your values."
	exit 1
fi

# shellcheck source=../.env
. "$ENV_FILE"

COMMON=(--host "$MVSMF_HOST" --port "$MVSMF_PORT" --reject-unauthorized false)

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

# Run a zowe command with JSON output; sets OUTPUT and RC.
run_zowe_json() {
	RC=0
	OUTPUT=$(zowe "$@" --rfj 2>&1) || RC=$?
}

assert_rc() {
	if [ "$2" = "$1" ]; then pass "$3 (rc=$2)"
	else fail "$3" "expected rc $1, got $2: $(echo "${OUTPUT:-}" | head -3)"; fi
}

assert_rc_nonzero() {
	if [ "$1" != "0" ]; then pass "$2 (rc=$1)"
	else fail "$2" "expected non-zero rc"; fi
}

assert_json_field() {
	local actual
	actual=$(echo "$1" | jq -r "$2" 2>/dev/null) || actual=""
	if [ "$actual" = "$3" ]; then pass "$4 ($2=$actual)"
	else fail "$4" "$2: expected '$3', got '$actual'"; fi
}

echo ""
echo "========================================"
echo " mvsMF Authentication API - Zowe CLI test suite"
echo " Host: ${MVSMF_HOST}:${MVSMF_PORT}"
echo " User: ${MVSMF_USER}"
echo "========================================"

# =========================================================================
# 1. Login with valid credentials -> obtain an LtpaToken2
# =========================================================================
echo ""
echo "--- auth login zosmf (valid credentials) ---"
run_zowe_json auth login zosmf "${COMMON[@]}" \
	--user "$MVSMF_USER" --password "$MVSMF_PASS" --show-token
assert_rc "0" "$RC" "login succeeds"
assert_json_field "$OUTPUT" '.data.tokenType' "LtpaToken2" "login: tokenType LtpaToken2"

TOKEN=$(echo "$OUTPUT" | jq -r '.data.tokenValue' 2>/dev/null)
if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
	pass "login: tokenValue present (${#TOKEN} chars)"
else
	TOKEN=""
	fail "login: tokenValue present" "no tokenValue in output"
fi

# =========================================================================
# 2. Replay the token on a files command -> succeeds (token accepted)
# =========================================================================
echo ""
echo "--- token replay (zos-files list) ---"
if [ -n "$TOKEN" ]; then
	run_zowe_json zos-files list data-set "SYS1.*" "${COMMON[@]}" \
		--token-type LtpaToken2 --token-value "$TOKEN"
	assert_rc "0" "$RC" "files list accepts the LtpaToken2"
else
	SKIPPED=$((SKIPPED + 1)); TOTAL=$((TOTAL + 1))
	echo "  SKIP: token replay (no token captured)"
fi

# =========================================================================
# 3. Login with invalid credentials -> fails
# =========================================================================
echo ""
echo "--- auth login zosmf (invalid credentials) ---"
run_zowe_json auth login zosmf "${COMMON[@]}" \
	--user NOSUCHUSER --password WRONGPW --show-token
assert_rc_nonzero "$RC" "bad login fails"

# =========================================================================
# 4. Logout the token
# =========================================================================
echo ""
echo "--- auth logout zosmf ---"
if [ -n "$TOKEN" ]; then
	run_zowe_json auth logout zosmf "${COMMON[@]}" \
		--token-type LtpaToken2 --token-value "$TOKEN"
	assert_rc "0" "$RC" "logout succeeds"
else
	SKIPPED=$((SKIPPED + 1)); TOTAL=$((TOTAL + 1))
	echo "  SKIP: logout (no token captured)"
fi

# =========================================================================
# Summary
# =========================================================================
echo ""
echo "========================================"
echo " Total: ${TOTAL}  Passed: ${PASSED}  Failed: ${FAILED}  Skipped: ${SKIPPED}"
echo "========================================"
[ "$FAILED" -eq 0 ]
