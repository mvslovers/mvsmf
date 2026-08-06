#!/bin/bash
# =========================================================================
# mvsMF Datasets REST API - Zowe CLI binary transfer test suite
#
# Tests binary upload/download for sequential datasets and PDS members
# using Zowe CLI --binary flag.
#
# Prerequisites:
#   - Copy tests/.config/zowe.config.json.example to
#     tests/.config/zowe.config.json and fill in credentials
#   - Zowe CLI must be installed (npm i -g @zowe/cli)
#
# Usage:
#   ./tests/zowe-binary.sh
# =========================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/.config"
CONFIG_FILE="${CONFIG_DIR}/zowe.config.json"
BINARY_FILE="${SCRIPT_DIR}/data/binary80.bin"

if [ ! -f "$CONFIG_FILE" ]; then
	echo "ERROR: ${CONFIG_FILE} not found."
	echo "Copy zowe.config.json.example to zowe.config.json and fill in your values."
	exit 1
fi

if [ ! -f "$BINARY_FILE" ]; then
	echo "ERROR: ${BINARY_FILE} not found."
	exit 1
fi

# Tell Zowe to use our local config
export ZOWE_CLI_HOME="$CONFIG_DIR"
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

# Test dataset names
TEST_SEQ="${MVS_USER}.ZOWE.TESTBIN"
TEST_PDS="${MVS_USER}.ZOWE.TESTBPDS"

# Temp file for downloads
DOWNLOAD_FILE=$(mktemp)
trap 'rm -f "$DOWNLOAD_FILE"' EXIT

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
	output=$(zowe "$@" "${ZOWE_CONN[@]}" 2>&1 </dev/null) || rc=$?
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
# Cleanup helper
# =========================================================================

cleanup_datasets() {
	run_zowe files delete ds "$TEST_SEQ" -f >/dev/null 2>&1 || true
	run_zowe files delete ds "$TEST_PDS" -f >/dev/null 2>&1 || true
}

# =========================================================================
# Tests
# =========================================================================

echo ""
echo "========================================"
echo " mvsMF Datasets API - Zowe CLI binary tests"
echo " Config: ${CONFIG_FILE}"
echo " User: ${MVS_USER}"
echo "========================================"

# Clean up leftovers
cleanup_datasets

# -----------------------------------------------------------------
# Sequential dataset: binary round-trip
# -----------------------------------------------------------------

echo ""
echo "--- Create Sequential Dataset (FB80) ---"

RC=0
OUTPUT=$(run_zowe files create ps "$TEST_SEQ" --recfm FB --lrecl 80 --blksize 3120 --size 1TRK) || RC=$?
assert_rc 0 "$RC" "create sequential dataset"

echo ""
echo "--- Upload Binary to Sequential Dataset ---"

RC=0
OUTPUT=$(run_zowe files upload ftds "$BINARY_FILE" "$TEST_SEQ" --binary) || RC=$?
assert_rc 0 "$RC" "upload binary to sequential dataset"

echo ""
echo "--- Download Binary from Sequential Dataset ---"

rm -f "$DOWNLOAD_FILE"
RC=0
OUTPUT=$(run_zowe files download ds "$TEST_SEQ" -f "$DOWNLOAD_FILE" --binary) || RC=$?
assert_rc 0 "$RC" "download binary from sequential dataset"

echo ""
echo "--- Compare Sequential Binary (byte-exact) ---"

if cmp -s "$BINARY_FILE" "$DOWNLOAD_FILE"; then
	pass "sequential binary round-trip matches"
else
	ORIG_SIZE=$(wc -c < "$BINARY_FILE" | tr -d ' ')
	DL_SIZE=$(wc -c < "$DOWNLOAD_FILE" | tr -d ' ')
	DIFF_OFFSET=$(cmp "$BINARY_FILE" "$DOWNLOAD_FILE" 2>&1 || true)
	fail "sequential binary round-trip matches" "sizes: orig=${ORIG_SIZE} dl=${DL_SIZE}; ${DIFF_OFFSET}"
fi

echo ""
echo "--- Delete Sequential Dataset ---"

RC=0
OUTPUT=$(run_zowe files delete ds "$TEST_SEQ" -f) || RC=$?
assert_rc 0 "$RC" "delete sequential dataset"

# -----------------------------------------------------------------
# PDS member: binary round-trip
# -----------------------------------------------------------------

echo ""
echo "--- Create PDS (FB80) ---"

RC=0
OUTPUT=$(run_zowe files create pds "$TEST_PDS" --recfm FB --lrecl 80 --blksize 3120 --size 1TRK --dirblks 5) || RC=$?
assert_rc 0 "$RC" "create PDS"

echo ""
echo "--- Upload Binary to PDS Member ---"

RC=0
OUTPUT=$(run_zowe files upload ftds "$BINARY_FILE" "${TEST_PDS}(BINMBR)" --binary) || RC=$?
assert_rc 0 "$RC" "upload binary to PDS member"

echo ""
echo "--- Download Binary from PDS Member ---"

rm -f "$DOWNLOAD_FILE"
RC=0
OUTPUT=$(run_zowe files download ds "${TEST_PDS}(BINMBR)" -f "$DOWNLOAD_FILE" --binary) || RC=$?
assert_rc 0 "$RC" "download binary from PDS member"

echo ""
echo "--- Compare PDS Member Binary (byte-exact) ---"

if cmp -s "$BINARY_FILE" "$DOWNLOAD_FILE"; then
	pass "PDS member binary round-trip matches"
else
	ORIG_SIZE=$(wc -c < "$BINARY_FILE" | tr -d ' ')
	DL_SIZE=$(wc -c < "$DOWNLOAD_FILE" | tr -d ' ')
	DIFF_OFFSET=$(cmp "$BINARY_FILE" "$DOWNLOAD_FILE" 2>&1 || true)
	fail "PDS member binary round-trip matches" "sizes: orig=${ORIG_SIZE} dl=${DL_SIZE}; ${DIFF_OFFSET}"
fi

# -----------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------

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
