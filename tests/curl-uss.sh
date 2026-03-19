#!/bin/bash
# =========================================================================
# mvsMF USS File REST API - curl test suite
#
# Tests USS (Unix System Services) file endpoints:
#   1. GET  /zosmf/restfiles/fs?path=<dir>          (list directory)
#   2. GET  /zosmf/restfiles/fs/{filepath}          (read file)
#   3. PUT  /zosmf/restfiles/fs/{filepath}          (write file)
#   4. POST   /zosmf/restfiles/fs/{filepath}          (create file/dir)
#   5. DELETE /zosmf/restfiles/fs/{filepath}          (delete file/dir)
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

# Test file path for read tests (must exist on the UFS filesystem)
TEST_FILE="${USS_TEST_FILE:-}"

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
# Read file tests
# =========================================================================

if [ -n "$TEST_FILE" ]; then
	echo ""
	echo "--- Read file (text mode, default) ---"

	RESP=$(curl -s -w '\n%{http_code}' \
		-u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs${TEST_FILE}")
	HTTP_CODE=$(echo "$RESP" | tail -1)
	BODY=$(echo "$RESP" | sed '$d')

	assert_http_status "200" "$HTTP_CODE" "read file text mode ${TEST_FILE}"

	if [ -n "$BODY" ]; then
		pass "read file: response body is non-empty"
	else
		fail "read file: response body is empty"
	fi

	# --- Read file (binary mode) ---
	echo ""
	echo "--- Read file (binary mode) ---"

	RESP=$(curl -s -w '\n%{http_code}' \
		-u "$AUTH" \
		-H "X-IBM-Data-Type: binary" \
		"${BASE_URL}/zosmf/restfiles/fs${TEST_FILE}")
	HTTP_CODE=$(echo "$RESP" | tail -1)

	assert_http_status "200" "$HTTP_CODE" "read file binary mode ${TEST_FILE}"

	# --- Read file: non-existent path ---
	echo ""
	echo "--- Read file error cases ---"

	RESP=$(curl -s -w '\n%{http_code}' \
		-u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs/nonexistent/file/path.txt")
	HTTP_CODE=$(echo "$RESP" | tail -1)

	assert_http_status "404" "$HTTP_CODE" "read non-existent file returns 404"

	# --- Read file: directory path (should fail) ---

	RESP=$(curl -s -w '\n%{http_code}' \
		-u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs${TEST_DIR}")
	HTTP_CODE=$(echo "$RESP" | tail -1)

	# Attempting to read a directory should return 400 (ISDIR) or 404
	if [ "$HTTP_CODE" = "400" ] || [ "$HTTP_CODE" = "404" ]; then
		pass "read directory as file returns error (HTTP $HTTP_CODE)"
	else
		fail "read directory as file" "expected HTTP 400 or 404, got $HTTP_CODE"
	fi
else
	echo ""
	echo "--- Read file tests ---"
	skip "read file: USS_TEST_FILE not set in .env, skipping read tests"
fi

# =========================================================================
# Write file tests
# =========================================================================

if [ -n "$TEST_FILE" ]; then
	WRITE_FILE="${TEST_FILE}.writetest"

	echo ""
	echo "--- Write file (text mode) ---"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X PUT -u "$AUTH" \
		-d "Hello from curl write test" \
		"${BASE_URL}/zosmf/restfiles/fs${WRITE_FILE}")

	assert_http_status "204" "$HTTP_CODE" "write file text mode ${WRITE_FILE}"

	# Read it back and verify content
	RESP=$(curl -s -w '\n%{http_code}' \
		-u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs${WRITE_FILE}")
	HTTP_CODE=$(echo "$RESP" | tail -1)
	BODY=$(echo "$RESP" | sed '$d')

	assert_http_status "200" "$HTTP_CODE" "read back written file"
	if echo "$BODY" | grep -q "Hello from curl write test"; then
		pass "write+read round-trip: content matches"
	else
		fail "write+read round-trip" "content mismatch: '$BODY'"
	fi

	# --- Write file (binary mode) ---
	echo ""
	echo "--- Write file (binary mode) ---"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X PUT -u "$AUTH" \
		-H "X-IBM-Data-Type: binary" \
		-d "Binary test data" \
		"${BASE_URL}/zosmf/restfiles/fs${WRITE_FILE}")

	assert_http_status "204" "$HTTP_CODE" "write file binary mode"

	# --- Write with application/json Content-Type → 501 ---
	echo ""
	echo "--- Write file error cases ---"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X PUT -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"request":"chmod","action":"set","mode":"0755"}' \
		"${BASE_URL}/zosmf/restfiles/fs${WRITE_FILE}")

	assert_http_status "501" "$HTTP_CODE" "json content-type returns 501 (utilities not implemented)"

	# --- Cleanup: delete the test file (will be 501 until delete is implemented) ---
	curl -s -X DELETE -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs${WRITE_FILE}" >/dev/null 2>&1 || true
else
	echo ""
	echo "--- Write file tests ---"
	skip "write file: USS_TEST_FILE not set in .env, skipping write tests"
fi

# =========================================================================
# Create file/directory tests
# =========================================================================

if [ -n "$TEST_FILE" ]; then
	CREATE_DIR="$(dirname "$TEST_FILE")/curl-create-test-dir"
	CREATE_FILE="$(dirname "$TEST_FILE")/curl-create-test-file.txt"

	echo ""
	echo "--- Create directory ---"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X POST -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"type":"directory"}' \
		"${BASE_URL}/zosmf/restfiles/fs${CREATE_DIR}")

	assert_http_status "201" "$HTTP_CODE" "create directory ${CREATE_DIR}"

	# --- Create directory that already exists → 409 ---
	echo ""
	echo "--- Create directory (already exists) ---"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X POST -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"type":"directory"}' \
		"${BASE_URL}/zosmf/restfiles/fs${CREATE_DIR}")

	assert_http_status "400" "$HTTP_CODE" "create duplicate directory returns 400"

	# --- Create file ---
	echo ""
	echo "--- Create file ---"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X POST -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"type":"file"}' \
		"${BASE_URL}/zosmf/restfiles/fs${CREATE_FILE}")

	assert_http_status "201" "$HTTP_CODE" "create file ${CREATE_FILE}"

	# --- Create file with custom mode ---
	echo ""
	echo "--- Create file with mode ---"

	CREATE_FILE_MODE="$(dirname "$TEST_FILE")/curl-create-mode.txt"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X POST -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"type":"file","mode":"rw-r--r--"}' \
		"${BASE_URL}/zosmf/restfiles/fs${CREATE_FILE_MODE}")

	assert_http_status "201" "$HTTP_CODE" "create file with mode rw-r--r--"

	# --- Create with "dir" alias ---
	echo ""
	echo "--- Create directory (dir alias) ---"

	CREATE_DIR_ALIAS="$(dirname "$TEST_FILE")/curl-create-test-dir2"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X POST -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"type":"dir"}' \
		"${BASE_URL}/zosmf/restfiles/fs${CREATE_DIR_ALIAS}")

	assert_http_status "201" "$HTTP_CODE" "create directory with type=dir"

	# --- Error: missing type field ---
	echo ""
	echo "--- Create error cases ---"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X POST -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"mode":"rwxr-xr-x"}' \
		"${BASE_URL}/zosmf/restfiles/fs/tmp/test-no-type")

	assert_http_status "400" "$HTTP_CODE" "create without type returns 400"

	# --- Error: invalid type ---

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X POST -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"type":"symlink"}' \
		"${BASE_URL}/zosmf/restfiles/fs/tmp/test-bad-type")

	assert_http_status "400" "$HTTP_CODE" "create with invalid type returns 400"

	# --- Error: parent not found ---

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X POST -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"type":"file"}' \
		"${BASE_URL}/zosmf/restfiles/fs/nonexistent/parent/dir/file.txt")

	# UFSD returns ROFS (read-only filesystem) for paths outside writable mounts
	if [ "$HTTP_CODE" = "403" ] || [ "$HTTP_CODE" = "404" ]; then
		pass "create in non-existent parent returns error (HTTP $HTTP_CODE)"
	else
		fail "create in non-existent parent" "expected HTTP 403 or 404, got $HTTP_CODE"
	fi

	# --- Cleanup ---
	curl -s -X DELETE -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs${CREATE_FILE}" >/dev/null 2>&1 || true
	curl -s -X DELETE -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs${CREATE_FILE_MODE}" >/dev/null 2>&1 || true
	curl -s -X DELETE -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs${CREATE_DIR}" >/dev/null 2>&1 || true
	curl -s -X DELETE -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs${CREATE_DIR_ALIAS}" >/dev/null 2>&1 || true
