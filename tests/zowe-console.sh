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
# Summary
# =========================================================================
echo ""
echo "========================================"
echo " Total: ${TOTAL}  Passed: ${PASSED}  Failed: ${FAILED}  Skipped: ${SKIPPED}"
echo "========================================"
[ "$FAILED" -eq 0 ]
