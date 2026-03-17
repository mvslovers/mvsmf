#!/bin/bash
# =========================================================================
# mvsMF USS File REST API - curl test suite
#
# Tests USS (Unix System Services) file endpoints:
#   1. GET /zosmf/restfiles/fs?path=<dir>          (list directory)
#
# Prerequisites:
#   - Copy .env.example to .env at the repo root and fill in
#   - curl and jq must be installed
#   - UFSD subsystem must be running on the target MVS system
#
# Usage:
#   ./tests/curl-uss.sh
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

BASE_URL="http://${MVSMF_HOST}:${MVSMF_PORT}"
AUTH="${MVSMF_USER}:${MVSMF_PASS}"

# Test directory path (root of UFS filesystem)
TEST_DIR="${USS_TEST_DIR:-/}"

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

assert_json_field_gte() {
	local json="$1"
	local field="$2"
	local min="$3"
	local label="$4"
	local actual
	actual=$(echo "$json" | jq -r "$field" 2>/dev/null) || actual=""
	if [ -n "$actual" ] && [ "$actual" -ge "$min" ] 2>/dev/null; then
		pass "$label ($field=$actual >= $min)"
	else
		fail "$label" "$field: expected >= $min, got '$actual'"
	fi
}

# =========================================================================
# Tests
# =========================================================================

echo ""
echo "========================================"
echo " mvsMF USS File API - curl test suite"
echo " Host: ${MVSMF_HOST}:${MVSMF_PORT}"
echo " User: ${MVSMF_USER}"
echo " Test dir: ${TEST_DIR}"
echo "========================================"

# --- 1. List directory (basic) ---
echo ""
echo "--- List directory ---"

RESP=$(curl -s -w '\n%{http_code}' \
	-u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/fs?path=${TEST_DIR}")
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')

assert_http_status "200" "$HTTP_CODE" "list directory ${TEST_DIR}"
assert_json_field_exists "$BODY" ".items" "list: items array present"
assert_json_field_exists "$BODY" ".returnedRows" "list: returnedRows present"
assert_json_field_exists "$BODY" ".totalRows" "list: totalRows present"
assert_json_field "$BODY" ".JSONversion" "1" "list: JSONversion is 1"

# Check that items have the expected fields
FIRST_ITEM=$(echo "$BODY" | jq '.items[0]' 2>/dev/null)
if [ "$FIRST_ITEM" != "null" ] && [ -n "$FIRST_ITEM" ]; then
	assert_json_field_exists "$BODY" '.items[0].name' "list: item has name"
	assert_json_field_exists "$BODY" '.items[0].mode' "list: item has mode"
	assert_json_field_exists "$BODY" '.items[0].size' "list: item has size"
	assert_json_field_exists "$BODY" '.items[0].user' "list: item has user"
	assert_json_field_exists "$BODY" '.items[0].group' "list: item has group"
	assert_json_field_exists "$BODY" '.items[0].mtime' "list: item has mtime"
	assert_json_field_exists "$BODY" '.items[0].inode' "list: item has inode"
	assert_json_field_exists "$BODY" '.items[0].links' "list: item has links"
else
	skip "list: no items returned, skipping field checks"
fi

# --- 2. List with X-IBM-Max-Items ---
echo ""
echo "--- List with X-IBM-Max-Items ---"

RESP=$(curl -s -w '\n%{http_code}' \
	-u "$AUTH" \
	-H "X-IBM-Max-Items: 2" \
	"${BASE_URL}/zosmf/restfiles/fs?path=${TEST_DIR}")
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')

assert_http_status "200" "$HTTP_CODE" "list with max-items=2"

RETURNED=$(echo "$BODY" | jq -r '.returnedRows' 2>/dev/null)
TOTAL_ROWS=$(echo "$BODY" | jq -r '.totalRows' 2>/dev/null)
if [ -n "$RETURNED" ] && [ "$RETURNED" -le 2 ] 2>/dev/null; then
	pass "list max-items: returnedRows ($RETURNED) <= 2"
else
	fail "list max-items: returnedRows" "expected <= 2, got '$RETURNED'"
fi

if [ -n "$TOTAL_ROWS" ] && [ -n "$RETURNED" ] && [ "$TOTAL_ROWS" -gt 2 ] 2>/dev/null; then
	assert_json_field "$BODY" ".moreRows" "true" "list max-items: moreRows is true when truncated"
fi

# --- 3. List with X-IBM-Max-Items: 0 (unlimited) ---
echo ""
echo "--- List with X-IBM-Max-Items: 0 ---"

RESP=$(curl -s -w '\n%{http_code}' \
	-u "$AUTH" \
	-H "X-IBM-Max-Items: 0" \
	"${BASE_URL}/zosmf/restfiles/fs?path=${TEST_DIR}")
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')

assert_http_status "200" "$HTTP_CODE" "list with max-items=0 (unlimited)"
assert_json_field "$BODY" ".moreRows" "false" "list unlimited: moreRows is false"

# --- 4. Error: missing path parameter ---
echo ""
echo "--- Error cases ---"

RESP=$(curl -s -w '\n%{http_code}' \
	-u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/fs")
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')

assert_http_status "400" "$HTTP_CODE" "missing path returns 400"

# --- 5. Error: non-existent path ---

RESP=$(curl -s -w '\n%{http_code}' \
	-u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/fs?path=/nonexistent/path/that/does/not/exist")
HTTP_CODE=$(echo "$RESP" | tail -1)

assert_http_status "404" "$HTTP_CODE" "non-existent path returns 404"

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
