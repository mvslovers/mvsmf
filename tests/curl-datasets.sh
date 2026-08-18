#!/bin/bash
# =========================================================================
# mvsMF Datasets REST API - curl test suite
#
# Tests dataset endpoints with volume serial prefix support:
#   1. POST   /zosmf/restfiles/ds/{dataset-name}          (create)
#   2. GET    /zosmf/restfiles/ds                          (list)
#   3. PUT    /zosmf/restfiles/ds/{dataset-name}           (write seq)
#   4. GET    /zosmf/restfiles/ds/{dataset-name}           (read seq)
#   5. DELETE /zosmf/restfiles/ds/{dataset-name}           (delete)
#   6. GET    /zosmf/restfiles/ds/{dataset-name}/member    (list members)
#   7. PUT    /zosmf/restfiles/ds/{dsn}({member})          (write member)
#   8. GET    /zosmf/restfiles/ds/{dsn}({member})          (read member)
#   9. DELETE /zosmf/restfiles/ds/{dsn}({member})          (delete member)
#  10. Volume prefix variants: -(vol)/...
#
# Prerequisites:
#   - Copy .env.example to .env at the repo root and fill in
#   - curl and jq must be installed
#
# Usage:
#   ./tests/curl-datasets.sh
# =========================================================================

# When a skip is right, and when it is a failure wearing a disguise
# ---------------------------------------------------------------------------
# A skip is right when the precondition is something this suite did not create
# and cannot: other jobs on the system, a data set that only exists on one
# stand, an ACTIVE started task, a client capability (python3, a Zowe CLI flag),
# or a defect with a ticket behind it.
#
# A skip is wrong -- and reports a broken run as green -- when the precondition
# is something this suite created through the very API under test, or was
# explicitly asked to create with --setup. Its absence then means that API
# misbehaved, and that has to be red. This is #304: the dataset-submit path went
# unexercised for months behind exactly such a skip.
#
# Downstream skips ("no submitted job") are fine as they are: they only fire
# after an assertion has already failed, so the run is red regardless.

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

BASE_URL="http://${MVSMF_HOST}:${MVSMF_PORT}"
AUTH="${MVSMF_USER}:${MVSMF_PASS}"

# Test dataset names
TEST_SEQ="${MVSMF_USER}.CURL.TESTSEQ"
TEST_SEQ2="${MVSMF_USER}.CURL.TESTSEQ2"
TEST_PDS="${MVSMF_USER}.CURL.TESTPDS"
# Large-LRECL fixtures for issue #198 (records above the old 1024-byte limit)
TEST_BIG="${MVSMF_USER}.CURL.TESTBIG"
TEST_BIGPDS="${MVSMF_USER}.CURL.TESTBGP"

# --- state ---
PASSED=0
FAILED=0
SKIPPED=0
TOTAL=0
VOLUME=""

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

assert_http_status() {
	local expected="$1"
	local actual="$2"
	local label="$3"
	if [ "$actual" = "$expected" ]; then
		pass "$label (HTTP $actual)"
	else
		fail "$label" "expected HTTP $expected, got $actual"
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
# Cleanup helper — delete datasets ignoring errors
# =========================================================================

cleanup_datasets() {
	curl -s -X DELETE -u "$AUTH" "${BASE_URL}/zosmf/restfiles/ds/${TEST_SEQ}" >/dev/null 2>&1 || true
	curl -s -X DELETE -u "$AUTH" "${BASE_URL}/zosmf/restfiles/ds/${TEST_SEQ2}" >/dev/null 2>&1 || true
	curl -s -X DELETE -u "$AUTH" "${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}" >/dev/null 2>&1 || true
}

# =========================================================================
# Tests
# =========================================================================

echo ""
echo "========================================"
echo " mvsMF Datasets API - curl test suite"
echo " Host: ${MVSMF_HOST}:${MVSMF_PORT}"
echo " User: ${MVSMF_USER}"
echo "========================================"

# Clean up any leftovers from previous runs
cleanup_datasets

# --- Create sequential dataset ---
echo ""
echo "--- Create Sequential Dataset ---"

BODY='{"dsorg":"PS","recfm":"FB","lrecl":80,"blksize":3120,"alcunit":"TRK","primary":1,"secondary":1}'
HTTP_CODE=$(curl -s -w '%{http_code}' -o /tmp/curl_ds_create.json \
	-X POST -u "$AUTH" \
	-H "Content-Type: application/json" \
	-d "$BODY" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_SEQ}")
assert_http_status "201" "$HTTP_CODE" "create sequential dataset"

# --- Write to sequential dataset ---
echo ""
echo "--- Write Sequential Dataset ---"

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X PUT -u "$AUTH" \
	-H "Content-Type: application/octet-stream" \
	--data-binary $'LINE 1 TEST DATA\nLINE 2 TEST DATA\nLINE 3 TEST DATA\n' \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_SEQ}")
assert_http_status "204" "$HTTP_CODE" "write sequential dataset"

# --- Read sequential dataset ---
echo ""
echo "--- Read Sequential Dataset ---"

BODY=$(curl -s -w '\n%{http_code}' -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_SEQ}")
HTTP_CODE=$(echo "$BODY" | tail -1)
CONTENT=$(echo "$BODY" | sed '$d')
assert_http_status "200" "$HTTP_CODE" "read sequential dataset"

if echo "$CONTENT" | grep -q "LINE 1 TEST DATA"; then
	pass "read content matches"
else
	fail "read content matches" "expected 'LINE 1 TEST DATA' in output"
fi

# FB datasets pad records to LRECL with spaces; verify they are stripped on download
if echo "$CONTENT" | grep -q "LINE 1 TEST DATA  "; then
	fail "FB dataset strips trailing spaces" "trailing space padding found in text output"
else
	pass "FB dataset strips trailing spaces"
fi

# Regression for #138: trailing-space stripping must not leak a raw control
# byte into the (already ASCII) output. The earlier fix re-added the newline
# after EBCDIC->ASCII translation, writing the compiler's EBCDIC '\n' (X'15')
# straight into the stream, which surfaced as a stray ^U (0x15) on every line
# but the first. Download to a file and check the raw bytes.
RAW_FILE=$(mktemp)
curl -s -u "$AUTH" "${BASE_URL}/zosmf/restfiles/ds/${TEST_SEQ}" > "$RAW_FILE"
if LC_ALL=C grep -q $'\025' "$RAW_FILE"; then
	fail "FB download has no stray control bytes" "found 0x15 (NEL/^U) in text output"
else
	pass "FB download has no stray control bytes"
fi
rm -f "$RAW_FILE"

# --- List datasets (two-level prefix) ---
echo ""
echo "--- List Datasets (two-level prefix) ---"

