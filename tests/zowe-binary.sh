#!/bin/bash
# =========================================================================
# mvsMF Datasets REST API - Zowe CLI binary transfer test suite
#
# Tests binary upload/download for sequential datasets and PDS members
# using Zowe CLI --binary flag.
#
# Prerequisites:
#   - Run through mbt (see Usage), which hands over the target's
#     connection (tests/lib/conn.sh)
#   - Zowe CLI must be installed (npm i -g @zowe/cli)
#
# Usage:
#   mbt run rest-tests -- zowe-binary
# =========================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY_FILE="${SCRIPT_DIR}/data/binary80.bin"


if [ ! -f "$BINARY_FILE" ]; then
	echo "ERROR: ${BINARY_FILE} not found."
	exit 1
fi

. "${SCRIPT_DIR}/lib/conn.sh"

MVS_USER="$MVSMF_USER"

# ZOWE_CONN comes from conn.sh: the connection on every call, and the
# session token in the environment rather than a password (#204, #400).

# Test dataset names
TEST_SEQ="${MVS_USER}.ZOWE.TESTBIN"
TEST_PDS="${MVS_USER}.ZOWE.TESTBPDS"
TEST_VSEQ="${MVS_USER}.ZOWE.TESTBVB"
TEST_VPDS="${MVS_USER}.ZOWE.TESTBVBP"

# Temp file for downloads
DOWNLOAD_FILE=$(mktemp)
mvsmf_on_exit 'rm -f "$DOWNLOAD_FILE"'

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
	run_zowe files delete ds "$TEST_VSEQ" -f >/dev/null 2>&1 || true
	run_zowe files delete ds "$TEST_VPDS" -f >/dev/null 2>&1 || true
}

# A record-mode download of a RECFM=V data set must fail and write no data
# (issue #455). $1 = what is downloaded, $2 = label.
assert_record_refused() {
	local what="$1" label="$2"
	local rc=0 out
	rm -f "$DOWNLOAD_FILE"
	out=$(run_zowe files download ds "$what" -f "$DOWNLOAD_FILE" --record) || rc=$?
	if [ "$rc" -ne 0 ]; then
		pass "$label: record download fails (rc=$rc)"
	else
		fail "$label: record download fails" "rc=0"
	fi
	if echo "$out" | grep -q "RECFM=V"; then
		pass "$label: the message says record mode is not supported for RECFM=V"
	else
		fail "$label: the message says record mode is not supported for RECFM=V" "output: $(echo "$out" | head -c 300)"
	fi
	# ... and what to use instead (issue #524)
	if echo "$out" | grep -q "binary" && echo "$out" | grep -q "text"; then
		pass "$label: the message says to use binary or text"
	else
		fail "$label: the message says to use binary or text" "output: $(echo "$out" | head -c 300)"
	fi
	if [ -s "$DOWNLOAD_FILE" ]; then
		fail "$label: no data is written" "$(wc -c < "$DOWNLOAD_FILE" | tr -d ' ') bytes in the output file"
	else
		pass "$label: no data is written"
	fi
}

# =========================================================================
# Tests
# =========================================================================

echo ""
echo "========================================"
echo " mvsMF Datasets API - Zowe CLI binary tests"
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
# Record mode: RECFM=FB works, RECFM=V is refused (issue #455)
# -----------------------------------------------------------------

echo ""
echo "--- Record Download from PDS Member, RECFM=FB (issue #455 control) ---"

rm -f "$DOWNLOAD_FILE"
RC=0
OUTPUT=$(run_zowe files download ds "${TEST_PDS}(BINMBR)" -f "$DOWNLOAD_FILE" --record) || RC=$?
assert_rc 0 "$RC" "record download of an FB member"

echo ""
echo "--- Record Download, RECFM=VB (issue #455) ---"

VB_FILE=$(mktemp)
mvsmf_on_exit 'rm -f "$VB_FILE"'
printf 'VBRECORD ONE\nVBRECORD TWO IS LONGER\nVBRECORD 3\n' > "$VB_FILE"

RC=0
OUTPUT=$(run_zowe files create ps "$TEST_VSEQ" --recfm VB --lrecl 84 --blksize 3120 --size 1TRK) || RC=$?
assert_rc 0 "$RC" "create VB sequential dataset"

RC=0
OUTPUT=$(run_zowe files upload ftds "$VB_FILE" "$TEST_VSEQ") || RC=$?
assert_rc 0 "$RC" "upload three lines of unequal length to the VB dataset"

assert_record_refused "$TEST_VSEQ" "VB sequential dataset"

RC=0
OUTPUT=$(run_zowe files create pds "$TEST_VPDS" --recfm VB --lrecl 84 --blksize 3120 --size 1TRK --dirblks 5) || RC=$?
assert_rc 0 "$RC" "create VB PDS"

RC=0
OUTPUT=$(run_zowe files upload ftds "$VB_FILE" "${TEST_VPDS}(VBMBR)") || RC=$?
assert_rc 0 "$RC" "upload three lines of unequal length to the VB member"

assert_record_refused "${TEST_VPDS}(VBMBR)" "VB member"

# -----------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------

echo ""
echo "--- Cleanup ---"

RC=0
OUTPUT=$(run_zowe files delete ds "$TEST_PDS" -f) || RC=$?
assert_rc 0 "$RC" "cleanup: delete PDS"

RC=0
OUTPUT=$(run_zowe files delete ds "$TEST_VPDS" -f) || RC=$?
assert_rc 0 "$RC" "cleanup: delete VB PDS"

RC=0
OUTPUT=$(run_zowe files delete ds "$TEST_VSEQ" -f) || RC=$?
assert_rc 0 "$RC" "cleanup: delete VB sequential dataset"

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
