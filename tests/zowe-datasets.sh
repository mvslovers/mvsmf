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
TEST_SEQ="${MVS_USER}.ZOWE.TESTSEQ"
TEST_SEQ2="${MVS_USER}.ZOWE.TESTSEQ2"
TEST_PDS="${MVS_USER}.ZOWE.TESTPDS"
# Large-LRECL fixture for issue #198 (records above the old 1024-byte limit)
TEST_BIG="${MVS_USER}.ZOWE.TESTBIG"
# Text framing fixture for issue #233 (blank lines, full-width records)
TEST_FRAME="${MVS_USER}.ZOWE.TESTFRM"

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

# Run zowe command expecting JSON output
run_zowe_json() {
	local output
	local rc=0
	output=$(zowe "$@" --rfj "${ZOWE_CONN[@]}" 2>&1 </dev/null) || rc=$?
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

assert_json_field_absent() {
	local json="$1"
	local expr="$2"
	local label="$3"
	local present
	# the expression is a has() test, not a value read: jq -r on an absent key
	# and on a literal null both print "null", so reading the value cannot tell
	# "omitted" from "present and null" -- and only the first is what z/OSMF does
	present=$(echo "$json" | jq -r "$expr" 2>/dev/null) || present="?"
	if [ "$present" = "false" ]; then
		pass "$label (key absent)"
	else
		fail "$label" "expected the key to be absent, got present=$present"
	fi
}

# =========================================================================
# Cleanup helper
# =========================================================================

cleanup_datasets() {
	run_zowe files delete ds "$TEST_SEQ" -f >/dev/null 2>&1 || true
	run_zowe files delete ds "$TEST_SEQ2" -f >/dev/null 2>&1 || true
	run_zowe files delete ds "$TEST_PDS" -f >/dev/null 2>&1 || true
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

# --- List datasets (two-level prefix) ---
echo ""
echo "--- List Datasets (two-level prefix) ---"

RC=0
OUTPUT=$(run_zowe_json files list ds "${MVS_USER}.ZOWE") || RC=$?
assert_rc 0 "$RC" "list datasets (two-level prefix)"

ITEMS=$(echo "$OUTPUT" | jq -r '.data.apiResponse.items | length' 2>/dev/null) || ITEMS=0
if [ "$ITEMS" -gt 0 ] 2>/dev/null; then
	pass "list returned results ($ITEMS)"
else
	fail "list returned results" "expected >0 items"
fi

# --- List datasets (exact three-level name) ---
echo ""
echo "--- List Datasets (exact name) ---"

RC=0
OUTPUT=$(run_zowe_json files list ds "${TEST_SEQ}") || RC=$?
assert_rc 0 "$RC" "list datasets (exact name)"

DSN=$(echo "$OUTPUT" | jq -r '.data.apiResponse.items[0].dsname' 2>/dev/null) || DSN=""
if [ "$DSN" = "$TEST_SEQ" ]; then
	pass "exact name returned correct dataset"
else
	fail "exact name returned correct dataset" "expected '$TEST_SEQ', got '$DSN'"
fi

# --- List datasets (wildcard *) ---
echo ""
echo "--- List Datasets (wildcard *) ---"

RC=0
OUTPUT=$(run_zowe_json files list ds "${MVS_USER}.*") || RC=$?
assert_rc 0 "$RC" "list datasets (wildcard *)"

ITEMS=$(echo "$OUTPUT" | jq -r '.data.apiResponse.items | length' 2>/dev/null) || ITEMS=0
if [ "$ITEMS" -gt 0 ] 2>/dev/null; then
	pass "wildcard * returned results ($ITEMS)"
else
	fail "wildcard * returned results" "expected >0 items"
fi

# --- List datasets (wildcard **) ---
echo ""
echo "--- List Datasets (wildcard **) ---"

RC=0
OUTPUT=$(run_zowe_json files list ds "${MVS_USER}.**") || RC=$?
assert_rc 0 "$RC" "list datasets (wildcard **)"

ITEMS=$(echo "$OUTPUT" | jq -r '.data.apiResponse.items | length' 2>/dev/null) || ITEMS=0
if [ "$ITEMS" -gt 0 ] 2>/dev/null; then
	pass "wildcard ** returned results ($ITEMS)"
else
	fail "wildcard ** returned results" "expected >0 items"
fi

# --- Create PDS (needed before max-items test so two datasets exist) ---
echo ""
echo "--- Create PDS ---"

RC=0
OUTPUT=$(run_zowe files create pds "$TEST_PDS" --recfm FB --lrecl 80 --blksize 3120 --size 1TRK --dirblks 5) || RC=$?
assert_rc 0 "$RC" "create PDS"

# --- List datasets (max-items) ---
echo ""
echo "--- List Datasets (max-items) ---"

RC=0
OUTPUT=$(run_zowe_json files list ds "${MVS_USER}.ZOWE" --max 1) || RC=$?
assert_rc 0 "$RC" "list datasets (max-items=1)"

RETURNED=$(echo "$OUTPUT" | jq -r '.data.apiResponse.returnedRows' 2>/dev/null) || RETURNED=0
if [ "$RETURNED" -eq 1 ] 2>/dev/null; then
	pass "max-items limited to 1 row"
else
	fail "max-items limited to 1 row" "expected returnedRows=1, got $RETURNED"
fi

MORE_ROWS=$(echo "$OUTPUT" | jq -r '.data.apiResponse.moreRows' 2>/dev/null) || MORE_ROWS=""
if [ "$MORE_ROWS" = "true" ]; then
	pass "moreRows=true when truncated"
else
	fail "moreRows=true when truncated" "expected true, got $MORE_ROWS"
fi

# --- Rename sequential dataset ---
echo ""
echo "--- Rename Sequential Dataset ---"

RC=0
OUTPUT=$(run_zowe files rename ds "$TEST_SEQ" "$TEST_SEQ2") || RC=$?
assert_rc 0 "$RC" "rename sequential dataset TESTSEQ -> TESTSEQ2"

RC=0
OUTPUT=$(run_zowe_json files list ds "$TEST_SEQ2") || RC=$?
assert_rc 0 "$RC" "list renamed dataset TESTSEQ2"

# rename back so the delete test below operates on TESTSEQ
RC=0
OUTPUT=$(run_zowe files rename ds "$TEST_SEQ2" "$TEST_SEQ") || RC=$?
assert_rc 0 "$RC" "rename sequential dataset TESTSEQ2 -> TESTSEQ (restore)"

# --- Delete sequential dataset ---
echo ""
echo "--- Delete Sequential Dataset ---"

RC=0
OUTPUT=$(run_zowe files delete ds "$TEST_SEQ" -f) || RC=$?
assert_rc 0 "$RC" "delete sequential dataset"

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
	# This was labelled a known issue with no ticket behind it, and the upload
	# has since started working -- so the branch was dead while still able to
	# swallow a regression silently. It is a failure now (#304).
	fail "write PDS member" "upload to ${TEST_PDS}(TESTMBR) failed (rc=$RC)"
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

	# names arrive without the directory's blank padding (#154) -- Zowe hands
	# them straight to the next request, so a padded name asks for a member
	# whose name ends in a blank
	NAMES=$(echo "$OUTPUT" |
		jq -c '[.data.apiResponse.items[].member]' 2>/dev/null)
	if echo "$NAMES" | jq -e 'all(test("^[^ ]+$"))' >/dev/null 2>&1; then
		pass "member names are returned unpadded"
	else
		fail "member names are returned unpadded" "got: $NAMES"
	fi

	# A truncated member list is a 200 carrying moreRows true (#274), and what
	# is asserted here is that the fact survives Zowe's own parsing -- the
	# status says nothing about it, so moreRows is the only thing a client has
	# to go on. The dataset list above covers the same ground for the other
	# handler.
	#
	# A second member has to exist first. With only TESTMBR in the directory
	# max-items=1 is not a truncation at all, the response is a plain 200, and
	# the case would pass without ever reaching the code it is meant to cover.
	#
	# Not TESTMBR2: the rename test below renames TESTMBR to that name and
	# would fail against an existing member. This one is deleted again as soon
	# as the two assertions are done, so the directory the later tests see is
	# the one they expect.
	PAGEFILE=$(mktemp)
	printf 'SECOND MEMBER\n' > "$PAGEFILE"
	run_zowe files upload ftds "$PAGEFILE" "${TEST_PDS}(PAGEMBR)" >/dev/null 2>&1
	rm -f "$PAGEFILE"

	RC=0
	OUTPUT=$(run_zowe_json files list am "$TEST_PDS" --max 1) || RC=$?
	assert_rc 0 "$RC" "list PDS members (max-items=1, truncated)"

	ROWS=$(echo "$OUTPUT" | jq -r '.data.apiResponse.returnedRows' 2>/dev/null) || ROWS=0
	MORE=$(echo "$OUTPUT" | jq -r '.data.apiResponse.moreRows' 2>/dev/null) || MORE=""
	if [ "$ROWS" = "1" ] && [ "$MORE" = "true" ]; then
		pass "member list max-items=1: one row and moreRows=true"
	else
		fail "member list max-items=1: one row and moreRows=true" \
			"returnedRows=$ROWS moreRows=$MORE"
	fi

	# and the negative: a limit the directory does not reach is a complete
	# listing, which carries no moreRows key at all (#279). Zowe has to cope
	# with the field being absent -- it is written against a reference that
	# omits it, and this is where that would show.
	RC=0
	OUTPUT=$(run_zowe_json files list am "$TEST_PDS" --max 100) || RC=$?
	assert_rc 0 "$RC" "list PDS members (max-items=100, complete)"
	assert_json_field_absent "$OUTPUT" '.data.apiResponse | has("moreRows")' \
		"member list max-items=100: no moreRows"

	run_zowe files delete ds "${TEST_PDS}(PAGEMBR)" -f >/dev/null 2>&1
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

# --- Rename PDS member ---
echo ""
echo "--- Rename PDS Member ---"

if [ "$MEMBER_WRITE_OK" -eq 1 ]; then
	RC=0
	OUTPUT=$(run_zowe files rename dsm "$TEST_PDS" TESTMBR TESTMBR2) || RC=$?
	assert_rc 0 "$RC" "rename PDS member TESTMBR -> TESTMBR2"

	RC=0
	OUTPUT=$(run_zowe files view ds "${TEST_PDS}(TESTMBR2)") || RC=$?
	assert_rc 0 "$RC" "read renamed member TESTMBR2"
	if echo "$OUTPUT" | grep -q "MEMBER TEST LINE 1"; then
		pass "renamed member content preserved"
	else
		fail "renamed member content preserved" "expected 'MEMBER TEST LINE 1' in output"
	fi

	# rename back so the delete test below operates on TESTMBR
	RC=0
	OUTPUT=$(run_zowe files rename dsm "$TEST_PDS" TESTMBR2 TESTMBR) || RC=$?
	assert_rc 0 "$RC" "rename PDS member TESTMBR2 -> TESTMBR (restore)"
else
	skip "rename PDS member (no member written)"
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

# --- Long DSN(member) name validation (Issue #133) ---
# DSN <=44 and member <=8 are individually valid even when combined they exceed 44.
# A 36-char DSN + 8-char member (combined 46 chars) was a false 400 before the fix.
echo ""
echo "--- Long DSN(member): individually valid names, combined >44 chars ---"

LONGDSN="IBMUSER.REXX370.V1R0M0D.REF.LINKLIB"  # 36 chars — valid MVS DSN
LONGMBR="IRXTSPRM"                               # 8 chars  — valid MVS member

# GET: validation should pass; 404 is expected since this dataset isn't on the test system
RC=0
OUTPUT=$(run_zowe files download ds "${LONGDSN}(${LONGMBR})" --binary --file /dev/null) || RC=$?
if echo "$OUTPUT" | grep -q "too long"; then
	fail "long DSN(member) GET passes validation" "server still rejects valid name with 'too long' — guard not fixed"
else
	pass "long DSN(member) GET passes validation (rc=$RC, no false 'too long' error)"
fi

# --- Records longer than 1024 bytes (issue #198) ---
# The write path used fixed 1024-byte buffers while bounding the copy by the
# data set's LRECL, so anything above 1024 smashed the stack (S0C1, answered
# as an internal server error). Needs an LRECL well above 1024 to reproduce.
echo ""
echo "--- Large LRECL: write and read back (issue #198) ---"

RC=0
OUTPUT=$(run_zowe files create ps "$TEST_BIG" --recfm VB --lrecl 4004 --blksize 8000 --size 5TRK) || RC=$?
assert_rc 0 "$RC" "create VB dataset with LRECL 4004"

TMPFILE=$(mktemp)
awk 'BEGIN { s = ""; while (length(s) < 4000) s = s "X"; l = substr(s, 1, 4000);
             print l; print l; print l }' > "$TMPFILE"
RC=0
OUTPUT=$(run_zowe files upload ftds "$TMPFILE" "$TEST_BIG") || RC=$?
rm -f "$TMPFILE"
assert_rc 0 "$RC" "upload 4000-byte records (was S0C1)"

RC=0
OUTPUT=$(run_zowe files view ds "$TEST_BIG") || RC=$?
assert_rc 0 "$RC" "read back 4000-byte records"

LONGEST=$(echo "$OUTPUT" | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')
if [ "$LONGEST" = "4000" ]; then
	pass "records survived at full length (longest=$LONGEST)"
else
	fail "records survived at full length" "expected longest line 4000, got $LONGEST"
fi

RC=0
OUTPUT=$(run_zowe files delete ds "$TEST_BIG" -f) || RC=$?
assert_rc 0 "$RC" "cleanup: delete large-LRECL dataset"

# --- Text record framing (issue #233) ---
# A blank line used to be written as a zero-length record, which never reached
# the data set, and the usable line length was LRECL-2 -- 80-column source into
# an FB80 data set came back as "Record too long".
echo ""
echo "--- Text framing: blank lines and full-width records (issue #233) ---"

RC=0
OUTPUT=$(run_zowe files create ps "$TEST_FRAME" --recfm FB --lrecl 80 --blksize 3120 --size 1TRK) || RC=$?
assert_rc 0 "$RC" "create FB80 dataset"

TMPFILE=$(mktemp)
awk 'BEGIN { s = ""; while (length(s) < 80) s = s "A";
             print "ERSTE ZEILE"; print ""; print substr(s, 1, 80) }' > "$TMPFILE"
RC=0
OUTPUT=$(run_zowe files upload ftds "$TMPFILE" "$TEST_FRAME") || RC=$?
rm -f "$TMPFILE"
assert_rc 0 "$RC" "upload a blank line and an 80-column line"

RC=0
OUTPUT=$(run_zowe files view ds "$TEST_FRAME") || RC=$?
assert_rc 0 "$RC" "read back the framed dataset"

LINES=$(echo "$OUTPUT" | wc -l | tr -d ' ')
if [ "$LINES" = "3" ]; then
	pass "three lines in, three lines out ($LINES)"
else
	fail "three lines in, three lines out" "expected 3 lines, got $LINES"
fi

if [ -z "$(echo "$OUTPUT" | sed -n '2p')" ]; then
	pass "the blank line survived"
else
	fail "the blank line survived" "line 2 is not empty"
fi

WIDTH=$(echo "$OUTPUT" | sed -n '3p' | tr -d '\r' | awk '{ print length($0) }')
if [ "$WIDTH" = "80" ]; then
	pass "the 80-column line kept all its columns ($WIDTH)"
else
	fail "the 80-column line kept all its columns" "expected 80, got $WIDTH"
fi

RC=0
OUTPUT=$(run_zowe files delete ds "$TEST_FRAME" -f) || RC=$?
assert_rc 0 "$RC" "cleanup: delete the framing dataset"

# --- ETag / optimistic locking (issue #152) ---
echo ""
echo "--- ETag: optimistic locking (issue #152) ---"

# The z/OSMF SDK carries the ETag through (returnEtag / etag on the upload and
# download options), but the CLI exposes no flag for either: there is no way to
# ask `zowe files download` for an ETag or to hand one to `zowe files upload`.
# So this suite cannot reach the feature at all, and the coverage lives in
# tests/curl-datasets.sh instead. Recorded as a skip rather than left out, so
# the gap stays visible if a later CLI version does expose it.
skip "etag: X-IBM-Return-Etag / If-Match (no Zowe CLI flag — see curl-datasets.sh)"

# The read half (#263) is further out of reach: the SDK has no If-None-Match
# option at all, so a 304 cannot be provoked through the CLI even indirectly.
skip "etag: If-None-Match / 304 (no Zowe CLI or SDK option — see curl-datasets.sh)"

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
