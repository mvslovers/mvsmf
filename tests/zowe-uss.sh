#!/bin/bash
# =========================================================================
# mvsMF USS File REST API - Zowe CLI test suite
#
# Tests USS (Unix System Services) file endpoints through Zowe CLI:
#   1. zowe files create uss-directory / uss-file
#   2. zowe files list uss-files
#   3. zowe files upload file-to-uss
#   4. zowe files view uss-file / download uss-file
#   5. zowe files delete uss-file
#
# Prerequisites:
#   - Copy tests/.config/zowe.config.json.example to
#     tests/.config/zowe.config.json and fill in credentials
#   - Zowe CLI must be installed (npm i -g @zowe/cli)
#   - UFSD subsystem must be running on the target MVS system
#
# Usage:
#   ./tests/zowe-uss.sh
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

# PID-based unique test directory to avoid collisions
TEST_BASE="/tmp"
TEST_DIR="${TEST_BASE}/zowe-uss-test-$$"

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

# =========================================================================
# Cleanup helpers
# =========================================================================

cleanup_uss() {
	zowe files delete uss-file "${TEST_DIR}" -r -f >/dev/null 2>&1 || true
}

# =========================================================================
# Tests
# =========================================================================

echo ""
echo "========================================"
echo " mvsMF USS File API - Zowe CLI test suite"
echo " Config: ${CONFIG_FILE}"
echo " Test dir: ${TEST_DIR}"
echo "========================================"

# Clean up leftovers from previous runs
cleanup_uss

# =========================================================================
# 1. Create directory and files
# =========================================================================

echo ""
echo "--- Create USS directory ---"

RC=0
OUTPUT=$(run_zowe files create uss-directory "${TEST_DIR}") || RC=$?
assert_rc 0 "$RC" "create USS directory"

echo ""
echo "--- Create USS file ---"

RC=0
OUTPUT=$(run_zowe files create uss-file "${TEST_DIR}/testfile.txt") || RC=$?
assert_rc 0 "$RC" "create USS file"

echo ""
echo "--- Create nested directory ---"

RC=0
OUTPUT=$(run_zowe files create uss-directory "${TEST_DIR}/subdir") || RC=$?
assert_rc 0 "$RC" "create nested directory"

echo ""
echo "--- Create file in nested directory ---"

RC=0
OUTPUT=$(run_zowe files create uss-file "${TEST_DIR}/subdir/nested.txt") || RC=$?
assert_rc 0 "$RC" "create file in nested directory"

# =========================================================================
# 2. List directory
# =========================================================================

echo ""
echo "--- List USS directory ---"

RC=0
OUTPUT=$(run_zowe_json files list uss-files "${TEST_DIR}") || RC=$?
assert_rc 0 "$RC" "list USS directory"

ITEMS=$(echo "$OUTPUT" | jq -r '.data.apiResponse.items | length' 2>/dev/null) || ITEMS=0
if [ "$ITEMS" -ge 2 ] 2>/dev/null; then
	pass "list returned items ($ITEMS >= 2)"
else
	fail "list returned items" "expected >= 2, got $ITEMS"
fi

# Check that testfile.txt appears in listing
HAS_FILE=$(echo "$OUTPUT" | jq '[.data.apiResponse.items[].name] | index("testfile.txt") != null' 2>/dev/null)
if [ "$HAS_FILE" = "true" ]; then
	pass "list: testfile.txt present"
else
	fail "list: testfile.txt present" "not found in listing"
fi

# Check that subdir appears in listing
HAS_DIR=$(echo "$OUTPUT" | jq '[.data.apiResponse.items[].name] | index("subdir") != null' 2>/dev/null)
if [ "$HAS_DIR" = "true" ]; then
	pass "list: subdir present"
else
	fail "list: subdir present" "not found in listing"
fi

# =========================================================================
# 3. Text round-trip: upload → view → diff
# =========================================================================

echo ""
echo "--- Text round-trip: upload → view ---"

TMPDIR_LOCAL=$(mktemp -d)
UPLOAD_FILE="${TMPDIR_LOCAL}/textfile.txt"
DOWNLOAD_FILE="${TMPDIR_LOCAL}/downloaded.txt"

printf 'Line 1: Hello from Zowe USS test\nLine 2: Round-trip verification\nLine 3: End of test data\n' > "$UPLOAD_FILE"

RC=0
OUTPUT=$(run_zowe files upload ftu "$UPLOAD_FILE" "${TEST_DIR}/textfile.txt") || RC=$?
assert_rc 0 "$RC" "upload text file"

RC=0
OUTPUT=$(run_zowe files view uss-file "${TEST_DIR}/textfile.txt") || RC=$?
assert_rc 0 "$RC" "view text file"