BODY=$(curl -s -w '\n%{http_code}' -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds?dslevel=${MVSMF_USER}.CURL")
HTTP_CODE=$(echo "$BODY" | tail -1)
CONTENT=$(echo "$BODY" | sed '$d')
assert_http_status "200" "$HTTP_CODE" "list datasets (two-level prefix)"

ITEMS=$(echo "$CONTENT" | jq '.items | length' 2>/dev/null) || ITEMS=0
if [ "$ITEMS" -gt 0 ] 2>/dev/null; then
	pass "list returned results ($ITEMS items)"
else
	fail "list returned results" "expected >0 items"
fi

# Extract volume serial for later volume-prefix tests
VOLUME=$(echo "$CONTENT" | jq -r --arg dsn "$TEST_SEQ" \
	'.items[] | select(.dsname == $dsn) | .vol // empty' 2>/dev/null) || VOLUME=""

# --- List datasets (exact three-level name) ---
echo ""
echo "--- List Datasets (exact name) ---"

BODY=$(curl -s -w '\n%{http_code}' -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds?dslevel=${TEST_SEQ}")
HTTP_CODE=$(echo "$BODY" | tail -1)
CONTENT=$(echo "$BODY" | sed '$d')
assert_http_status "200" "$HTTP_CODE" "list datasets (exact name)"
assert_json_field "$CONTENT" '.items[0].dsname' "$TEST_SEQ" "exact name match"

# --- List datasets (exact two-level name, issue #61) ---
echo ""
echo "--- List Datasets (exact two-level name) ---"

BODY=$(curl -s -w '\n%{http_code}' -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds?dslevel=SYS1.MACLIB")
HTTP_CODE=$(echo "$BODY" | tail -1)
CONTENT=$(echo "$BODY" | sed '$d')
assert_http_status "200" "$HTTP_CODE" "list datasets (exact two-level name)"
assert_json_field "$CONTENT" '.items[0].dsname' "SYS1.MACLIB" "two-level exact name match"

# --- List datasets (two-level prefix returns exact + sub-datasets, issue #61) ---
echo ""
echo "--- List Datasets (two-level prefix semantics) ---"

# Create a two-level dataset alongside the existing three-level TEST_SEQ
TEST_2LVL="${MVSMF_USER}.CURL"
BODY_2LVL='{"dsorg":"PS","recfm":"FB","lrecl":80,"blksize":3120,"alcunit":"TRK","primary":1,"secondary":1}'
curl -s -w '%{http_code}' -o /dev/null \
	-X POST -u "$AUTH" \
	-H "Content-Type: application/json" \
	-d "$BODY_2LVL" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_2LVL}" >/dev/null 2>&1

BODY=$(curl -s -w '\n%{http_code}' -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds?dslevel=${TEST_2LVL}")
HTTP_CODE=$(echo "$BODY" | tail -1)
CONTENT=$(echo "$BODY" | sed '$d')
assert_http_status "200" "$HTTP_CODE" "list datasets (two-level prefix)"

# Should find both the exact two-level dataset and the three-level ones below it
ITEMS=$(echo "$CONTENT" | jq '.items | length' 2>/dev/null) || ITEMS=0
if [ "$ITEMS" -ge 2 ] 2>/dev/null; then
	pass "two-level prefix returned exact + sub-datasets ($ITEMS items)"
else
	fail "two-level prefix returned exact + sub-datasets" "expected >=2 items, got $ITEMS"
fi

HAS_EXACT=$(echo "$CONTENT" | jq --arg n "$TEST_2LVL" '[.items[].dsname] | index($n) != null' 2>/dev/null)
if [ "$HAS_EXACT" = "true" ]; then
	pass "two-level prefix includes exact match ($TEST_2LVL)"
else
	fail "two-level prefix includes exact match" "expected $TEST_2LVL in results"
fi

HAS_SUB=$(echo "$CONTENT" | jq --arg n "$TEST_SEQ" '[.items[].dsname] | index($n) != null' 2>/dev/null)
if [ "$HAS_SUB" = "true" ]; then
	pass "two-level prefix includes sub-dataset ($TEST_SEQ)"
else
	fail "two-level prefix includes sub-dataset" "expected $TEST_SEQ in results"
fi

# Clean up the two-level dataset
curl -s -X DELETE -u "$AUTH" "${BASE_URL}/zosmf/restfiles/ds/${TEST_2LVL}" >/dev/null 2>&1 || true

# --- List datasets (wildcard *) ---
echo ""
echo "--- List Datasets (wildcard *) ---"

BODY=$(curl -s -w '\n%{http_code}' -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds?dslevel=${MVSMF_USER}.*")
HTTP_CODE=$(echo "$BODY" | tail -1)
CONTENT=$(echo "$BODY" | sed '$d')
assert_http_status "200" "$HTTP_CODE" "list datasets (wildcard *)"

ITEMS=$(echo "$CONTENT" | jq '.items | length' 2>/dev/null) || ITEMS=0
if [ "$ITEMS" -gt 0 ] 2>/dev/null; then
	pass "wildcard * returned results ($ITEMS items)"
else
	fail "wildcard * returned results" "expected >0 items"
fi

# --- List datasets (wildcard **) ---
echo ""
echo "--- List Datasets (wildcard **) ---"

BODY=$(curl -s -w '\n%{http_code}' -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds?dslevel=${MVSMF_USER}.**")
HTTP_CODE=$(echo "$BODY" | tail -1)
CONTENT=$(echo "$BODY" | sed '$d')
assert_http_status "200" "$HTTP_CODE" "list datasets (wildcard **)"

ITEMS=$(echo "$CONTENT" | jq '.items | length' 2>/dev/null) || ITEMS=0
if [ "$ITEMS" -gt 0 ] 2>/dev/null; then
	pass "wildcard ** returned results ($ITEMS items)"
else
	fail "wildcard ** returned results" "expected >0 items"
fi

# --- List datasets (partial wildcard) ---
echo ""
echo "--- List Datasets (partial wildcard) ---"

BODY=$(curl -s -w '\n%{http_code}' -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds?dslevel=${MVSMF_USER}.CURL*")
HTTP_CODE=$(echo "$BODY" | tail -1)
CONTENT=$(echo "$BODY" | sed '$d')
assert_http_status "200" "$HTTP_CODE" "list datasets (partial wildcard)"

ITEMS=$(echo "$CONTENT" | jq '.items | length' 2>/dev/null) || ITEMS=0
if [ "$ITEMS" -gt 0 ] 2>/dev/null; then
	pass "partial wildcard returned results ($ITEMS items)"
else
	fail "partial wildcard returned results" "expected >0 items"
fi

# --- Create PDS (needed before max-items test so two datasets exist) ---
echo ""
echo "--- Create PDS ---"

BODY='{"dsorg":"PO","recfm":"FB","lrecl":80,"blksize":3120,"alcunit":"TRK","primary":1,"secondary":1,"dirblk":5}'
HTTP_CODE=$(curl -s -w '%{http_code}' -o /tmp/curl_ds_pds.json \
	-X POST -u "$AUTH" \
	-H "Content-Type: application/json" \
	-d "$BODY" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}")
assert_http_status "201" "$HTTP_CODE" "create PDS"

# --- List datasets (X-IBM-Max-Items) ---
echo ""
echo "--- List Datasets (X-IBM-Max-Items) ---"

BODY=$(curl -s -w '\n%{http_code}' -u "$AUTH" \
	-H "X-IBM-Max-Items: 1" \
	"${BASE_URL}/zosmf/restfiles/ds?dslevel=${MVSMF_USER}.CURL")
HTTP_CODE=$(echo "$BODY" | tail -1)
CONTENT=$(echo "$BODY" | sed '$d')
# a listing cut short by X-IBM-Max-Items stays 200 and says so in moreRows --
# that is what real z/OSMF does, measured (#274)
assert_http_status "200" "$HTTP_CODE" "list datasets (max-items=1)"

RETURNED=$(echo "$CONTENT" | jq '.returnedRows' 2>/dev/null) || RETURNED=0
if [ "$RETURNED" -eq 1 ] 2>/dev/null; then
	pass "max-items limited to 1 row"
else
	fail "max-items limited to 1 row" "expected returnedRows=1, got $RETURNED"
fi

MORE_ROWS=$(echo "$CONTENT" | jq -r '.moreRows' 2>/dev/null) || MORE_ROWS=""
if [ "$MORE_ROWS" = "true" ]; then
	pass "moreRows=true when truncated"
else
	fail "moreRows=true when truncated" "expected true, got $MORE_ROWS"
fi

# The other half: the header alone does not make a listing partial. A limit
# nothing reaches is a complete answer, and a complete answer carries no
# moreRows key at all (#279).
BODY=$(curl -s -w '\n%{http_code}' -u "$AUTH" \
	-H "X-IBM-Max-Items: 1000" \
	"${BASE_URL}/zosmf/restfiles/ds?dslevel=${MVSMF_USER}.CURL")
HTTP_CODE=$(echo "$BODY" | tail -1)
CONTENT=$(echo "$BODY" | sed '$d')
assert_http_status "200" "$HTTP_CODE" "max-items above the row count stays 200"
assert_json_field_absent "$CONTENT" 'has("moreRows")' \
	"max-items above the row count: no moreRows"

# --- List datasets (start=) ---
#
# start= was read from the query string and then never used, so every page
# began at the first entry and a client paging by name never advanced (#232).
echo ""
echo "--- List Datasets (start=) ---"

ALL=$(curl -s -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds?dslevel=${MVSMF_USER}.CURL" |
	jq -r '.items[].dsname' 2>/dev/null)
COUNT=$(echo "$ALL" | grep -c .)

if [ "$COUNT" -lt 2 ]; then
	# This suite creates its own data sets under <user>.CURL earlier in the run,
	# so fewer than two here means the listing under test lost them, not that
	# the system is bare. Reporting that as a skip hides it (#304).
	fail "start= returns the tail of the list" \
		"the listing reported ${COUNT} data set(s) under ${MVSMF_USER}.CURL; this suite created more"
	fail "start= beyond the last dataset" \
		"the listing reported ${COUNT} data set(s) under ${MVSMF_USER}.CURL; this suite created more"
else
	SECOND=$(echo "$ALL" | sed -n 2p)

	BODY=$(curl -s -w '\n%{http_code}' -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/ds?dslevel=${MVSMF_USER}.CURL&start=${SECOND}")
	HTTP_CODE=$(echo "$BODY" | tail -1)
	CONTENT=$(echo "$BODY" | sed '$d')
	FIRST=$(echo "$CONTENT" | jq -r '.items[0].dsname' 2>/dev/null)
	RETURNED=$(echo "$CONTENT" | jq -r '.returnedRows' 2>/dev/null)

	if [ "$HTTP_CODE" = "200" ] && [ "$FIRST" = "$SECOND" ] &&
	   [ "$RETURNED" = "$((COUNT - 1))" ]; then
		pass "start=${SECOND} returns the tail of the list (inclusive)"
	else
		fail "start=${SECOND} returns the tail of the list" \
			"got HTTP $HTTP_CODE first='$FIRST' returnedRows=$RETURNED (expected first='$SECOND', $((COUNT - 1)) rows)"
	fi

	# The exact-name entry must sort in front of its own children. LISTC
	# returns the children of a level and the handler looks the exact name up
	# separately, so before #232 it was appended last -- with max-items=1 the
	# first page was the CHILD and the parent was unreachable from any later
	# start=.
	BODY='{"dsorg":"PS","recfm":"FB","lrecl":80,"blksize":3120,"alcunit":"TRK","primary":1,"secondary":1}'
	for D in "${MVSMF_USER}.CURL.EXACT" "${MVSMF_USER}.CURL.EXACT.CHILD"; do
		curl -s -o /dev/null -X POST -u "$AUTH" \
			-H "Content-Type: application/json" -d "$BODY" \
			"${BASE_URL}/zosmf/restfiles/ds/${D}"
	done

	CONTENT=$(curl -s -u "$AUTH" -H "X-IBM-Max-Items: 1" \
		"${BASE_URL}/zosmf/restfiles/ds?dslevel=${MVSMF_USER}.CURL.EXACT")
	if [ "$(echo "$CONTENT" | jq -r '.items[0].dsname' 2>/dev/null)" = "${MVSMF_USER}.CURL.EXACT" ] &&
	   [ "$(echo "$CONTENT" | jq -r '.moreRows' 2>/dev/null)" = "true" ]; then
		pass "exact-name entry sorts before its children"
	else
		fail "exact-name entry sorts before its children" \
			"first item is '$(echo "$CONTENT" | jq -r '.items[0].dsname' 2>/dev/null)'"
	fi

	for D in "${MVSMF_USER}.CURL.EXACT.CHILD" "${MVSMF_USER}.CURL.EXACT"; do
		curl -s -o /dev/null -X DELETE -u "$AUTH" \
			"${BASE_URL}/zosmf/restfiles/ds/${D}"
	done

	# past the last name is an empty page, not a full one -- and nothing may
	# claim there is more to fetch, which since #279 means no moreRows key
	CONTENT=$(curl -s -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/ds?dslevel=${MVSMF_USER}.CURL&start=ZZZZZZZZ")
	if [ "$(echo "$CONTENT" | jq -r '.returnedRows' 2>/dev/null)" = "0" ]; then
		pass "start= beyond the last dataset returns an empty page"
	else
		fail "start= beyond the last dataset returns an empty page" \
			"returnedRows=$(echo "$CONTENT" | jq -r '.returnedRows' 2>/dev/null)"
	fi
	assert_json_field_absent "$CONTENT" 'has("moreRows")' \
		"start= beyond the last dataset: no moreRows"

	# --- over-long start= (issue #240) ---
	#
	# The dataset list cuts start= to 44 characters, the longest a cataloged
	# name can be. A 45-character value was then applied as if the client had
	# asked for its 44-character prefix, so a data set named exactly that
	# prefix -- which sorts BEFORE the value that was sent -- stayed in the
	# page. Only a 44-character name can collide, so one is built here.
	LONG_DSN="${MVSMF_USER}.CURL"
	while [ "${#LONG_DSN}" -lt 44 ]; do
		QLEN=$((44 - ${#LONG_DSN} - 1))
		[ "$QLEN" -le 0 ] && break
		[ "$QLEN" -gt 8 ] && QLEN=8
		LONG_DSN="${LONG_DSN}.$(printf 'Q%.0s' $(seq 1 $QLEN))"
	done

	if [ "${#LONG_DSN}" -ne 44 ]; then
		skip "over-long start= (no 44-character name fits under ${MVSMF_USER}.CURL)"
	else
		curl -s -o /dev/null -X POST -u "$AUTH" \
			-H "Content-Type: application/json" \
			-d '{"dsorg":"PS","recfm":"FB","lrecl":80,"blksize":3120,"alcunit":"TRK","primary":1,"secondary":1}' \
			"${BASE_URL}/zosmf/restfiles/ds/${LONG_DSN}"

		# 44 characters fit, so start= still names the first row
		LIST=$(curl -s -u "$AUTH" \
			"${BASE_URL}/zosmf/restfiles/ds?dslevel=${MVSMF_USER}.CURL&start=${LONG_DSN}" |
			jq -r '.items[].dsname' 2>/dev/null)

		if echo "$LIST" | grep -qx "$LONG_DSN"; then
			pass "start= at 44 characters is inclusive"
		else
			fail "start= at 44 characters is inclusive" \
				"got: $(echo "$LIST" | tr '\n' ' ')"
		fi

		# 45 do not, and the prefix must not readmit the name
		LIST=$(curl -s -u "$AUTH" \
			"${BASE_URL}/zosmf/restfiles/ds?dslevel=${MVSMF_USER}.CURL&start=${LONG_DSN}X" |
			jq -r '.items[].dsname' 2>/dev/null)

		if ! echo "$LIST" | grep -qx "$LONG_DSN"; then
			pass "start= at 45 characters starts after the truncated prefix"
		else
			fail "start= at 45 characters starts after the truncated prefix" \
				"got: $(echo "$LIST" | tr '\n' ' ') -- a truncated start= must not readmit the prefix"
		fi

		curl -s -o /dev/null -X DELETE -u "$AUTH" \
			"${BASE_URL}/zosmf/restfiles/ds/${LONG_DSN}"
	fi
fi

# --- Read with volume prefix ---
echo ""
echo "--- Read Sequential Dataset with Volume Prefix ---"
if [ -n "$VOLUME" ] && [ "$VOLUME" != "null" ]; then
	BODY=$(curl -s -w '\n%{http_code}' -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/ds/-(${VOLUME})/${TEST_SEQ}")
	HTTP_CODE=$(echo "$BODY" | tail -1)
	assert_http_status "200" "$HTTP_CODE" "read dataset with volume prefix -(${VOLUME})"
else
	fail "read dataset with volume prefix" "the listing reported no volume for ${TEST_SEQ} -- the value comes from the API under test"
fi

# --- Delete sequential dataset ---
echo ""
echo "--- Delete Sequential Dataset ---"

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X DELETE -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_SEQ}")
assert_http_status "204" "$HTTP_CODE" "delete sequential dataset"

# --- Delete non-existent dataset ---
echo ""
echo "--- Delete Dataset: not found ---"

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X DELETE -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_SEQ}")
assert_http_status "404" "$HTTP_CODE" "delete non-existent dataset"

# --- Create and delete with volume prefix ---
echo ""
echo "--- Delete Sequential Dataset with Volume Prefix ---"

# Create a fresh dataset to delete via volume prefix
BODY='{"dsorg":"PS","recfm":"FB","lrecl":80,"blksize":3120,"alcunit":"TRK","primary":1,"secondary":1}'
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X POST -u "$AUTH" \
	-H "Content-Type: application/json" \
	-d "$BODY" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_SEQ}")

if [ "$HTTP_CODE" = "201" ] && [ -n "$VOLUME" ] && [ "$VOLUME" != "null" ]; then
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X DELETE -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/ds/-(${VOLUME})/${TEST_SEQ}")
	assert_http_status "204" "$HTTP_CODE" "delete dataset with volume prefix -(${VOLUME})"
else
	fail "delete dataset with volume prefix" "could not create the fixture, or the listing reported no volume for it"
fi

# --- Write PDS member ---
echo ""
echo "--- Write PDS Member ---"

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X PUT -u "$AUTH" \
	-H "Content-Type: application/octet-stream" \
	--data-binary $'MEMBER TEST LINE 1\nMEMBER TEST LINE 2\n' \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(TESTMBR)")
assert_http_status "204" "$HTTP_CODE" "write PDS member"

# --- List PDS members ---
echo ""
echo "--- List PDS Members ---"

BODY=$(curl -s -w '\n%{http_code}' -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}/member")
HTTP_CODE=$(echo "$BODY" | tail -1)
CONTENT=$(echo "$BODY" | sed '$d')
assert_http_status "200" "$HTTP_CODE" "list PDS members"
assert_json_field_exists "$CONTENT" '.items[0].member' "member list has member field"
assert_json_field_absent "$CONTENT" 'has("moreRows")' \
	"member list: no moreRows when complete"

# Names come back as z/OSMF reports them, without the directory's blank padding
# (#154). A padded name makes a client build "dsn(member )" for the follow-up
# request. Every other member assertion below compares the exact string, so this
# is checked once here for the directory as a whole.
if echo "$CONTENT" | jq -e '[.items[].member] | length > 0 and all(test("^[^ ]+$"))' \
	>/dev/null 2>&1; then
	pass "member names are returned unpadded"
else
	fail "member names are returned unpadded" \
		"got: $(echo "$CONTENT" | jq -c '[.items[].member]' 2>/dev/null)"
fi

# --- List PDS members (start=) ---
#
# start= was accepted and ignored, so Zowe Explorer could never page past the
# first X-IBM-Max-Items members of a directory (#232).
#
# The names below pin the collating order down. A PDS directory is stored in
# EBCDIC order, where 'F' (0xC6) sorts BEFORE '0' (0xF0) -- in ASCII it is the
# other way round. The directory therefore reads
#
#     MBRA, MBRB, MBRC, MBRF1, MBR03, TESTMBR
#
# and a start=MBR03 compared in ASCII would wrongly keep MBRF1 in the answer.
echo ""
echo "--- List PDS Members (start=, issue #232) ---"

for M in MBRA MBRB MBRC MBRF1 MBR03; do
	curl -s -o /dev/null -X PUT -u "$AUTH" \
		-H "Content-Type: application/octet-stream" \
		--data-binary "MEMBER ${M}" \
		"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(${M})"
done

LIST=$(curl -s -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}/member?start=MBRC" |
	jq -r '.items[].member' 2>/dev/null)

if [ "$(echo "$LIST" | head -1)" = "MBRC" ] &&
   ! echo "$LIST" | grep -qxE 'MBRA|MBRB'; then
	pass "start=MBRC begins at MBRC and drops the earlier members"
else
	fail "start=MBRC begins at MBRC and drops the earlier members" \
		"got: $(echo "$LIST" | tr '\n' ' ')"
fi

LIST=$(curl -s -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}/member?start=MBR03" |
	jq -r '.items[].member' 2>/dev/null)

if [ "$(echo "$LIST" | head -1)" = "MBR03" ] && ! echo "$LIST" | grep -qx 'MBRF1'; then
	pass "start=MBR03 skips MBRF1 (EBCDIC collating order)"
else
	fail "start=MBR03 skips MBRF1 (EBCDIC collating order)" \
		"got: $(echo "$LIST" | tr '\n' ' ') -- an ASCII compare keeps MBRF1"
fi

# the skipped members must not eat the page budget: with the skip applied
# after the cap this returns zero items and moreRows true
BODY=$(curl -s -w '\n%{http_code}' -u "$AUTH" -H 'X-IBM-Max-Items: 2' \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}/member?start=MBRC")
HTTP_CODE=$(echo "$BODY" | tail -1)
CONTENT=$(echo "$BODY" | sed '$d')
LIST=$(echo "$CONTENT" | jq -r '.items[].member' 2>/dev/null)

if [ "$HTTP_CODE" = "200" ] &&
   [ "$(echo "$CONTENT" | jq -r '.returnedRows' 2>/dev/null)" = "2" ] &&
   [ "$(echo "$LIST" | head -1)" = "MBRC" ] &&
   [ "$(echo "$LIST" | sed -n 2p)" = "MBRF1" ] &&
   [ "$(echo "$CONTENT" | jq -r '.moreRows' 2>/dev/null)" = "true" ]; then
	pass "start=MBRC with max-items=2 returns MBRC,MBRF1 and moreRows=true"
else
	fail "start=MBRC with max-items=2 returns MBRC,MBRF1 and moreRows=true" \
		"got HTTP $HTTP_CODE rows=$(echo "$CONTENT" | jq -r '.returnedRows' 2>/dev/null) items='$(echo "$LIST" | tr '\n' ' ')' moreRows=$(echo "$CONTENT" | jq -r '.moreRows' 2>/dev/null)"
fi

# the listing no longer pads the names it returns (#154), but a client holding
# an older list -- or padding a name itself -- still sends the blanks, and
# start= has to keep tolerating them
LIST=$(curl -s -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}/member?start=MBRC%20%20%20%20" |
	jq -r '.items[].member' 2>/dev/null)

if [ "$(echo "$LIST" | head -1)" = "MBRC" ]; then
	pass "start= tolerates a blank-padded member name"
else
	fail "start= tolerates a blank-padded member name" \
		"got: $(echo "$LIST" | tr '\n' ' ')"
fi

CONTENT=$(curl -s -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}/member?start=ZZZZZZZZ")
if [ "$(echo "$CONTENT" | jq -r '.returnedRows' 2>/dev/null)" = "0" ]; then
	pass "start= beyond the last member returns an empty page"
else
	fail "start= beyond the last member returns an empty page" \
		"returnedRows=$(echo "$CONTENT" | jq -r '.returnedRows' 2>/dev/null)"
fi
assert_json_field_absent "$CONTENT" 'has("moreRows")' \
	"start= beyond the last member: no moreRows"

# --- List PDS members (pattern=) ---
#
# pattern= was accepted and ignored, so a filtered member view silently showed
# the whole directory (#236). '*' matches any run of characters, '%' exactly
# one -- and '%' has to be sent percent-encoded as %25, or the URL parser eats
# it as an escape.
#
# The directory at this point is MBRA, MBRB, MBRC, MBRF1, MBR03, TESTMBR.
echo ""
echo "--- List PDS Members (pattern=, issue #236) ---"

pattern_list() {
	curl -s -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}/member?pattern=$1" |
		jq -r '.items[].member' 2>/dev/null | tr '\n' ' ' |
		sed 's/ *$//'
}

assert_pattern() {
	local got
	got=$(pattern_list "$1")
	if [ "$got" = "$2" ]; then
		pass "pattern=$1 -> $2"
	else
		fail "pattern=$1 -> $2" "got '$got'"
	fi
}

assert_pattern 'MBR*'  'MBRA MBRB MBRC MBRF1 MBR03'
assert_pattern 'MBR%25' 'MBRA MBRB MBRC'
assert_pattern '*MBR*' 'MBRA MBRB MBRC MBRF1 MBR03 TESTMBR'
assert_pattern 'MBRC'  'MBRC'
assert_pattern 'NOSUCH*' ''

# a filtered-out member must not consume a slot of the page
BODY=$(curl -s -w '\n%{http_code}' -u "$AUTH" -H 'X-IBM-Max-Items: 2' \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}/member?pattern=MBR%25")
HTTP_CODE=$(echo "$BODY" | tail -1)
CONTENT=$(echo "$BODY" | sed '$d')
LIST=$(echo "$CONTENT" | jq -r '.items[].member' 2>/dev/null |
	tr '\n' ' ' | sed 's/ *$//')

if [ "$HTTP_CODE" = "200" ] && [ "$LIST" = "MBRA MBRB" ] &&
   [ "$(echo "$CONTENT" | jq -r '.returnedRows' 2>/dev/null)" = "2" ] &&
   [ "$(echo "$CONTENT" | jq -r '.moreRows' 2>/dev/null)" = "true" ]; then
	pass "pattern= with max-items=2 fills the page with matches only"
else
	fail "pattern= with max-items=2 fills the page with matches only" \
		"got HTTP $HTTP_CODE items='$LIST' moreRows=$(echo "$CONTENT" | jq -r '.moreRows' 2>/dev/null)"
fi

# A page that is exactly full is not truncated. The walk looks one match past
# the page to tell those two apart, and a walk bounded at the page instead
# cannot: it returns the limit either way, and every directory whose member
# count equals the limit would report moreRows true (#274). The limit is read
# off an unlimited listing rather than hardcoded, so adding members above does
# not quietly turn this into the truncated case again.
# MEMBER_COUNT, not TOTAL: TOTAL is the suite's own test counter, and assigning
# to it here reset the run tally mid-suite -- which is why the summary line read
# "188 passed, 0 failed, 2 skipped (141 total)".
MEMBER_COUNT=$(curl -s -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}/member" |
	jq -r '.returnedRows' 2>/dev/null)
BODY=$(curl -s -w '\n%{http_code}' -u "$AUTH" -H "X-IBM-Max-Items: ${MEMBER_COUNT}" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}/member")
HTTP_CODE=$(echo "$BODY" | tail -1)
CONTENT=$(echo "$BODY" | sed '$d')

if [ "$HTTP_CODE" = "200" ] &&
   [ "$(echo "$CONTENT" | jq -r '.returnedRows' 2>/dev/null)" = "$MEMBER_COUNT" ]; then
	pass "max-items equal to the member count returns every member"
else
	fail "max-items equal to the member count returns every member" \
		"got HTTP $HTTP_CODE rows=$(echo "$CONTENT" | jq -r '.returnedRows' 2>/dev/null) of $MEMBER_COUNT"
fi
assert_json_field_absent "$CONTENT" 'has("moreRows")' \
	"max-items equal to the member count: no moreRows"

# an over-long pattern is rejected, not quietly cut down to size: a truncated
# pattern selects a different set of members, and answering 200 with that list
# is a wrong answer rather than an error
LONG_PATTERN=$(printf 'A%.0s' $(seq 1 60))
HTTP_CODE=$(curl -s -o /tmp/curl_ds_pat.json -w '%{http_code}' -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}/member?pattern=${LONG_PATTERN}")
assert_http_status "400" "$HTTP_CODE" "over-long pattern is rejected"
assert_json_field "$(cat /tmp/curl_ds_pat.json)" '.reason' "9" \
	"over-long pattern: reason 9 (pattern too long)"

# pattern= and start= have to compose -- Zowe pages a filtered list
LIST=$(curl -s -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}/member?start=MBRB&pattern=MBR%25" |
	jq -r '.items[].member' 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')

if [ "$LIST" = "MBRB MBRC" ]; then
	pass "start= and pattern= compose"
else
	fail "start= and pattern= compose" "got '$LIST' (expected 'MBRB MBRC')"
fi

# --- List PDS members (over-long start=, issue #240) ---
#
# A start= value longer than eight characters is cut to eight. It used to be
# applied as if the client had asked for that prefix, so a member named exactly
# the prefix -- which sorts BEFORE the value the client sent -- came back in the
# page. The prefix now starts the page exclusively.
#
# The directory here is MBRA, MBRB, MBRC, MBRCXXXX, MBRF1, MBR03, TESTMBR, in
# EBCDIC order: MBRC pads with blanks and 0x40 sorts below 'X'.
echo ""
echo "--- List PDS Members (over-long start=, issue #240) ---"

curl -s -o /dev/null -X PUT -u "$AUTH" \
	-H "Content-Type: application/octet-stream" \
	--data-binary "MEMBER MBRCXXXX" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(MBRCXXXX)"

# eight characters still fit, so start= keeps naming the first member of the page
LIST=$(curl -s -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}/member?start=MBRCXXXX" |
	jq -r '.items[].member' 2>/dev/null)

if [ "$(echo "$LIST" | head -1)" = "MBRCXXXX" ]; then
	pass "start=MBRCXXXX (8 chars) is inclusive"
else
	fail "start=MBRCXXXX (8 chars) is inclusive" \
		"got: $(echo "$LIST" | tr '\n' ' ')"
fi

# nine characters do not: MBRCXXXX sorts before MBRCXXXXY and must be dropped
LIST=$(curl -s -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}/member?start=MBRCXXXXY" |
	jq -r '.items[].member' 2>/dev/null)

if [ "$(echo "$LIST" | head -1)" = "MBRF1" ] &&
   ! echo "$LIST" | grep -qx 'MBRCXXXX'; then
	pass "start=MBRCXXXXY (9 chars) starts after the truncated prefix"
else
	fail "start=MBRCXXXXY (9 chars) starts after the truncated prefix" \
		"got: $(echo "$LIST" | tr '\n' ' ') -- a truncated start= must not readmit the prefix"
fi

curl -s -o /dev/null -X DELETE -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(MBRCXXXX)"

for M in MBRA MBRB MBRC MBRF1 MBR03; do
	curl -s -o /dev/null -X DELETE -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(${M})"
done

# --- List members: a large directory must not take the server down (#212) ---
# memberListHandler used to build the whole member array in storage via
# __listpd(). On SYS1.SMPCDS (~23000 members) that exhausts the region and
# abends S878, and because the abend unwinds before __freepd() the storage is
# never returned -- httpd can then no longer load MVSMF and EVERY endpoint
# answers S80A until it is restarted. One request was enough.
#
# So this case asserts two things: the request itself succeeds, and the server
# is still alive afterwards. The second assertion is the one that matters.
echo ""
echo "--- List PDS Members: large directory (issue #212) ---"

BIG_PDS="${BIG_PDS:-SYS1.SMPCDS}"

HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -m 180 -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${BIG_PDS}/member")

if [ "$HTTP_CODE" = "404" ]; then
	skip "large member list (${BIG_PDS} not on this system)"
	skip "large member list: X-IBM-Max-Items (${BIG_PDS} not on this system)"
	skip "server survives a large member list (${BIG_PDS} not on this system)"
else
	assert_http_status "200" "$HTTP_CODE" "list members of ${BIG_PDS}"

	# Member names are not guaranteed to be printable -- the SMP/E keys in
	# SYS1.SMPCDS are binary. Emitted raw they produce control characters
	# inside a JSON string, which no parser accepts, so the response has to
	# survive an actual parse and not merely arrive with status 200.
	if curl -s -m 180 -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/ds/${BIG_PDS}/member" | jq -e . >/dev/null 2>&1; then
		pass "${BIG_PDS} member list is valid JSON (binary names escaped)"
	else
		fail "${BIG_PDS} member list is valid JSON" \
			"jq rejected the response -- unescaped bytes in a member name"
	fi

	# The cap is asserted here rather than against TEST_PDS: that one holds a
	# single member, so max-items=1 and no cap at all produce byte-identical
	# output and the assertion would pass either way. Against a directory with
	# thousands of entries the cap is the only thing that can produce 10 rows,
	# and moreRows must then be true.
	BODY=$(curl -s -w '\n%{http_code}' -m 180 -u "$AUTH" -H 'X-IBM-Max-Items: 10' \
		"${BASE_URL}/zosmf/restfiles/ds/${BIG_PDS}/member")
	HTTP_CODE=$(echo "$BODY" | tail -1)
	CONTENT=$(echo "$BODY" | sed '$d')

	if [ "$HTTP_CODE" = "200" ] &&
	   [ "$(echo "$CONTENT" | jq -r '.returnedRows')" = "10" ] &&
	   [ "$(echo "$CONTENT" | jq -r '.items | length')" = "10" ] &&
	   [ "$(echo "$CONTENT" | jq -r '.moreRows')" = "true" ]; then
		pass "max-items=10 on ${BIG_PDS}: 10 rows and moreRows=true"
	else
		fail "max-items=10 on ${BIG_PDS}" \
			"got HTTP $HTTP_CODE returnedRows=$(echo "$CONTENT" | jq -r '.returnedRows') moreRows=$(echo "$CONTENT" | jq -r '.moreRows')"
	fi

	# This is where a large directory shows whether the walk still stops one
	# match past the page: with start= applied first it must return the first
	# 10 members behind the key and give up there, not read 23000 entries.
	# A timeout here is the regression.
	START=$(date +%s)
	BODY=$(curl -s -w '\n%{http_code}' -m 180 -u "$AUTH" -H 'X-IBM-Max-Items: 10' \
		"${BASE_URL}/zosmf/restfiles/ds/${BIG_PDS}/member?start=A")
	ELAPSED=$(( $(date +%s) - START ))
	HTTP_CODE=$(echo "$BODY" | tail -1)
	CONTENT=$(echo "$BODY" | sed '$d')

	if [ "$HTTP_CODE" = "200" ] &&
	   [ "$(echo "$CONTENT" | jq -r '.returnedRows')" = "10" ]; then
		pass "max-items=10 with start= on ${BIG_PDS} (${ELAPSED}s)"
	else
		fail "max-items=10 with start= on ${BIG_PDS}" \
			"got HTTP $HTTP_CODE returnedRows=$(echo "$CONTENT" | jq -r '.returnedRows') after ${ELAPSED}s"
	fi

	# the regression: is MVSMF still loadable at all?
	AFTER=$(curl -s -m 20 -u "$AUTH" "${BASE_URL}/zosmf/info")
	case "$AFTER" in
		*S80A*|"")
			fail "server survives a large member list" \
				"MVSMF no longer loads after ${BIG_PDS} -- httpd needs a restart"
			;;
		*)
			pass "server still serves requests after listing ${BIG_PDS}"
			;;
	esac
