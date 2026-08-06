#!/bin/bash
# =========================================================================
# mvsMF Console services REST API - Zowe CLI test suite
#
# Tests the console "issue command" endpoint (endpoint 1) through Zowe CLI:
#   zowe zos-console issue command "<cmd>"
#
# Prerequisites:
#   - Zowe CLI installed (npm i -g @zowe/cli) and a profile/config that
#     points at the mvsMF host (or tests/.config/zowe.config.json).
#   - jq must be installed.
#
# Usage:
#   ./tests/zowe-console.sh
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

MVS_USER="${MVSMF_USER:-}"
if [ -z "$MVS_USER" ]; then
	echo "ERROR: MVSMF_USER is not set in ${ENV_FILE}."
	echo "  Without it every data set name is built from an empty prefix and the"
	echo "  suite silently works on the wrong HLQ. Refusing to run. See issue #204."
	exit 1
fi

# Every connection option goes on every invocation. A Zowe base profile is
# merged into each command and overrides host and credentials silently --
# passing --user/--password alone is not enough, the request still goes to
# the base profile's host and comes back 401. See issue #204.
ZOWE_CONN=(--host "$MVSMF_HOST" --port "$MVSMF_PORT"
	--protocol "${MVSMF_PROTOCOL:-http}"
	--user "$MVS_USER" --password "$MVSMF_PASS"
	--reject-unauthorized false)


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
	OUTPUT=$(zowe "$@" --rfj "${ZOWE_CONN[@]}" 2>&1 </dev/null) || RC=$?
}

assert_rc() {
	if [ "$2" = "$1" ]; then pass "$3 (rc=$2)"
	else fail "$3" "expected rc $1, got $2: $(echo "${OUTPUT:-}" | head -3)"; fi
}

assert_json_field() {
	local actual
	actual=$(echo "$1" | jq -r "$2" 2>/dev/null) || actual=""
	if [ "$actual" = "$3" ]; then pass "$4 ($2=$actual)"
	else fail "$4" "$2: expected '$3', got '$actual'"; fi
}

assert_contains() {
	local actual
	actual=$(echo "$1" | jq -r "$2" 2>/dev/null) || actual=""
	case "$actual" in
		*"$3"*) pass "$4 ($2 contains '$3')" ;;
		*)      fail "$4" "$2 does not contain '$3'" ;;
	esac
}

if ! command -v zowe >/dev/null 2>&1; then
	echo "ERROR: zowe CLI not found (npm i -g @zowe/cli)"
	exit 1
fi

echo ""
echo "========================================"
echo " mvsMF Console API - Zowe CLI test suite"
echo "========================================"

# =========================================================================
# 1. Issue D T (single-line)
# =========================================================================
echo ""
echo "--- issue: D T ---"
run_zowe_json zos-console issue command "D T"
assert_rc 0 "$RC" "issue D T"
assert_json_field "$OUTPUT" '.success' "true" "D T: success"
assert_contains   "$OUTPUT" '.data.commandResponse' "IEE136I" "D T: response has IEE136I"

# =========================================================================
# 2. Issue D A,L (multi-line MLWTO)
# =========================================================================
echo ""
echo "--- issue: D A,L ---"
run_zowe_json zos-console issue command "D A,L"
assert_rc 0 "$RC" "issue D A,L"
assert_contains "$OUTPUT" '.data.commandResponse' "IEE102I" "D A,L: response has IEE102I"

# =========================================================================
# 3. Solicited keyword detection
# =========================================================================
echo ""
echo "--- sol-key ---"
run_zowe_json zos-console issue command "D T" --solicited-keyword "DATE"
assert_rc 0 "$RC" "issue D T with sol-key"
assert_json_field "$OUTPUT" '.data.keywordDetected' "true" "sol-key DATE detected"

# =========================================================================
# 4. Collect terminates (issue -> key -> collect sync-responses)
# =========================================================================
echo ""
echo "--- collect ---"
run_zowe_json zos-console issue command "D T"
KEY=$(echo "$OUTPUT" | jq -r '.data.lastResponseKey' 2>/dev/null)
if [ -n "$KEY" ] && [ "$KEY" != "null" ]; then
	# this drives the collect poll loop; a broken cursor would never empty
	# and hang here, so reaching rc 0 proves the loop terminates
	run_zowe_json zos-console collect sync-responses "$KEY"
	assert_rc 0 "$RC" "collect sync-responses terminates"
	assert_json_field "$OUTPUT" '.success' "true" "collect: success"
else
	fail "issue returned no lastResponseKey"
fi

# =========================================================================
# Summary
# =========================================================================
echo ""
echo "========================================"
echo " Total: ${TOTAL}  Passed: ${PASSED}  Failed: ${FAILED}  Skipped: ${SKIPPED}"
echo "========================================"
[ "$FAILED" -eq 0 ]
