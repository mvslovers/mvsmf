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
#   - Copy tests/.config/.env.example to tests/.config/.env and fill in
#   - curl and jq must be installed
#
# Usage:
#   ./tests/curl-datasets.sh
# =========================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.config/.env"

if [ ! -f "$ENV_FILE" ]; then
	echo "ERROR: ${ENV_FILE} not found."
	echo "Copy .env.example to .env and fill in your values."
	exit 1
fi

# shellcheck source=.config/.env
. "$ENV_FILE"

BASE_URL="http://${MVS_HOST}:${MVS_PORT}"
AUTH="${MVS_USER}:${MVS_PASS}"

# Test dataset names
TEST_SEQ="${MVS_USER}.CURL.TESTSEQ"
TEST_PDS="${MVS_USER}.CURL.TESTPDS"

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

# =========================================================================
# Cleanup helper — delete datasets ignoring errors
# =========================================================================

cleanup_datasets() {
	curl -s -X DELETE -u "$AUTH" "${BASE_URL}/zosmf/restfiles/ds/${TEST_SEQ}" >/dev/null 2>&1 || true
	curl -s -X DELETE -u "$AUTH" "${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}" >/dev/null 2>&1 || true
}

# =========================================================================
# Tests
# =========================================================================

echo ""
echo "========================================"
echo " mvsMF Datasets API - curl test suite"
echo " Host: ${MVS_HOST}:${MVS_PORT}"
echo " User: ${MVS_USER}"
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

# --- List datasets ---
echo ""
echo "--- List Datasets ---"

BODY=$(curl -s -w '\n%{http_code}' -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds?dslevel=${MVS_USER}.CURL")
HTTP_CODE=$(echo "$BODY" | tail -1)
CONTENT=$(echo "$BODY" | sed '$d')
assert_http_status "200" "$HTTP_CODE" "list datasets"

# Extract volume serial for later volume-prefix tests
VOLUME=$(echo "$CONTENT" | jq -r --arg dsn "$TEST_SEQ" \
	'.items[] | select(.dsname == $dsn) | .vol // empty' 2>/dev/null) || VOLUME=""

# --- Read with volume prefix ---
echo ""
echo "--- Read Sequential Dataset with Volume Prefix ---"
if [ -n "$VOLUME" ] && [ "$VOLUME" != "null" ]; then
	BODY=$(curl -s -w '\n%{http_code}' -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/ds/-(${VOLUME})/${TEST_SEQ}")
	HTTP_CODE=$(echo "$BODY" | tail -1)
	assert_http_status "200" "$HTTP_CODE" "read dataset with volume prefix -(${VOLUME})"
else
	skip "read dataset with volume prefix (could not determine volume)"
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
	skip "delete dataset with volume prefix (could not create or no volume)"
fi

# --- Create PDS ---
echo ""
echo "--- Create PDS ---"

BODY='{"dsorg":"PO","recfm":"FB","lrecl":80,"blksize":3120,"alcunit":"TRK","primary":1,"secondary":1,"dirblk":5}'
HTTP_CODE=$(curl -s -w '%{http_code}' -o /tmp/curl_ds_pds.json \
	-X POST -u "$AUTH" \
	-H "Content-Type: application/json" \
	-d "$BODY" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}")
assert_http_status "201" "$HTTP_CODE" "create PDS"

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

# --- List PDS members with volume prefix ---
echo ""
echo "--- List PDS Members with Volume Prefix ---"

# Get volume from a dataset list query
VOLBODY=$(curl -s -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds?dslevel=${MVS_USER}.CURL")
PDS_VOLUME=$(echo "$VOLBODY" | jq -r --arg dsn "$TEST_PDS" \
	'.items[] | select(.dsname == $dsn) | .vol // empty' 2>/dev/null) || PDS_VOLUME=""

if [ -n "$PDS_VOLUME" ] && [ "$PDS_VOLUME" != "null" ]; then
	BODY=$(curl -s -w '\n%{http_code}' -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/ds/-(${PDS_VOLUME})/${TEST_PDS}/member")
	HTTP_CODE=$(echo "$BODY" | tail -1)
	assert_http_status "200" "$HTTP_CODE" "list members with volume prefix -(${PDS_VOLUME})"
else
	skip "list members with volume prefix (could not determine volume)"
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
	skip "read member with volume prefix (could not determine volume)"
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
	skip "write member with volume prefix (could not determine volume)"
fi

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
	skip "delete member with volume prefix (could not determine volume)"
fi

# --- Delete PDS member: not found ---
echo ""
echo "--- Delete PDS Member: not found ---"

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X DELETE -u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(TESTMBR)")
assert_http_status "404" "$HTTP_CODE" "delete non-existent member"

# --- Cleanup: delete PDS ---
echo ""
echo "--- Cleanup ---"

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