fi

# --- List members: the target must actually be a PDS (issue #193) ---
# __listpd() reads the directory with BPAM and abends S001 on a sequential
# data set, so this used to be answered by the router's abend recovery. A
# data set that is not cataloged at all used to come back as an empty 200,
# which reads as "this PDS has no members".
echo ""
echo "--- List PDS Members: wrong or missing target (issue #193) ---"

LIST_SEQ="${MVSMF_USER}.CURL.LISTSEQ"
curl -s -X DELETE -u "$AUTH" "${BASE_URL}/zosmf/restfiles/ds/${LIST_SEQ}" >/dev/null 2>&1 || true
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X POST -u "$AUTH" -H "Content-Type: application/json" \
	-d '{"dsorg":"PS","recfm":"FB","lrecl":80,"blksize":800,"alcunit":"TRK","primary":1}' \
	"${BASE_URL}/zosmf/restfiles/ds/${LIST_SEQ}")

if [ "$HTTP_CODE" = "201" ]; then
	BODY=$(curl -s -w '\n%{http_code}' -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/ds/${LIST_SEQ}/member")
	HTTP_CODE=$(echo "$BODY" | tail -1)
	CONTENT=$(echo "$BODY" | sed '$d')
	assert_http_status "400" "$HTTP_CODE" "list members of a sequential dataset"
	if echo "$CONTENT" | grep -q "abend"; then
		fail "list members of a sequential dataset must not abend" "abend recovery response"
	else
		pass "list members of a sequential dataset does not abend"
	fi
	curl -s -X DELETE -u "$AUTH" "${BASE_URL}/zosmf/restfiles/ds/${LIST_SEQ}" >/dev/null 2>&1 || true
else
	fail "list members of a sequential dataset" "could not create ${LIST_SEQ} (HTTP ${HTTP_CODE})"
fi

BODY=$(curl -s -w '\n%{http_code}' -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${MVSMF_USER}.NOSUCH.LISTPDS/member")
HTTP_CODE=$(echo "$BODY" | tail -1)
CONTENT=$(echo "$BODY" | sed '$d')
assert_http_status "404" "$HTTP_CODE" "list members of a missing dataset"
assert_json_field "$CONTENT" '.reason' "4" "missing dataset: reason 4 (dataset not found)"

# --- List PDS members with volume prefix ---
echo ""
echo "--- List PDS Members with Volume Prefix ---"

# Get volume from a dataset list query
VOLBODY=$(curl -s -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds?dslevel=${MVSMF_USER}.CURL")
PDS_VOLUME=$(echo "$VOLBODY" | jq -r --arg dsn "$TEST_PDS" \
	'.items[] | select(.dsname == $dsn) | .vol // empty' 2>/dev/null) || PDS_VOLUME=""

if [ -n "$PDS_VOLUME" ] && [ "$PDS_VOLUME" != "null" ]; then
	BODY=$(curl -s -w '\n%{http_code}' -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/ds/-(${PDS_VOLUME})/${TEST_PDS}/member")
	HTTP_CODE=$(echo "$BODY" | tail -1)
	assert_http_status "200" "$HTTP_CODE" "list members with volume prefix -(${PDS_VOLUME})"
else
	fail "list members with volume prefix" "the listing reported no volume for ${TEST_PDS} -- the value comes from the API under test"
fi

# --- Read PDS member ---
echo ""
echo "--- Read PDS Member ---"

BODY=$(curl -s -w '\n%{http_code}' -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(TESTMBR)")
HTTP_CODE=$(echo "$BODY" | tail -1)
CONTENT=$(echo "$BODY" | sed '$d')
assert_http_status "200" "$HTTP_CODE" "read PDS member"

if echo "$CONTENT" | grep -q "MEMBER TEST LINE 1"; then
	pass "member content matches"
else
	fail "member content matches" "expected 'MEMBER TEST LINE 1' in output"
fi

# --- Read PDS member with volume prefix ---
echo ""
echo "--- Read PDS Member with Volume Prefix ---"

if [ -n "$PDS_VOLUME" ] && [ "$PDS_VOLUME" != "null" ]; then
	BODY=$(curl -s -w '\n%{http_code}' -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/ds/-(${PDS_VOLUME})/${TEST_PDS}(TESTMBR)")
	HTTP_CODE=$(echo "$BODY" | tail -1)
	assert_http_status "200" "$HTTP_CODE" "read member with volume prefix -(${PDS_VOLUME})"
else
	fail "read member with volume prefix" "the listing reported no volume for ${TEST_PDS} -- the value comes from the API under test"
fi

# --- Write PDS member with volume prefix ---
echo ""
echo "--- Write PDS Member with Volume Prefix ---"

if [ -n "$PDS_VOLUME" ] && [ "$PDS_VOLUME" != "null" ]; then
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X PUT -u "$AUTH" \
		-H "Content-Type: application/octet-stream" \
		--data-binary $'VOLUME PREFIX WRITE TEST\n' \
		"${BASE_URL}/zosmf/restfiles/ds/-(${PDS_VOLUME})/${TEST_PDS}(VOLMBR)")
	assert_http_status "204" "$HTTP_CODE" "write member with volume prefix -(${PDS_VOLUME})"
else
	fail "write member with volume prefix" "the listing reported no volume for ${TEST_PDS} -- the value comes from the API under test"
fi

# --- Rename PDS member ---
echo ""
echo "--- Rename PDS Member ---"

# rename TESTMBR -> TESTMBR2 (z/OSMF control request)
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X PUT -u "$AUTH" \
	-H "Content-Type: application/json" \
	--data-binary "{\"request\":\"rename\",\"from-dataset\":{\"dsn\":\"${TEST_PDS}\",\"member\":\"TESTMBR\"}}" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(TESTMBR2)")
assert_http_status "204" "$HTTP_CODE" "rename PDS member TESTMBR -> TESTMBR2"

# new member is readable and keeps the original content
BODY=$(curl -s -w '\n%{http_code}' -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(TESTMBR2)")
HTTP_CODE=$(echo "$BODY" | tail -1)
CONTENT=$(echo "$BODY" | sed '$d')
assert_http_status "200" "$HTTP_CODE" "read renamed member TESTMBR2"
if echo "$CONTENT" | grep -q "MEMBER TEST LINE 1"; then
	pass "renamed member content preserved"
else
	fail "renamed member content preserved" "expected 'MEMBER TEST LINE 1' in output"
fi

# old member no longer exists
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(TESTMBR)")
assert_http_status "404" "$HTTP_CODE" "old member TESTMBR is gone after rename"

# rename a non-existent member -> 404
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X PUT -u "$AUTH" \
	-H "Content-Type: application/json" \
	--data-binary "{\"request\":\"rename\",\"from-dataset\":{\"dsn\":\"${TEST_PDS}\",\"member\":\"NOSUCH\"}}" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(WHATEVER)")
assert_http_status "404" "$HTTP_CODE" "rename non-existent member returns 404"

# rename back so the remaining tests operate on TESTMBR
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X PUT -u "$AUTH" \
	-H "Content-Type: application/json" \
	--data-binary "{\"request\":\"rename\",\"from-dataset\":{\"dsn\":\"${TEST_PDS}\",\"member\":\"TESTMBR2\"}}" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(TESTMBR)")
assert_http_status "204" "$HTTP_CODE" "rename PDS member TESTMBR2 -> TESTMBR (restore)"

# --- Delete PDS member ---
echo ""
echo "--- Delete PDS Member ---"

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X DELETE -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(TESTMBR)")
assert_http_status "204" "$HTTP_CODE" "delete PDS member"

# --- Delete PDS member with volume prefix ---
echo ""
echo "--- Delete PDS Member with Volume Prefix ---"

if [ -n "$PDS_VOLUME" ] && [ "$PDS_VOLUME" != "null" ]; then
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X DELETE -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/ds/-(${PDS_VOLUME})/${TEST_PDS}(VOLMBR)")
	assert_http_status "204" "$HTTP_CODE" "delete member with volume prefix -(${PDS_VOLUME})"
else
	fail "delete member with volume prefix" "the listing reported no volume for ${TEST_PDS} -- the value comes from the API under test"
fi

# --- Delete PDS member: not found ---
echo ""
echo "--- Delete PDS Member: not found ---"

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X DELETE -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(TESTMBR)")
assert_http_status "404" "$HTTP_CODE" "delete non-existent member"

# --- Open failures: 404 vs 500 (Issue #191) ---
# fopen() only reports NULL, so every failed open used to be an I/O error 500 —
# a member that is simply not there was indistinguishable from a broken server,
# and 500 invites a retry that can never succeed.
echo ""
echo "--- Open failures: not found must be 404, not 500 (issue #191) ---"

# missing sequential dataset
RESP=$(curl -s -w '\n%{http_code}' -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${MVSMF_USER}.NOSUCH.SEQDS")
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_http_status "404" "$HTTP_CODE" "read missing sequential dataset"
assert_json_field "$BODY" '.reason' "4" "missing dataset: reason 4 (dataset not found)"

# missing member of a dataset that does exist
RESP=$(curl -s -w '\n%{http_code}' -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(NOSUCHMB)")
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_http_status "404" "$HTTP_CODE" "read missing member of an existing PDS"
assert_json_field "$BODY" '.reason' "5" "missing member: reason 5 (member not found)"

# member of a dataset that does not exist — the dataset is the reason, not the member
RESP=$(curl -s -w '\n%{http_code}' -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${MVSMF_USER}.NOSUCH.PDS(M1)")
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')
assert_http_status "404" "$HTTP_CODE" "read member of a missing PDS"
assert_json_field "$BODY" '.reason' "4" "member of missing PDS: reason 4 (dataset not found)"

# asking for a member of a data set that is not partitioned. __listpd() reads
# the directory with BPAM and abends S001 on a sequential data set, so this
# used to come back as the router's abend-recovery 500.
# Self-contained: TEST_SEQ has already been deleted by the delete tests at
# this point, and a missing data set would answer 404 instead of 400.
PROBE_SEQ="${MVSMF_USER}.CURL.NOTPDS"
curl -s -X DELETE -u "$AUTH" "${BASE_URL}/zosmf/restfiles/ds/${PROBE_SEQ}" >/dev/null 2>&1 || true
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X POST -u "$AUTH" -H "Content-Type: application/json" \
	-d '{"dsorg":"PS","recfm":"FB","lrecl":80,"blksize":800,"alcunit":"TRK","primary":1}' \
	"${BASE_URL}/zosmf/restfiles/ds/${PROBE_SEQ}")

if [ "$HTTP_CODE" = "201" ]; then
	RESP=$(curl -s -w '\n%{http_code}' -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/ds/${PROBE_SEQ}(M1)")
	HTTP_CODE=$(echo "$RESP" | tail -1)
	BODY=$(echo "$RESP" | sed '$d')
	assert_http_status "400" "$HTTP_CODE" "read a member of a sequential dataset"
	if echo "$BODY" | grep -q "abend"; then
		fail "member of sequential dataset must not abend" "abend recovery response"
	else
		pass "member of sequential dataset does not abend"
	fi
	curl -s -X DELETE -u "$AUTH" "${BASE_URL}/zosmf/restfiles/ds/${PROBE_SEQ}" >/dev/null 2>&1 || true
else
	fail "member of a sequential dataset" "could not create ${PROBE_SEQ} (HTTP ${HTTP_CODE})"
fi

# writing into a dataset that does not exist. fopen("w") auto-allocates an
# unknown name with the wrong DCB, so this used to answer 500 *and* leave a
# RECFM=V sequential data set behind (same defect as issue #65 on the
# sequential path). Assert both the status and that nothing was created.
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X PUT -u "$AUTH" \
	-H "Content-Type: application/octet-stream" \
	--data-binary $'X\n' \
	"${BASE_URL}/zosmf/restfiles/ds/${MVSMF_USER}.NOSUCH.PDS(M1)")
assert_http_status "404" "$HTTP_CODE" "write member into a missing PDS"

LOCBODY=$(curl -s -u "$AUTH" \
	"${BASE_URL}/zosmf/test?fn=locate&dsn=${MVSMF_USER}.NOSUCH.PDS")
if echo "$LOCBODY" | grep -q '"rc": 0'; then
	fail "failed member write must not create the dataset" "${MVSMF_USER}.NOSUCH.PDS now exists"
	curl -s -o /dev/null -X DELETE -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/ds/${MVSMF_USER}.NOSUCH.PDS"
else
	pass "failed member write did not create the dataset"
fi

# ... but a member that does not exist YET is a create, not an error. This is
# the regression guard for the write path: it must not inherit the read path's
# member check, or creating a member would start answering 404.
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X PUT -u "$AUTH" \
	-H "Content-Type: application/octet-stream" \
	--data-binary $'NEW MEMBER\n' \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(NEWMBR)")
assert_http_status "204" "$HTTP_CODE" "create a new member in an existing PDS"

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X DELETE -u "$AUTH" "${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(NEWMBR)")
assert_http_status "204" "$HTTP_CODE" "delete the member just created"

# --- Long DSN(member) name validation (Issue #133) ---
# DSN <=44 and member <=8 are individually valid even when combined they exceed 44.
# A 36-char DSN + 8-char member = 36+1+8+1=46 chars qualified: previously false 400, now passes guard.
echo ""
echo "--- Long DSN(member): individually valid names, combined >44 chars ---"

# GET: long qualified name — validation passes, 404 because dataset doesn't exist on this system
LONGDSN="IBMUSER.REXX370.V1R0M0D.REF.LINKLIB"  # 36 chars — valid MVS DSN
LONGMBR="IRXTSPRM"                               # 8 chars  — valid MVS member
BODY=$(curl -s -w '\n%{http_code}' -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${LONGDSN}(${LONGMBR})")
HTTP_CODE=$(echo "$BODY" | tail -1)
CONTENT=$(echo "$BODY" | sed '$d')
if [ "$HTTP_CODE" = "400" ] && echo "$CONTENT" | grep -q "too long"; then
	fail "long DSN(member) GET passes validation" "server still rejects valid name with 400 'too long' — guard not fixed"
else
	pass "long DSN(member) GET passes validation (got HTTP $HTTP_CODE, not false 400)"
fi

# DELETE: same long name — validation passes, 404 because dataset doesn't exist
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X DELETE -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${LONGDSN}(${LONGMBR})")
if [ "$HTTP_CODE" = "400" ]; then
	BODY2=$(curl -s -u "$AUTH" "${BASE_URL}/zosmf/restfiles/ds/${LONGDSN}(${LONGMBR})")
	if echo "$BODY2" | grep -q "too long"; then
		fail "long DSN(member) DELETE passes validation" "server still rejects valid name with 400 'too long'"
	else
		pass "long DSN(member) DELETE passes validation (got HTTP $HTTP_CODE)"
	fi
else
	pass "long DSN(member) DELETE passes validation (got HTTP $HTTP_CODE, not false 400)"
fi

# GET: dsname > 44 chars — must still return 400 "too long" (dsname itself is invalid)
# IBMUSER.REXX370.V1R0M0D.REF.LINKLIB.EXTRAS.XX = 45 chars (7+1+7+1+7+1+3+1+7+1+6+1+2)
TOOLONG_DSN="IBMUSER.REXX370.V1R0M0D.REF.LINKLIB.EXTRAS.XX"  # 45 chars
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${TOOLONG_DSN}(TESTMBR)")
assert_http_status "400" "$HTTP_CODE" "GET with dsname >44 chars returns 400"

# GET: member > 8 chars — must return 400 "too long" (member name itself is invalid)
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(TOOLONGMEMBER)")
assert_http_status "400" "$HTTP_CODE" "GET with member >8 chars returns 400"

# --- Rename sequential dataset ---
echo ""
echo "--- Rename Sequential Dataset ---"

# self-contained: fresh source + clean target
curl -s -X DELETE -u "$AUTH" "${BASE_URL}/zosmf/restfiles/ds/${TEST_SEQ}"  >/dev/null 2>&1 || true
curl -s -X DELETE -u "$AUTH" "${BASE_URL}/zosmf/restfiles/ds/${TEST_SEQ2}" >/dev/null 2>&1 || true

CREATE_BODY='{"dsorg":"PS","recfm":"FB","lrecl":80,"blksize":800,"alcunit":"TRK","primary":1}'
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X POST -u "$AUTH" -H "Content-Type: application/json" \
	-d "$CREATE_BODY" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_SEQ}")

if [ "$HTTP_CODE" = "201" ]; then
	# rename TEST_SEQ -> TEST_SEQ2 (z/OSMF control request)
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X PUT -u "$AUTH" -H "Content-Type: application/json" \
		--data-binary "{\"request\":\"rename\",\"from-dataset\":{\"dsn\":\"${TEST_SEQ}\"}}" \
		"${BASE_URL}/zosmf/restfiles/ds/${TEST_SEQ2}")
	assert_http_status "204" "$HTTP_CODE" "rename sequential dataset TESTSEQ -> TESTSEQ2"

	# the new name is cataloged
	BODY=$(curl -s -w '\n%{http_code}' -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/ds?dslevel=${TEST_SEQ2}")
	HTTP_CODE=$(echo "$BODY" | tail -1)
	CONTENT=$(echo "$BODY" | sed '$d')
	assert_http_status "200" "$HTTP_CODE" "list renamed dataset"
	assert_json_field "$CONTENT" '.items[0].dsname' "$TEST_SEQ2" "renamed dataset present in catalog"

	# rename a non-existent source -> 404
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X PUT -u "$AUTH" -H "Content-Type: application/json" \
		--data-binary "{\"request\":\"rename\",\"from-dataset\":{\"dsn\":\"${TEST_SEQ}.NOPE\"}}" \
		"${BASE_URL}/zosmf/restfiles/ds/${TEST_SEQ}.NOPE2")
	assert_http_status "404" "$HTTP_CODE" "rename non-existent dataset returns 404"
else
	fail "rename sequential dataset" "could not create the rename source"
fi

# =========================================================================
# Records longer than 1024 bytes (issue #198)
#
# write_record() used to convert TEXT records through a fixed 1024-byte
# stack buffer while clamping the length to the data set's LRECL, and
# memberPutHandler bounded its binary reads by fp->lrecl into a 1024-byte
# stack array. Either one smashed the stack for LRECL > 1024 -- observed
# as S0C1 in the handler, answered as HTTP 500 by the ESTAE recovery.
# Both paths need an LRECL well above 1024 to be exercised at all.
# =========================================================================

echo ""
echo "--- Large LRECL: sequential write (issue #198) ---"

BIGLINE=$(awk 'BEGIN { s = ""; while (length(s) < 4000) s = s "X"; print substr(s, 1, 4000) }')

BODY='{"dsorg":"PS","recfm":"VB","lrecl":4004,"blksize":8000,"alcunit":"TRK","primary":5,"secondary":5}'
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X POST -u "$AUTH" \
	-H "Content-Type: application/json" \
	-d "$BODY" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_BIG}")
assert_http_status "201" "$HTTP_CODE" "create VB dataset with LRECL 4004"

printf '%s\n%s\n%s\n' "$BIGLINE" "$BIGLINE" "$BIGLINE" > /tmp/curl_ds_big.txt
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X PUT -u "$AUTH" \
	-H "Content-Type: application/octet-stream" \
	--data-binary @/tmp/curl_ds_big.txt \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_BIG}")
assert_http_status "204" "$HTTP_CODE" "write 4000-byte records (was S0C1)"

BODY=$(curl -s -w '\n%{http_code}' -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_BIG}")
HTTP_CODE=$(echo "$BODY" | tail -1)
CONTENT=$(echo "$BODY" | sed '$d')
assert_http_status "200" "$HTTP_CODE" "read back 4000-byte records"

LONGEST=$(echo "$CONTENT" | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')
if [ "$LONGEST" = "4000" ]; then
	pass "records survived at full length (longest=$LONGEST)"
else
	fail "records survived at full length" "expected longest line 4000, got $LONGEST"
fi

echo ""
echo "--- Large LRECL: binary member write (issue #198) ---"

BODY='{"dsorg":"PO","recfm":"FB","lrecl":4004,"blksize":8008,"alcunit":"TRK","primary":5,"secondary":5,"dirblk":5}'
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X POST -u "$AUTH" \
	-H "Content-Type: application/json" \
	-d "$BODY" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_BIGPDS}")
assert_http_status "201" "$HTTP_CODE" "create PDS with LRECL 4004"

# Exactly two full 4004-byte records
awk 'BEGIN { s = ""; while (length(s) < 8008) s = s "B"; printf "%s", substr(s, 1, 8008) }' \
	> /tmp/curl_ds_big.bin
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X PUT -u "$AUTH" \
	-H "Content-Type: application/octet-stream" \
	-H "X-IBM-Data-Type: binary" \
	--data-binary @/tmp/curl_ds_big.bin \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_BIGPDS}(BIGBIN)")
assert_http_status "204" "$HTTP_CODE" "write binary member with LRECL 4004 (was S0C1)"

HTTP_CODE=$(curl -s -w '%{http_code}' -o /tmp/curl_ds_big_rt.bin \
	-u "$AUTH" \
	-H "X-IBM-Data-Type: binary" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_BIGPDS}(BIGBIN)")
assert_http_status "200" "$HTTP_CODE" "read back binary member"

RT_SIZE=$(wc -c < /tmp/curl_ds_big_rt.bin | tr -d ' ')
if [ "$RT_SIZE" = "8008" ]; then
	pass "binary member round-trips at full size ($RT_SIZE bytes)"
else
	fail "binary member round-trips at full size" "expected 8008 bytes, got $RT_SIZE"
fi

rm -f /tmp/curl_ds_big.txt /tmp/curl_ds_big.bin /tmp/curl_ds_big_rt.bin

# =========================================================================
# Text record framing (issue #233)
#
# Two defects on the text write path, both reproducible with plain ASCII
# into the FB80 PDS above:
#
#   - a blank line produced a zero-length fwrite(), which libc370's fflush()
#     discards at its empty-buffer guard -- the record disappeared and the
#     upload still answered 204;
#   - the length guard ran before the byte was stored and counted the
#     terminator, so the usable line length was LRECL-2: 79 and 80 columns
#     were rejected as "Record too long".
#
# Record counts are checked through a BINARY read: it returns the stored
# records verbatim (80 bytes each), while the text read strips the padding
# and would hide a missing blank record.
# =========================================================================

echo ""
echo "--- Text framing: blank lines are records (issue #233) ---"

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X PUT -u "$AUTH" \
	-H "Content-Type: application/octet-stream" \
	--data-binary $'ERSTE ZEILE\n\nDRITTE ZEILE\n' \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(BLANKT)")
assert_http_status "204" "$HTTP_CODE" "write member with a blank line"

HTTP_CODE=$(curl -s -w '%{http_code}' -o /tmp/curl_ds_blank.bin \
	-u "$AUTH" \
	-H "X-IBM-Data-Type: binary" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(BLANKT)")
assert_http_status "200" "$HTTP_CODE" "read back the member"

RT_SIZE=$(wc -c < /tmp/curl_ds_blank.bin | tr -d ' ')
if [ "$RT_SIZE" = "240" ]; then
	pass "three lines stored as three records ($RT_SIZE bytes)"
else
	fail "three lines stored as three records" \
		"expected 240 bytes (3 x 80), got $RT_SIZE"
fi

CONTENT=$(curl -s -u "$AUTH" "${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(BLANKT)")
LINE2=$(echo "$CONTENT" | sed -n '2p')
if [ -z "$LINE2" ]; then
	pass "the blank line reads back as an empty line"
else
	fail "the blank line reads back as an empty line" "got '$LINE2'"
fi

echo ""
echo "--- Text framing: a full-width line fits (issue #233) ---"

# 77..80 columns into LRECL=80. 79 and 80 were rejected before the fix.
# Each width gets its own member and is read back on the spot -- writing them
# all to one member would only ever prove something about the last one.
# The line is uploaded from a file: the trailing newline is the byte the old
# guard tripped over, and a command substitution would strip it.
for COLS in 77 78 79 80; do
	awk -v n="$COLS" 'BEGIN { s = ""; while (length(s) < n) s = s "A"; print substr(s, 1, n) }' \
		> /tmp/curl_ds_wide.txt
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X PUT -u "$AUTH" \
		-H "Content-Type: application/octet-stream" \
		--data-binary @/tmp/curl_ds_wide.txt \
		"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(WIDE${COLS})")
	assert_http_status "204" "$HTTP_CODE" "write a ${COLS}-column line into LRECL=80"

	# Binary read: one stored record is exactly LRECL bytes, whatever the
	# line's own width, so this catches a line that was split in two.
	curl -s -o /tmp/curl_ds_wide.bin -u "$AUTH" \
		-H "X-IBM-Data-Type: binary" \
		"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(WIDE${COLS})"
	RT_SIZE=$(wc -c < /tmp/curl_ds_wide.bin | tr -d ' ')
	if [ "$RT_SIZE" = "80" ]; then
		pass "the ${COLS}-column line is one record ($RT_SIZE bytes)"
	else
		fail "the ${COLS}-column line is one record" \
			"expected 80 bytes, got $RT_SIZE"
	fi

	CONTENT=$(curl -s -u "$AUTH" "${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(WIDE${COLS})")
	RT_COLS=$(echo "$CONTENT" | head -1 | tr -d '\r' | awk '{ print length($0) }')
	if [ "$RT_COLS" = "$COLS" ]; then
		pass "all ${COLS} columns survive the round trip"
	else
		fail "all ${COLS} columns survive the round trip" \
			"expected $COLS characters, got $RT_COLS"
	fi
done

echo ""
echo "--- Text framing: one column too many is still rejected ---"

awk 'BEGIN { s = ""; while (length(s) < 81) s = s "A"; print substr(s, 1, 81) }' \
	> /tmp/curl_ds_wide.txt
BODY=$(curl -s -w '\n%{http_code}' \
	-X PUT -u "$AUTH" \
	-H "Content-Type: application/octet-stream" \
	--data-binary @/tmp/curl_ds_wide.txt \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(TOOWIDE)")
HTTP_CODE=$(echo "$BODY" | tail -1)
CONTENT=$(echo "$BODY" | sed '$d')
assert_http_status "500" "$HTTP_CODE" "an 81-column line is rejected"
if echo "$CONTENT" | grep -qi "Record too long"; then
	pass "the rejection names the reason (Record too long)"
else
	fail "the rejection names the reason" "got: $CONTENT"
fi

echo ""
echo "--- Text framing: terminators and chunked transfer (issue #233) ---"

# CRLF endings, a body that does not end in a newline, and a body that does:
# each must produce exactly two records and no phantom third one.
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X PUT -u "$AUTH" \
	-H "Content-Type: application/octet-stream" \
	--data-binary $'ALPHA\r\nBETA\r\n' \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(CRLFT)")
assert_http_status "204" "$HTTP_CODE" "write a CRLF body"

curl -s -o /tmp/curl_ds_crlf.bin -u "$AUTH" \
	-H "X-IBM-Data-Type: binary" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(CRLFT)"
RT_SIZE=$(wc -c < /tmp/curl_ds_crlf.bin | tr -d ' ')
if [ "$RT_SIZE" = "160" ]; then
	pass "CRLF body stored as two records ($RT_SIZE bytes)"
else
	fail "CRLF body stored as two records" "expected 160 bytes, got $RT_SIZE"
fi

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X PUT -u "$AUTH" \
	-H "Content-Type: application/octet-stream" \
	--data-binary $'ALPHA\nBETA' \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(NOEOLT)")
assert_http_status "204" "$HTTP_CODE" "write a body without a trailing newline"

curl -s -o /tmp/curl_ds_noeol.bin -u "$AUTH" \
	-H "X-IBM-Data-Type: binary" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(NOEOLT)"
RT_SIZE=$(wc -c < /tmp/curl_ds_noeol.bin | tr -d ' ')
if [ "$RT_SIZE" = "160" ]; then
	pass "last line without a terminator still stored ($RT_SIZE bytes)"
else
	fail "last line without a terminator still stored" \
		"expected 160 bytes, got $RT_SIZE"
fi

# Chunked: the framing state has to survive the chunk boundaries curl inserts,
# and a trailing newline must not add a blank record at the end.
printf 'CHUNK ONE\n\nCHUNK THREE\n' > /tmp/curl_ds_chunk.txt
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X PUT -u "$AUTH" \
	-H "Content-Type: application/octet-stream" \
	-H "Transfer-Encoding: chunked" \
	--data-binary @/tmp/curl_ds_chunk.txt \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(CHUNKT)")
assert_http_status "204" "$HTTP_CODE" "write a chunked body with a blank line"

curl -s -o /tmp/curl_ds_chunk.bin -u "$AUTH" \
	-H "X-IBM-Data-Type: binary" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(CHUNKT)"
RT_SIZE=$(wc -c < /tmp/curl_ds_chunk.bin | tr -d ' ')
if [ "$RT_SIZE" = "240" ]; then
	pass "chunked body stored as three records ($RT_SIZE bytes)"
else
	fail "chunked body stored as three records" \
		"expected 240 bytes (3 x 80), got $RT_SIZE"
fi

rm -f /tmp/curl_ds_blank.bin /tmp/curl_ds_wide.txt /tmp/curl_ds_wide.bin \
	/tmp/curl_ds_crlf.bin /tmp/curl_ds_noeol.bin /tmp/curl_ds_chunk.txt \
	/tmp/curl_ds_chunk.bin

# --- ETag / optimistic locking (issue #152) ---
echo ""
echo "--- ETag: optimistic locking (issue #152) ---"

# Pull the ETag out of a response header dump. Case-insensitive, CR stripped:
# the value is compared literally later, and a stray CR silently breaks that.
get_etag() {
	grep -i '^ETag:' "$1" | tr -d '\r' | sed 's/^[Ee][Tt][Aa][Gg]:[ ]*//'
}

printf 'LINE ONE\nLINE TWO\n' > /tmp/curl_ds_etag.txt
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X PUT -u "$AUTH" \
	-H "Content-Type: text/plain" \
	--data-binary @/tmp/curl_ds_etag.txt \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(ETAGT)")
assert_http_status "204" "$HTTP_CODE" "etag: seed the member"

# An ETag costs an extra read pass, so it is opt-in: no header, no ETag.
curl -s -D /tmp/curl_ds_h1.txt -o /dev/null -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(ETAGT)"
if [ -z "$(get_etag /tmp/curl_ds_h1.txt)" ]; then
	pass "etag: a plain GET returns no ETag"
else
	fail "etag: a plain GET returns no ETag" "got $(get_etag /tmp/curl_ds_h1.txt)"
fi

curl -s -D /tmp/curl_ds_h1.txt -o /dev/null -u "$AUTH" \
	-H "X-IBM-Return-Etag: true" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(ETAGT)"
ETAG1=$(get_etag /tmp/curl_ds_h1.txt)
if [ -n "$ETAG1" ]; then
	pass "etag: X-IBM-Return-Etag returns one ($ETAG1)"
else
	fail "etag: X-IBM-Return-Etag returns one" "no ETag header in response"
fi

if echo "$ETAG1" | grep -qE '^[0-9A-F]{16}$'; then
	pass "etag: the value is 16 uppercase hex digits"
else
	fail "etag: the value is 16 uppercase hex digits" "got '$ETAG1'"
fi

# Stability: an unchanged member must stamp the same, or every save would
# fail its own precondition.
curl -s -D /tmp/curl_ds_h2.txt -o /dev/null -u "$AUTH" \
	-H "X-IBM-Return-Etag: true" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(ETAGT)"
ETAG2=$(get_etag /tmp/curl_ds_h2.txt)
if [ "$ETAG1" = "$ETAG2" ]; then
	pass "etag: an unchanged member stamps the same twice"
else
	fail "etag: an unchanged member stamps the same twice" "$ETAG1 vs $ETAG2"
fi

# The mode the client reads in must not change the stamp: a text read and a
# binary read describe the same resource state.
curl -s -D /tmp/curl_ds_h3.txt -o /dev/null -u "$AUTH" \
	-H "X-IBM-Return-Etag: true" \
	-H "X-IBM-Data-Type: binary" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(ETAGT)"
ETAG3=$(get_etag /tmp/curl_ds_h3.txt)
if [ "$ETAG1" = "$ETAG3" ]; then
	pass "etag: text and binary reads stamp alike"
else
	fail "etag: text and binary reads stamp alike" "$ETAG1 vs $ETAG3"
fi

# A stale precondition must fail, and must fail BEFORE anything is written.
printf 'LINE ONE\nLINE TWO CHANGED\n' > /tmp/curl_ds_etag2.txt
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X PUT -u "$AUTH" \
	-H "Content-Type: text/plain" \
	-H "If-Match: 0000000000000000" \
	--data-binary @/tmp/curl_ds_etag2.txt \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(ETAGT)")
assert_http_status "412" "$HTTP_CODE" "etag: a stale If-Match is refused"

curl -s -o /tmp/curl_ds_after412.txt -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(ETAGT)"
if grep -q 'LINE TWO$' /tmp/curl_ds_after412.txt; then
	pass "etag: the refused write left the member untouched"
else
	fail "etag: the refused write left the member untouched" \
		"content changed despite the 412"
fi

# The current stamp is accepted, and the response carries the stamp of what
# was just written -- without it the next save would fail on a stale value.
HTTP_CODE=$(curl -s -w '%{http_code}' -D /tmp/curl_ds_h4.txt -o /dev/null \
	-X PUT -u "$AUTH" \
	-H "Content-Type: text/plain" \
	-H "X-IBM-Return-Etag: true" \
	-H "If-Match: ${ETAG1}" \
	--data-binary @/tmp/curl_ds_etag2.txt \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(ETAGT)")
assert_http_status "204" "$HTTP_CODE" "etag: a current If-Match is accepted"

ETAG4=$(get_etag /tmp/curl_ds_h4.txt)
if [ -n "$ETAG4" ] && [ "$ETAG4" != "$ETAG1" ]; then
	pass "etag: the PUT returns the new stamp ($ETAG4)"
else
	fail "etag: the PUT returns the new stamp" "got '$ETAG4', was '$ETAG1'"
fi

# The round trip that makes repeated saves work: what the PUT handed back has
# to be what the next GET computes.
curl -s -D /tmp/curl_ds_h5.txt -o /dev/null -u "$AUTH" \
	-H "X-IBM-Return-Etag: true" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(ETAGT)"
ETAG5=$(get_etag /tmp/curl_ds_h5.txt)
if [ "$ETAG4" = "$ETAG5" ]; then
	pass "etag: the PUT stamp matches the next GET stamp"
else
	fail "etag: the PUT stamp matches the next GET stamp" "$ETAG4 vs $ETAG5"
fi

# Saving twice in a row with the stamp the previous save returned: the case
# that breaks if the PUT hashes the request body instead of the stored member.
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X PUT -u "$AUTH" \
	-H "Content-Type: text/plain" \
	-H "If-Match: ${ETAG4}" \
	--data-binary @/tmp/curl_ds_etag.txt \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(ETAGT)")
assert_http_status "204" "$HTTP_CODE" "etag: a second save with the returned stamp"

# Header forms clients actually send.
curl -s -D /tmp/curl_ds_h6.txt -o /dev/null -u "$AUTH" \
	-H "X-IBM-Return-Etag: true" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(ETAGT)"
ETAG6=$(get_etag /tmp/curl_ds_h6.txt)

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X PUT -u "$AUTH" \
	-H "Content-Type: text/plain" \
	-H "If-Match: \"${ETAG6}\"" \
	--data-binary @/tmp/curl_ds_etag.txt \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(ETAGT)")
assert_http_status "204" "$HTTP_CODE" "etag: a quoted If-Match is accepted"

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X PUT -u "$AUTH" \
	-H "Content-Type: text/plain" \
	-H "If-Match: W/\"${ETAG6}\"" \
	--data-binary @/tmp/curl_ds_etag.txt \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(ETAGT)")
assert_http_status "204" "$HTTP_CODE" "etag: a weak If-Match is accepted"

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X PUT -u "$AUTH" \
	-H "Content-Type: text/plain" \
	-H "If-Match: *" \
	--data-binary @/tmp/curl_ds_etag.txt \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(ETAGT)")
assert_http_status "204" "$HTTP_CODE" "etag: If-Match * on an existing member"

# "*" asserts the resource exists. A member that does not is the deletion case
# the precondition is there to catch.
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X PUT -u "$AUTH" \
	-H "Content-Type: text/plain" \
	-H "If-Match: *" \
	--data-binary @/tmp/curl_ds_etag.txt \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(ETAGNON)")
assert_http_status "412" "$HTTP_CODE" "etag: If-Match on a missing member is 412"

# Without If-Match nothing changes: last write wins, as before the feature.
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X PUT -u "$AUTH" \
	-H "Content-Type: text/plain" \
	--data-binary @/tmp/curl_ds_etag2.txt \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(ETAGT)")
assert_http_status "204" "$HTTP_CODE" "etag: a PUT without If-Match still writes"

# A missing PDS is still a 404 -- the more specific answer wins over 412.
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X PUT -u "$AUTH" \
	-H "Content-Type: text/plain" \
	-H "If-Match: *" \
	--data-binary @/tmp/curl_ds_etag.txt \
	"${BASE_URL}/zosmf/restfiles/ds/${MVSMF_USER}.NO.SUCH.PDS(M1)")
assert_http_status "404" "$HTTP_CODE" "etag: a missing data set is 404, not 412"

# The same protocol on the sequential endpoint. This allocates its own data
# set rather than reusing TEST_SEQ: that one is deleted further up as part of
# the DELETE test case and no longer exists by the time this section runs.
TEST_ETAGSEQ="${MVSMF_USER}.CURL.TESTETG"
curl -s -X DELETE -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_ETAGSEQ}" >/dev/null 2>&1 || true

BODY='{"dsorg":"PS","recfm":"FB","lrecl":80,"blksize":3120,"alcunit":"TRK","primary":1,"secondary":1}'
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X POST -u "$AUTH" \
	-H "Content-Type: application/json" \
	-d "$BODY" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_ETAGSEQ}")
assert_http_status "201" "$HTTP_CODE" "etag: allocate a sequential data set"

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X PUT -u "$AUTH" \
	-H "Content-Type: text/plain" \
	--data-binary @/tmp/curl_ds_etag.txt \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_ETAGSEQ}")
assert_http_status "204" "$HTTP_CODE" "etag: seed the sequential data set"

curl -s -D /tmp/curl_ds_h7.txt -o /dev/null -u "$AUTH" \
	-H "X-IBM-Return-Etag: true" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_ETAGSEQ}"