if echo "$OUTPUT" | grep -q "Hello from Zowe USS test"; then
	pass "text round-trip: content matches"
else
	fail "text round-trip: content matches" "expected content not found in output"
fi

echo ""
echo "--- Text round-trip: download → diff ---"

RC=0
OUTPUT=$(run_zowe files download uss-file "${TEST_DIR}/textfile.txt" -f "$DOWNLOAD_FILE") || RC=$?
assert_rc 0 "$RC" "download text file"

if [ -f "$DOWNLOAD_FILE" ]; then
	if diff -q "$UPLOAD_FILE" "$DOWNLOAD_FILE" >/dev/null 2>&1; then
		pass "text round-trip: download matches upload"
	else
		fail "text round-trip: download matches upload" "files differ"
	fi
else
	fail "text round-trip: download file exists" "file not created"
fi

# =========================================================================
# 4. Binary round-trip: upload → download → diff
# =========================================================================

echo ""
echo "--- Binary round-trip: upload → download ---"

BINARY_FILE="${TMPDIR_LOCAL}/binary.dat"
BINARY_DL="${TMPDIR_LOCAL}/binary_dl.dat"

# Create a file with bytes that would be corrupted by text conversion
printf '\x00\x01\x02\x03\x80\x81\xFF' > "$BINARY_FILE"

RC=0
OUTPUT=$(run_zowe files upload ftu "$BINARY_FILE" "${TEST_DIR}/binary.dat" --binary) || RC=$?
assert_rc 0 "$RC" "upload binary file"

RC=0
OUTPUT=$(run_zowe files download uss-file "${TEST_DIR}/binary.dat" -f "$BINARY_DL" -b) || RC=$?
assert_rc 0 "$RC" "download binary file"

if [ -f "$BINARY_DL" ]; then
	if diff -q "$BINARY_FILE" "$BINARY_DL" >/dev/null 2>&1; then
		pass "binary round-trip: download matches upload"
	else
		fail "binary round-trip: download matches upload" "files differ"
	fi
else
	fail "binary round-trip: download file exists" "file not created"
fi

# =========================================================================
# 5. Error cases
# =========================================================================

echo ""
echo "--- Error: list non-existent directory ---"

RC=0
OUTPUT=$(run_zowe files list uss-files "/nonexistent/path/does/not/exist") || RC=$?
if [ "$RC" -ne 0 ]; then
	pass "list non-existent directory fails (rc=$RC)"
else
	fail "list non-existent directory" "expected non-zero rc, got 0"
fi

echo ""
echo "--- Error: view non-existent file ---"

RC=0
OUTPUT=$(run_zowe files view uss-file "/nonexistent/file.txt") || RC=$?
if [ "$RC" -ne 0 ]; then
	pass "view non-existent file fails (rc=$RC)"
else
	fail "view non-existent file" "expected non-zero rc, got 0"
fi

# =========================================================================
# 6. Delete tests
# =========================================================================

echo ""
echo "--- Delete file ---"

RC=0
OUTPUT=$(run_zowe files delete uss-file "${TEST_DIR}/testfile.txt" -f) || RC=$?
assert_rc 0 "$RC" "delete USS file"

echo ""
echo "--- Delete non-existent file ---"

RC=0
OUTPUT=$(run_zowe files delete uss-file "${TEST_DIR}/testfile.txt" -f) || RC=$?
if [ "$RC" -ne 0 ]; then
	pass "delete non-existent file fails (rc=$RC)"
else
	fail "delete non-existent file" "expected non-zero rc, got 0"
fi

echo ""
echo "--- Delete non-empty directory without recursive ---"

RC=0
OUTPUT=$(run_zowe files delete uss-file "${TEST_DIR}" -f) || RC=$?
if [ "$RC" -ne 0 ]; then
	pass "delete non-empty dir without -r fails (rc=$RC)"
else
	fail "delete non-empty dir without -r" "expected non-zero rc, got 0"
fi

echo ""
echo "--- Delete directory recursively ---"

RC=0
OUTPUT=$(run_zowe files delete uss-file "${TEST_DIR}" -r -f) || RC=$?
assert_rc 0 "$RC" "delete directory recursively"

# Verify it's gone
RC=0
OUTPUT=$(run_zowe files list uss-files "${TEST_DIR}") || RC=$?
if [ "$RC" -ne 0 ]; then
	pass "deleted directory is gone (rc=$RC)"
else
	fail "deleted directory is gone" "expected non-zero rc, got 0"
fi

# =========================================================================
# Cleanup
# =========================================================================

rm -rf "$TMPDIR_LOCAL"

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
