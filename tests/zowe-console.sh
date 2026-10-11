#!/bin/bash
# =========================================================================
# mvsMF Console services REST API - Zowe CLI test suite
#
# Tests the console "issue command" endpoint (endpoint 1) through Zowe CLI:
#   zowe zos-console issue command "<cmd>"
#
# Prerequisites:
#   - Run through mbt (see Usage), which hands over the target's
#     connection (tests/lib/conn.sh)
#   - Zowe CLI installed (npm i -g @zowe/cli)
#   - jq must be installed.
#
# Usage:
#   mbt run rest-tests -- zowe-console
# =========================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/lib/conn.sh"

MVS_USER="$MVSMF_USER"

# ZOWE_CONN comes from conn.sh: the connection on every call, and the
# session token in the environment rather than a password (#204, #400).


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
# SKIPPED is counted in the summary but had no way to be incremented
skip() { SKIPPED=$((SKIPPED + 1)); TOTAL=$((TOTAL + 1)); echo "  SKIP: $1"; }

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
# 5. --wait-to-collect completes a truncated response (issue #346)
#
# Opt-in: it STOPS then STARTS FTPD (the P/S pair leaves it running), so it
# briefly disrupts the FTP service. Set RUN_FTPD_TESTS=1 to enable.
#
# Zowe does not collect unless asked -- Command.handler.js calls issue() and
# only branches to issueAndCollect() when --wait-to-collect is given. P FTPD's
# reply pauses ~2 s mid-stream, so the plain call returns FTPD098I and the sync
# capture is over before $HASP395 arrives. This asserts the flag reaches the
# terminal line, which is the whole point of the completion path.
#
# On its own this assertion does not discriminate: it would also pass on a stand
# where the sync capture caught the whole block. The discriminator is the curl
# suite's P FTPD block, which measures both halves from a single issue call and
# fails if collect stays silent on a truncated run. Here the flag hides those
# halves behind one command, so testing the delta would mean stopping FTPD
# twice. Read the two blocks together.
# =========================================================================
if [ "${RUN_FTPD_TESTS:-0}" = "1" ]; then
	echo ""
	echo "--- wait-to-collect: P/S FTPD (issue #346) ---"
	run_zowe_json zos-console issue command "P FTPD" --wait-to-collect 5
	assert_rc 0 "$RC" "issue P FTPD --wait-to-collect"
	assert_contains "$OUTPUT" '.data.commandResponse' "FTPD098I" \
		"P FTPD: shutdown line present"
	assert_contains "$OUTPUT" '.data.commandResponse' "HASP395" \
		"P FTPD: terminal line present (arrives after the sync capture)"

	# Restart, so the suite leaves the service as it found it.
	run_zowe_json zos-console issue command "S FTPD" --wait-to-collect 5
	assert_rc 0 "$RC" "issue S FTPD --wait-to-collect (restores the service)"
else
	echo ""
	skip "P/S FTPD wait-to-collect (set RUN_FTPD_TESTS=1 to enable)"
fi

# =========================================================================
# Summary
# =========================================================================
echo ""
echo "========================================"
echo " Total: ${TOTAL}  Passed: ${PASSED}  Failed: ${FAILED}  Skipped: ${SKIPPED}"
echo "========================================"
[ "$FAILED" -eq 0 ]