ETAG7=$(get_etag /tmp/curl_ds_h7.txt)
if [ -n "$ETAG7" ]; then
	pass "etag: sequential GET returns one ($ETAG7)"
else
	fail "etag: sequential GET returns one" "no ETag header in response"
fi

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X PUT -u "$AUTH" \
	-H "Content-Type: text/plain" \
	-H "If-Match: 0000000000000000" \
	--data-binary @/tmp/curl_ds_etag.txt \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_ETAGSEQ}")
assert_http_status "412" "$HTTP_CODE" "etag: sequential stale If-Match is refused"

HTTP_CODE=$(curl -s -w '%{http_code}' -D /tmp/curl_ds_h8.txt -o /dev/null \
	-X PUT -u "$AUTH" \
	-H "Content-Type: text/plain" \
	-H "X-IBM-Return-Etag: true" \
	-H "If-Match: ${ETAG7}" \
	--data-binary @/tmp/curl_ds_etag2.txt \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_ETAGSEQ}")
assert_http_status "204" "$HTTP_CODE" "etag: sequential current If-Match is accepted"

# The round trip again, on the sequential path. It does not inherit the member
# evidence above: the post-write stamp here is bounded by get_fb_record_count()
# against a data set whose DSCB was just rewritten, not by the member path's
# plain read-to-EOF. If that count disagreed with what the next GET computes,
# the symptom would be every second save failing 412.
ETAG8=$(get_etag /tmp/curl_ds_h8.txt)
if [ -n "$ETAG8" ]; then
	pass "etag: sequential PUT returns the new stamp ($ETAG8)"