else
	echo ""
	echo "--- Create file/directory tests ---"
	skip "create: USS_TEST_FILE not set in .env, skipping create tests"
fi

# =========================================================================
# Delete file/directory tests
# =========================================================================

if [ -n "$TEST_FILE" ]; then
	DELETE_FILE="$(dirname "$TEST_FILE")/curl-delete-test-file.txt"
	DELETE_DIR="$(dirname "$TEST_FILE")/curl-delete-test-dir"
	DELETE_DIR_REC="$(dirname "$TEST_FILE")/curl-delete-test-rec"

	echo ""
	echo "--- Delete file ---"

	# Create a file to delete
	curl -s -w '%{http_code}' -o /dev/null \
		-X POST -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"type":"file"}' \
		"${BASE_URL}/zosmf/restfiles/fs${DELETE_FILE}" >/dev/null 2>&1

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X DELETE -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs${DELETE_FILE}")

	assert_http_status "204" "$HTTP_CODE" "delete file ${DELETE_FILE}"

	# Verify it's gone
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs${DELETE_FILE}")

	assert_http_status "404" "$HTTP_CODE" "deleted file returns 404"

	# --- Delete non-existent file → 404 ---
	echo ""
	echo "--- Delete non-existent file ---"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X DELETE -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs/nonexistent/file/path.txt")

	assert_http_status "404" "$HTTP_CODE" "delete non-existent file returns 404"

	# --- Delete empty directory ---
	echo ""
	echo "--- Delete empty directory ---"

	# Create a directory to delete
	curl -s -w '%{http_code}' -o /dev/null \
		-X POST -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"type":"directory"}' \
		"${BASE_URL}/zosmf/restfiles/fs${DELETE_DIR}" >/dev/null 2>&1

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X DELETE -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs${DELETE_DIR}")

	assert_http_status "204" "$HTTP_CODE" "delete empty directory"

	# --- Delete non-empty directory without recursive → 400 ---
	echo ""
	echo "--- Delete non-empty directory (no recursive) ---"

	# Create dir with a file inside
	curl -s -o /dev/null \
		-X POST -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"type":"directory"}' \
		"${BASE_URL}/zosmf/restfiles/fs${DELETE_DIR_REC}" 2>&1

	curl -s -o /dev/null \
		-X POST -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"type":"file"}' \
		"${BASE_URL}/zosmf/restfiles/fs${DELETE_DIR_REC}/child.txt" 2>&1

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X DELETE -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs${DELETE_DIR_REC}")

	assert_http_status "400" "$HTTP_CODE" "delete non-empty dir without recursive returns 400"

	# --- Delete non-empty directory with recursive ---
	echo ""
	echo "--- Delete non-empty directory (recursive) ---"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X DELETE -u "$AUTH" \
		-H "X-IBM-Option: recursive" \
		"${BASE_URL}/zosmf/restfiles/fs${DELETE_DIR_REC}")

	assert_http_status "204" "$HTTP_CODE" "delete non-empty dir with recursive"

	# Verify it's gone
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs?path=${DELETE_DIR_REC}")

	assert_http_status "404" "$HTTP_CODE" "recursively deleted dir returns 404"
else
	echo ""
	echo "--- Delete file/directory tests ---"
	skip "delete: USS_TEST_FILE not set in .env, skipping delete tests"
fi

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
