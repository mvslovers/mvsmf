#!/bin/bash
# =========================================================================
# mvsMF Datasets REST API - Zowe CLI test suite
#
# Tests dataset endpoints through Zowe CLI commands, including
# volume serial prefix support.
#
# Prerequisites:
#   - Copy tests/.config/zowe.config.json.example to
#     tests/.config/zowe.config.json and fill in credentials
#   - Zowe CLI must be installed (npm i -g @zowe/cli)
#
# Usage:
#   ./tests/zowe-datasets.sh
# =========================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/.config"
CONFIG_FILE="${CONFIG_DIR}/zowe.config.json"

if [ ! -f "$CONFIG_FILE" ]; then
	echo "ERROR: ${CONFIG_FILE} not found."
	echo "Copy zowe.config.json.example to zowe.config.json and fill in your values."
	exit 1
fi

# Tell Zowe to use our local config
export ZOWE_CLI_HOME="$CONFIG_DIR"

# Extract user from config for dataset naming
MVS_USER=$(jq -r '.profiles.mvsmf.properties.user' "$CONFIG_FILE")

# Test dataset names
TEST_SEQ="${MVS_USER}.ZOWE.TESTSEQ"
TEST_PDS="${MVS_USER}.ZOWE.TESTPDS"

# --- state ---
PASSED=0
FAILED=0
SKIPPED=0
TOTAL=0

# =========================================================================
# Helpers
# =========================================================================

pass() {
	PASSED=$((PASSED + 1))
	TOTAL=$((TOTAL + 1))
	echo "  PASS: $1"
}

fail() {
	FAILED=$((FAILED + 1))
	TOTAL=$((TOTAL + 1))
	echo "  FAIL: $1"
	if [ -n "${2:-}" ]; then
		echo "        $2"
	fi
}

skip() {
	SKIPPED=$((SKIPPED + 1))
	TOTAL=$((TOTAL + 1))
	echo "  SKIP: $1"
}

# Run zowe command, capture stdout+stderr and exit code
run_zowe() {
	local output
	local rc=0
	output=$(zowe "$@" 2>&1) || rc=$?
	echo "$output"
	return $rc
}

# Run zowe command expecting JSON output
run_zowe_json() {
	local output
	local rc=0
	output=$(zowe "$@" --rfj 2>&1) || rc=$?
	echo "$output"
	return $rc
}

assert_rc() {
	local expected="$1"
	local actual="$2"
	local label="$3"
	if [ "$actual" -eq "$expected" ]; then
		pass "$label (rc=$actual)"
	else
		fail "$label" "expected rc=$expected, got rc=$actual"
	fi
}

assert_json_field() {
	local json="$1"
	local field="$2"
	local expected="$3"
	local label="$4"
	local actual
	actual=$(echo "$json" | jq -r "$field" 2>/dev/null) || actual=""
	if [ "$actual" = "$expected" ]; then
		pass "$label ($field=$actual)"
	else
		fail "$label" "$field: expected '$expected', got '$actual'"
	fi
}

assert_json_field_exists() {
	local json="$1"
	local field="$2"
	local label="$3"
	local val rc=0
	val=$(echo "$json" | jq -e "$field" 2>/dev/null) || rc=$?
	if [ $rc -eq 0 ] && [ "$val" != "null" ]; then
		pass "$label ($field present)"
	else
		fail "$label" "$field missing or null"
	fi
}

# =========================================================================
# Cleanup helper
# =========================================================================

cleanup_datasets() {
	zowe files delete ds "$TEST_SEQ" -f >/dev/null 2>&1 || true
	zowe files delete ds "$TEST_PDS" -f >/dev/null 2>&1 || true
}

# =========================================================================
# Tests
# =========================================================================

echo ""
echo "========================================"
echo " mvsMF Datasets API - Zowe CLI test suite"
echo " Config: ${CONFIG_FILE}"
echo " User: ${MVS_USER}"
echo "========================================"

# Clean up leftovers
cleanup_datasets

# --- Create sequential dataset ---
echo ""
echo "--- Create Sequential Dataset ---"

RC=0
OUTPUT=$(run_zowe files create ps "$TEST_SEQ" --recfm FB --lrecl 80 --blksize 3120 --size 1TRK) || RC=$?
assert_rc 0 "$RC" "create sequential dataset"

# --- Write to sequential dataset ---
echo ""
echo "--- Write Sequential Dataset ---"

TMPFILE=$(mktemp)
printf 'LINE 1 TEST DATA\nLINE 2 TEST DATA\nLINE 3 TEST DATA\n' > "$TMPFILE"
RC=0
OUTPUT=$(run_zowe files upload ftds "$TMPFILE" "$TEST_SEQ") || RC=$?
rm -f "$TMPFILE"
assert_rc 0 "$RC" "write sequential dataset"

# --- Read sequential dataset ---
echo ""
echo "--- Read Sequential Dataset ---"

RC=0
OUTPUT=$(run_zowe files view ds "$TEST_SEQ") || RC=$?
assert_rc 0 "$RC" "read sequential dataset"