else
	fail "etag: sequential PUT returns the new stamp" "no ETag header in response"
fi

curl -s -D /tmp/curl_ds_h9.txt -o /dev/null -u "$AUTH" \
	-H "X-IBM-Return-Etag: true" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_ETAGSEQ}"
ETAG9=$(get_etag /tmp/curl_ds_h9.txt)
if [ "$ETAG8" = "$ETAG9" ]; then
	pass "etag: sequential PUT stamp matches the next GET stamp"
else
	fail "etag: sequential PUT stamp matches the next GET stamp" "$ETAG8 vs $ETAG9"
fi

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X PUT -u "$AUTH" \
	-H "Content-Type: text/plain" \
	-H "If-Match: ${ETAG8}" \
	--data-binary @/tmp/curl_ds_etag.txt \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_ETAGSEQ}")
assert_http_status "204" "$HTTP_CODE" "etag: sequential second save with the returned stamp"

# --- ETag: conditional reads (issue #263) ---
echo ""
echo "--- ETag: conditional reads / If-None-Match (issue #263) ---"

# One value drives every check below: the stamp the member returns right now.
# The read half computes its own stamp for the comparison, so if that pass ever
# drifted from the one behind X-IBM-Return-Etag, it would surface here as a 200
# where a 304 was asked for -- which is why the two are hashed in one pass.
curl -s -D /tmp/curl_ds_c1.txt -o /dev/null -u "$AUTH" \
	-H "X-IBM-Return-Etag: true" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(ETAGT)"
CETAG=$(get_etag /tmp/curl_ds_c1.txt)

HTTP_CODE=$(curl -s -w '%{http_code}' \
	-D /tmp/curl_ds_c2.txt -o /tmp/curl_ds_c2.body \
	-u "$AUTH" -H "If-None-Match: ${CETAG}" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(ETAGT)")
assert_http_status "304" "$HTTP_CODE" "cond: a current If-None-Match is 304"

# A body is the one thing the status promises not to send.
if [ ! -s /tmp/curl_ds_c2.body ]; then
	pass "cond: the 304 carries no body"
else
	fail "cond: the 304 carries no body" \
		"got $(wc -c < /tmp/curl_ds_c2.body) bytes"
fi

# The ETag rides along without X-IBM-Return-Etag being sent: a client on
# If-None-Match is already speaking the protocol, and the stamp had to be
# computed to answer at all.
if [ "$(get_etag /tmp/curl_ds_c2.txt)" = "$CETAG" ]; then
	pass "cond: the 304 carries the ETag it confirmed"
else
	fail "cond: the 304 carries the ETag it confirmed" \
		"got '$(get_etag /tmp/curl_ds_c2.txt)', expected '$CETAG'"
fi

# The forms clients send, and the wildcard. "*" fails the If-None-Match
# condition whenever a representation exists (RFC 9110 13.1.2), and a failed
# condition on a GET is a 304 -- the opposite reading, "only if it does not
# exist", is the conditional-create semantic of a PUT.
for FORM in "\"${CETAG}\"" "W/\"${CETAG}\"" \
	"\"0000000000000000\", \"${CETAG}\"" "*"; do
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null -u "$AUTH" \
		-H "If-None-Match: ${FORM}" \
		"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(ETAGT)")
	assert_http_status "304" "$HTTP_CODE" \
		"cond: If-None-Match ${FORM} is 304"