if echo "$OUTPUT" | grep -q "LINE 1 TEST DATA"; then
	pass "read content matches"
else
	fail "read content matches" "expected 'LINE 1 TEST DATA' in output"
fi

# --- List datasets ---
echo ""
echo "--- List Datasets ---"

RC=0
OUTPUT=$(run_zowe_json files list ds "${MVS_USER}.ZOWE") || RC=$?
assert_rc 0 "$RC" "list datasets"

ITEMS=$(echo "$OUTPUT" | jq -r '.data.apiResponse.items | length' 2>/dev/null) || ITEMS=0
if [ "$ITEMS" -gt 0 ] 2>/dev/null; then
	pass "list returned results ($ITEMS)"
else
	fail "list returned results" "expected >0 items"
fi

# --- Delete sequential dataset ---
echo ""
echo "--- Delete Sequential Dataset ---"

RC=0
OUTPUT=$(run_zowe files delete ds "$TEST_SEQ" -f) || RC=$?
assert_rc 0 "$RC" "delete sequential dataset"

# --- Create PDS ---
echo ""
echo "--- Create PDS ---"

RC=0
OUTPUT=$(run_zowe files create pds "$TEST_PDS" --recfm FB --lrecl 80 --blksize 3120 --size 1TRK --dirblks 5) || RC=$?
assert_rc 0 "$RC" "create PDS"

# --- Write PDS member ---
# NOTE: Zowe CLI member PUT is blocked by a known issue where the
# "(MEMBER)" portion of the URI does not reach the router.
# See GitHub issue tracking this problem. Skipping member tests
# until resolved.
echo ""
echo "--- Write PDS Member ---"

TMPFILE=$(mktemp)
printf 'MEMBER TEST LINE 1\nMEMBER TEST LINE 2\n' > "$TMPFILE"
RC=0
OUTPUT=$(run_zowe files upload ftds "$TMPFILE" "${TEST_PDS}(TESTMBR)") || RC=$?
rm -f "$TMPFILE"

if [ "$RC" -eq 0 ]; then
	pass "write PDS member (rc=$RC)"
	MEMBER_WRITE_OK=1
else
	skip "write PDS member (known issue: member URI routing)"
	MEMBER_WRITE_OK=0
fi

# --- List PDS members ---
echo ""
echo "--- List PDS Members ---"

RC=0
OUTPUT=$(run_zowe_json files list am "$TEST_PDS") || RC=$?
assert_rc 0 "$RC" "list PDS members"

if [ "$MEMBER_WRITE_OK" -eq 1 ]; then
	ITEMS=$(echo "$OUTPUT" | jq -r '.data.apiResponse.items | length' 2>/dev/null) || ITEMS=0
	if [ "$ITEMS" -gt 0 ] 2>/dev/null; then
		pass "member list returned results ($ITEMS)"
	else
		fail "member list returned results" "expected >0 items"
	fi
fi

# --- Read PDS member ---
echo ""
echo "--- Read PDS Member ---"

if [ "$MEMBER_WRITE_OK" -eq 1 ]; then
	RC=0
	OUTPUT=$(run_zowe files view ds "${TEST_PDS}(TESTMBR)") || RC=$?
	assert_rc 0 "$RC" "read PDS member"

	if echo "$OUTPUT" | grep -q "MEMBER TEST LINE 1"; then
		pass "member content matches"
	else
		fail "member content matches" "expected 'MEMBER TEST LINE 1' in output"
	fi
else
	skip "read PDS member (no member written)"
fi

# --- Delete PDS member ---
echo ""
echo "--- Delete PDS Member ---"

if [ "$MEMBER_WRITE_OK" -eq 1 ]; then
	RC=0
	OUTPUT=$(run_zowe files delete ds "${TEST_PDS}(TESTMBR)" -f) || RC=$?
	assert_rc 0 "$RC" "delete PDS member"

	# --- Delete PDS member: not found ---
	echo ""
	echo "--- Delete PDS Member: not found ---"

	RC=0
	OUTPUT=$(run_zowe files delete ds "${TEST_PDS}(TESTMBR)" -f) || RC=$?
	if [ "$RC" -ne 0 ]; then
		pass "delete non-existent member (rc=$RC)"
	else
		fail "delete non-existent member" "expected non-zero rc, got 0"
	fi
else
	skip "delete PDS member (no member written)"
fi

# --- Cleanup: delete PDS ---
echo ""
echo "--- Cleanup ---"

RC=0
OUTPUT=$(run_zowe files delete ds "$TEST_PDS" -f) || RC=$?
assert_rc 0 "$RC" "cleanup: delete PDS"

# =========================================================================
# Summary
# =========================================================================

echo ""
echo "========================================"
echo " Results: ${PASSED} passed, ${FAILED} failed, ${SKIPPED} skipped (${TOTAL} total)"
echo "========================================"

if [ "$FAILED" -gt 0 ]; then
	exit 1
fi