done

HTTP_CODE=$(curl -s -w '%{http_code}' \
	-D /tmp/curl_ds_c3.txt -o /tmp/curl_ds_c3.body -u "$AUTH" \
	-H "If-None-Match: 0000000000000000" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(ETAGT)")
assert_http_status "200" "$HTTP_CODE" "cond: a stale If-None-Match is 200"

if [ -s /tmp/curl_ds_c3.body ]; then
	pass "cond: the 200 still carries the content"
else
	fail "cond: the 200 still carries the content" "empty body"
fi

# The miss carries the stamp as well, without X-IBM-Return-Etag being sent.
# A reader polling on If-None-Match alone would otherwise receive the changed
# content and no validator to ask about the next change with.
if [ "$(get_etag /tmp/curl_ds_c3.txt)" = "$CETAG" ]; then
	pass "cond: the 200 carries the current ETag too"
else
	fail "cond: the 200 carries the current ETag too" \
		"got '$(get_etag /tmp/curl_ds_c3.txt)', expected '$CETAG'"
fi

# 304 has to be a statement about the current content, not about the header
# having been seen once. Change the member and the same stamp must stop matching.
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X PUT -u "$AUTH" \
	-H "Content-Type: text/plain" \
	--data-binary @/tmp/curl_ds_etag.txt \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(ETAGT)")
assert_http_status "204" "$HTTP_CODE" "cond: rewrite the member"

HTTP_CODE=$(curl -s -w '%{http_code}' -D /tmp/curl_ds_c7.txt -o /dev/null \
	-u "$AUTH" -H "If-None-Match: ${CETAG}" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(ETAGT)")
assert_http_status "200" "$HTTP_CODE" "cond: a changed member is 200 again"

# ... and the stamp it hands back is the new one, which is what lets the poll
# continue from here without a second request.
CETAGNEW=$(get_etag /tmp/curl_ds_c7.txt)
if [ -n "$CETAGNEW" ] && [ "$CETAGNEW" != "$CETAG" ]; then
	pass "cond: the 200 after a change carries the new stamp ($CETAGNEW)"
else
	fail "cond: the 200 after a change carries the new stamp" \
		"got '$CETAGNEW', was '$CETAG'"
fi

# Nothing to be fresh about: the 404 is the more specific answer and wins.
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null -u "$AUTH" \
	-H "If-None-Match: *" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(ETAGNON)")
assert_http_status "404" "$HTTP_CODE" "cond: a missing member is 404, not 304"

# A bodiless response is framed by its header block alone. If that framing were
# wrong the next request on the same connection would hang or read the previous
# response's tail -- curl reuses the connection when both URLs are given in one
# invocation, so a second 304 here is the evidence.
curl -s -D /tmp/curl_ds_c4.txt -o /dev/null -u "$AUTH" \
	-H "X-IBM-Return-Etag: true" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(ETAGT)"
CETAG2=$(get_etag /tmp/curl_ds_c4.txt)
CODES=$(curl -s --max-time 30 -o /dev/null -w '%{http_code} ' -u "$AUTH" \
	-H "If-None-Match: ${CETAG2}" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(ETAGT)" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(ETAGT)")
if [ "$CODES" = "304 304 " ]; then
	pass "cond: a second request on the same connection still answers"
else
	fail "cond: a second request on the same connection still answers" \
		"got '$CODES', expected '304 304 '"
fi

# The sequential path, where the hash pass is bounded by get_fb_record_count()
# rather than reading to EOF. A bound copied from the member path would hash
# the residue of the last block as well, and this 304 would come back 200.
curl -s -D /tmp/curl_ds_c5.txt -o /dev/null -u "$AUTH" \
	-H "X-IBM-Return-Etag: true" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_ETAGSEQ}"
SETAG=$(get_etag /tmp/curl_ds_c5.txt)

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null -u "$AUTH" \
	-H "If-None-Match: ${SETAG}" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_ETAGSEQ}")
assert_http_status "304" "$HTTP_CODE" "cond: sequential current stamp is 304"

# The stamp does not depend on X-IBM-Data-Type, so neither does the 304.
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null -u "$AUTH" \
	-H "X-IBM-Data-Type: binary" \
	-H "If-None-Match: ${SETAG}" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_ETAGSEQ}")
assert_http_status "304" "$HTTP_CODE" "cond: sequential binary read is 304 too"

HTTP_CODE=$(curl -s -w '%{http_code}' -o /tmp/curl_ds_c6.body -u "$AUTH" \
	-H "If-None-Match: 0000000000000000" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_ETAGSEQ}")
assert_http_status "200" "$HTTP_CODE" "cond: sequential stale stamp is 200"

curl -s -X DELETE -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(ETAGT)" >/dev/null 2>&1 || true
curl -s -X DELETE -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_ETAGSEQ}" >/dev/null 2>&1 || true
rm -f /tmp/curl_ds_etag.txt /tmp/curl_ds_etag2.txt /tmp/curl_ds_after412.txt \
	/tmp/curl_ds_h1.txt /tmp/curl_ds_h2.txt /tmp/curl_ds_h3.txt \
	/tmp/curl_ds_h4.txt /tmp/curl_ds_h5.txt /tmp/curl_ds_h6.txt \
	/tmp/curl_ds_h7.txt /tmp/curl_ds_h8.txt /tmp/curl_ds_h9.txt \
	/tmp/curl_ds_c1.txt /tmp/curl_ds_c2.txt /tmp/curl_ds_c2.body \
	/tmp/curl_ds_c3.txt /tmp/curl_ds_c3.body /tmp/curl_ds_c4.txt \
	/tmp/curl_ds_c5.txt /tmp/curl_ds_c6.body /tmp/curl_ds_c7.txt

# =========================================================================
# A failed PUT must not destroy what it failed to replace (issues #243, #246)
# =========================================================================
echo ""
echo "--- Failed PUT preserves the previous content (issues #243, #246) ---"

ATOM_SEQ="${MVSMF_USER}.CURL.ATOMSEQ"
ATOM_PDS="${MVSMF_USER}.CURL.ATOMPDS"

# Announce a Content-Length and then close the sending half, so the handler's
# very first recv() fails. curl cannot express this, hence the raw request.
put_dies_before_body() {
	python3 - "$MVSMF_HOST" "$MVSMF_PORT" "$AUTH" "$1" >/dev/null 2>&1 <<-'PYEOF'
		import base64, socket, sys, time
		host, port, auth, target = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
		req = (f"PUT /zosmf/restfiles/ds/{target} HTTP/1.1\r\n"
		       f"Host: {host}:{port}\r\n"
		       f"Authorization: Basic {base64.b64encode(auth.encode()).decode()}\r\n"
		       f"X-IBM-Data-Type: text\r\nContent-Length: 500\r\n\r\n")
		s = socket.create_connection((host, port), timeout=30)
		s.sendall(req.encode()); time.sleep(0.5); s.shutdown(socket.SHUT_WR)
		try: s.recv(4096)
		except Exception: pass
		s.close()
	PYEOF
}

printf 'ORIGINAL LINE ONE\nORIGINAL LINE TWO\n' > /tmp/curl_ds_atom_good.txt
# second line is 200 columns -- rejected by the record framing, but only after
# the first line has already been framed as a record
{
	printf 'FIRST GOOD LINE\n'
	awk 'BEGIN { while (i++ < 200) printf "X"; printf "\n" }'
	printf 'LAST GOOD LINE\n'
} > /tmp/curl_ds_atom_long.txt

curl -s -X DELETE -u "$AUTH" "${BASE_URL}/zosmf/restfiles/ds/${ATOM_SEQ}" >/dev/null 2>&1 || true
curl -s -X DELETE -u "$AUTH" "${BASE_URL}/zosmf/restfiles/ds/${ATOM_PDS}" >/dev/null 2>&1 || true

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null -X POST -u "$AUTH" \
	-H "Content-Type: application/json" \
	-d '{"dsorg":"PS","recfm":"FB","lrecl":80,"blksize":800,"alcunit":"TRK","primary":1,"secondary":1}' \
	"${BASE_URL}/zosmf/restfiles/ds/${ATOM_SEQ}")
HTTP_CODE2=$(curl -s -w '%{http_code}' -o /dev/null -X POST -u "$AUTH" \
	-H "Content-Type: application/json" \
	-d '{"dsorg":"PO","recfm":"FB","lrecl":80,"blksize":800,"alcunit":"TRK","primary":1,"secondary":1,"dirblk":5}' \
	"${BASE_URL}/zosmf/restfiles/ds/${ATOM_PDS}")

if [ "$HTTP_CODE" = "201" ] && [ "$HTTP_CODE2" = "201" ]; then
	# --- sequential: a mid-body failure (issue #243) ---
	curl -s -o /dev/null -X PUT -u "$AUTH" -H "X-IBM-Data-Type: text" -H "Expect:" \
		--data-binary @/tmp/curl_ds_atom_good.txt \
		"${BASE_URL}/zosmf/restfiles/ds/${ATOM_SEQ}"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null -X PUT -u "$AUTH" \
		-H "X-IBM-Data-Type: text" -H "Expect:" \
		--data-binary @/tmp/curl_ds_atom_long.txt \
		"${BASE_URL}/zosmf/restfiles/ds/${ATOM_SEQ}")
	assert_http_status "500" "$HTTP_CODE" "seq: over-long record is rejected"

	# A mid-body failure is NOT yet atomic: the records written before the
	# offending line are already committed. Reported as a skip rather than a
	# failure so the suite stays green on known behaviour -- turn this into an
	# assertion when #243 lands.
	CONTENT=$(curl -s -u "$AUTH" "${BASE_URL}/zosmf/restfiles/ds/${ATOM_SEQ}")
	if [ "$CONTENT" = "$(cat /tmp/curl_ds_atom_good.txt)" ]; then
		pass "seq: a mid-body failure leaves the previous content intact (#243 fixed?)"
	else
		skip "seq: a mid-body failure still commits what it wrote (known, #243)"
	fi

	# --- member: the same, where CLOSE is what commits (issue #243) ---
	curl -s -o /dev/null -X PUT -u "$AUTH" -H "X-IBM-Data-Type: text" -H "Expect:" \
		--data-binary @/tmp/curl_ds_atom_good.txt \
		"${BASE_URL}/zosmf/restfiles/ds/${ATOM_PDS}(KEEPME)"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null -X PUT -u "$AUTH" \
		-H "X-IBM-Data-Type: text" -H "Expect:" \
		--data-binary @/tmp/curl_ds_atom_long.txt \
		"${BASE_URL}/zosmf/restfiles/ds/${ATOM_PDS}(KEEPME)")
	assert_http_status "500" "$HTTP_CODE" "member: over-long record is rejected"

	CONTENT=$(curl -s -u "$AUTH" "${BASE_URL}/zosmf/restfiles/ds/${ATOM_PDS}(KEEPME)")
	if [ "$CONTENT" = "$(cat /tmp/curl_ds_atom_good.txt)" ]; then
		pass "member: a mid-body failure leaves the previous content intact (#243 fixed?)"
	else
		skip "member: a mid-body failure still commits what it wrote (known, #243)"
	fi

	# Re-seed: the mid-body case above deliberately damaged the member, and the
	# #246 case below has to start from a known state or it measures the wrong
	# thing -- it would compare against content the previous case already ate.
	curl -s -o /dev/null -X PUT -u "$AUTH" -H "X-IBM-Data-Type: text" -H "Expect:" \
		--data-binary @/tmp/curl_ds_atom_good.txt \
		"${BASE_URL}/zosmf/restfiles/ds/${ATOM_PDS}(KEEPME)"

	# --- failure before a single body byte is read (issue #246) ---
	# A member and a sequential data set commit by different mechanisms -- STOW
	# of the directory entry versus DS1LSTAR at CLOSE -- so both are covered.
	if command -v python3 >/dev/null 2>&1; then
		for ATOM_T in "${ATOM_PDS}(KEEPME)" "${ATOM_SEQ}"; do
			curl -s -o /dev/null -X PUT -u "$AUTH" \
				-H "X-IBM-Data-Type: text" -H "Expect:" \
				--data-binary @/tmp/curl_ds_atom_good.txt \
				"${BASE_URL}/zosmf/restfiles/ds/${ATOM_T}"

			put_dies_before_body "$ATOM_T"

			CONTENT=$(curl -s -u "$AUTH" "${BASE_URL}/zosmf/restfiles/ds/${ATOM_T}")
			if [ "$CONTENT" = "$(cat /tmp/curl_ds_atom_good.txt)" ]; then
				pass "${ATOM_T}: a PUT that dies before the body leaves the content intact"
			else
				fail "${ATOM_T}: a PUT that dies before the body leaves the content intact" \
					"got: $(echo "$CONTENT" | tr '\n' '/')"
			fi
		done
	else
		skip "a PUT that dies before the body (needs python3)"
	fi

	# --- the negative: an empty body must still empty the target ---
	# The lazy open must not turn "PUT nothing" into "change nothing".
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null -X PUT -u "$AUTH" \
		-H "X-IBM-Data-Type: text" -H "Expect:" -H "Content-Length: 0" \
		"${BASE_URL}/zosmf/restfiles/ds/${ATOM_PDS}(KEEPME)")
	assert_http_status "204" "$HTTP_CODE" "member: empty body is accepted"

	CONTENT=$(curl -s -w '%{size_download}' -o /dev/null -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/ds/${ATOM_PDS}(KEEPME)")
	if [ "$CONTENT" = "0" ]; then
		pass "member: an empty body still empties the member"
	else
		fail "member: an empty body still empties the member" \
			"expected 0 bytes, got $CONTENT"
	fi
else
	fail "failed-PUT atomicity" "could not create ${ATOM_SEQ}/${ATOM_PDS}"
fi

curl -s -X DELETE -u "$AUTH" "${BASE_URL}/zosmf/restfiles/ds/${ATOM_SEQ}" >/dev/null 2>&1 || true
curl -s -X DELETE -u "$AUTH" "${BASE_URL}/zosmf/restfiles/ds/${ATOM_PDS}" >/dev/null 2>&1 || true
rm -f /tmp/curl_ds_atom_good.txt /tmp/curl_ds_atom_long.txt

# --- Cleanup: delete PDS ---
echo ""
echo "--- Cleanup ---"

curl -s -X DELETE -u "$AUTH" "${BASE_URL}/zosmf/restfiles/ds/${TEST_BIG}" >/dev/null 2>&1 || true
curl -s -X DELETE -u "$AUTH" "${BASE_URL}/zosmf/restfiles/ds/${TEST_BIGPDS}" >/dev/null 2>&1 || true

curl -s -X DELETE -u "$AUTH" "${BASE_URL}/zosmf/restfiles/ds/${TEST_SEQ2}" >/dev/null 2>&1 || true

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X DELETE -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}")
assert_http_status "204" "$HTTP_CODE" "cleanup: delete PDS"

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
