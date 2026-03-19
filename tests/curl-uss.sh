#!/bin/bash
# =========================================================================
# mvsMF USS File REST API - curl test suite
#
# Tests USS (Unix System Services) file endpoints:
#   1. GET    /zosmf/restfiles/fs?path=<dir>          (list directory)
#   2. GET    /zosmf/restfiles/fs/{filepath}          (read file)
#   3. PUT    /zosmf/restfiles/fs/{filepath}          (write file)
#   4. DELETE /zosmf/restfiles/fs/{filepath}          (delete file/dir)
#   5. POST   /zosmf/restfiles/fs/{filepath}          (create file/dir)
#
# Sections are ordered so that each section can clean up after itself:
# delete tests run before create tests, write tests clean up via delete.
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

# Silent cleanup helper — DELETE, ignoring errors
cleanup() {
	curl -s -X DELETE -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs$1" >/dev/null 2>&1 || true
}

cleanup_recursive() {
	curl -s -X DELETE -u "$AUTH" \
		-H "X-IBM-Option: recursive" \
		"${BASE_URL}/zosmf/restfiles/fs$1" >/dev/null 2>&1 || true
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

# =========================================================================
# 1. List directory tests (read-only, no cleanup needed)
# =========================================================================

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

echo ""
echo "--- List error cases ---"

RESP=$(curl -s -w '\n%{http_code}' \
	-u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/fs")
HTTP_CODE=$(echo "$RESP" | tail -1)

assert_http_status "400" "$HTTP_CODE" "missing path returns 400"

RESP=$(curl -s -w '\n%{http_code}' \
	-u "$AUTH" \
	"${BASE_URL}/zosmf/restfiles/fs?path=/nonexistent/path/that/does/not/exist")
HTTP_CODE=$(echo "$RESP" | tail -1)

assert_http_status "404" "$HTTP_CODE" "non-existent path returns 404"

if [ -n "$TEST_FILE" ]; then
	RESP=$(curl -s -w '\n%{http_code}' \
		-u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs?path=${TEST_FILE}")
	HTTP_CODE=$(echo "$RESP" | tail -1)

	assert_http_status "404" "$HTTP_CODE" "list file path (not a directory) returns 404"
fi

# =========================================================================
# 2. Read file tests (read-only, no cleanup needed)
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

	echo ""
	echo "--- Read file (binary mode) ---"

	RESP=$(curl -s -w '\n%{http_code}' \
		-u "$AUTH" \
		-H "X-IBM-Data-Type: binary" \
		"${BASE_URL}/zosmf/restfiles/fs${TEST_FILE}")
	HTTP_CODE=$(echo "$RESP" | tail -1)

	assert_http_status "200" "$HTTP_CODE" "read file binary mode ${TEST_FILE}"

	echo ""
	echo "--- Read file error cases ---"

	RESP=$(curl -s -w '\n%{http_code}' \
		-u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs/nonexistent/file/path.txt")
	HTTP_CODE=$(echo "$RESP" | tail -1)

	assert_http_status "404" "$HTTP_CODE" "read non-existent file returns 404"

	RESP=$(curl -s -w '\n%{http_code}' \
		-u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs${TEST_DIR}")
	HTTP_CODE=$(echo "$RESP" | tail -1)

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
# 3. Write file tests (creates temp file, cleans up via DELETE)
# =========================================================================

if [ -n "$TEST_FILE" ]; then
	WRITE_FILE="${TEST_FILE}.writetest"

	# Pre-cleanup in case a previous run left debris
	cleanup "$WRITE_FILE"

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

	echo ""
	echo "--- Write file (binary mode) ---"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X PUT -u "$AUTH" \
		-H "X-IBM-Data-Type: binary" \
		-d "Binary test data" \
		"${BASE_URL}/zosmf/restfiles/fs${WRITE_FILE}")

	assert_http_status "204" "$HTTP_CODE" "write file binary mode"

	echo ""
	echo "--- Write file error cases ---"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X PUT -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"request":"chmod","action":"set","mode":"0755"}' \
		"${BASE_URL}/zosmf/restfiles/fs${WRITE_FILE}")

	assert_http_status "501" "$HTTP_CODE" "json content-type returns 501 (utilities not implemented)"

	echo ""
	echo "--- Write to directory path ---"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X PUT -u "$AUTH" \
		-H "Content-Length: 10" \
		-d "some data!" \
		"${BASE_URL}/zosmf/restfiles/fs${TEST_DIR}")

	assert_http_status "400" "$HTTP_CODE" "write to directory returns 400 (ISDIR)"

	# Cleanup
	cleanup "$WRITE_FILE"
else
	echo ""
	echo "--- Write file tests ---"
	skip "write file: USS_TEST_FILE not set in .env, skipping write tests"
fi

# =========================================================================
# 4. Delete file/directory tests (creates own fixtures, cleans up)
# =========================================================================

if [ -n "$TEST_FILE" ]; then
	DELETE_FILE="$(dirname "$TEST_FILE")/curl-delete-test-file.txt"
	DELETE_DIR="$(dirname "$TEST_FILE")/curl-delete-test-dir"
	DELETE_DIR_REC="$(dirname "$TEST_FILE")/curl-delete-test-rec"

	# Pre-cleanup in case a previous run left debris
	cleanup "$DELETE_FILE"
	cleanup "$DELETE_DIR"
	cleanup_recursive "$DELETE_DIR_REC"

	echo ""
	echo "--- Delete file ---"

	# Create a file to delete
	curl -s -o /dev/null \
		-X POST -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"type":"file"}' \
		"${BASE_URL}/zosmf/restfiles/fs${DELETE_FILE}" 2>&1

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X DELETE -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs${DELETE_FILE}")

	assert_http_status "204" "$HTTP_CODE" "delete file ${DELETE_FILE}"

	# Verify it's gone
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs${DELETE_FILE}")

	assert_http_status "404" "$HTTP_CODE" "deleted file returns 404"

	echo ""
	echo "--- Delete non-existent file ---"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X DELETE -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs/nonexistent/file/path.txt")

	assert_http_status "404" "$HTTP_CODE" "delete non-existent file returns 404"

	echo ""
	echo "--- Delete empty directory ---"

	# Create a directory to delete
	curl -s -o /dev/null \
		-X POST -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"type":"directory"}' \
		"${BASE_URL}/zosmf/restfiles/fs${DELETE_DIR}" 2>&1

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X DELETE -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs${DELETE_DIR}")

	assert_http_status "204" "$HTTP_CODE" "delete empty directory"

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
# 5. Create file/directory tests (cleans up own fixtures via DELETE)
# =========================================================================

if [ -n "$TEST_FILE" ]; then
	CREATE_DIR="$(dirname "$TEST_FILE")/curl-create-test-dir"
	CREATE_FILE="$(dirname "$TEST_FILE")/curl-create-test-file.txt"
	CREATE_FILE_MODE="$(dirname "$TEST_FILE")/curl-create-mode.txt"
	CREATE_DIR_ALIAS="$(dirname "$TEST_FILE")/curl-create-test-dir2"

	# Pre-cleanup in case a previous run left debris
	cleanup "$CREATE_FILE"
	cleanup "$CREATE_FILE_MODE"
	cleanup "$CREATE_DIR"
	cleanup "$CREATE_DIR_ALIAS"

	echo ""
	echo "--- Create directory ---"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X POST -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"type":"directory"}' \
		"${BASE_URL}/zosmf/restfiles/fs${CREATE_DIR}")

	assert_http_status "201" "$HTTP_CODE" "create directory ${CREATE_DIR}"

	echo ""
	echo "--- Create directory (already exists) ---"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X POST -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"type":"directory"}' \
		"${BASE_URL}/zosmf/restfiles/fs${CREATE_DIR}")

	assert_http_status "400" "$HTTP_CODE" "create duplicate directory returns 400"

	echo ""
	echo "--- Create file ---"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X POST -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"type":"file"}' \
		"${BASE_URL}/zosmf/restfiles/fs${CREATE_FILE}")

	assert_http_status "201" "$HTTP_CODE" "create file ${CREATE_FILE}"

	echo ""
	echo "--- Create file with mode ---"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X POST -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"type":"file","mode":"rw-r--r--"}' \
		"${BASE_URL}/zosmf/restfiles/fs${CREATE_FILE_MODE}")

	assert_http_status "201" "$HTTP_CODE" "create file with mode rw-r--r--"

	echo ""
	echo "--- Create directory (dir alias) ---"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X POST -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"type":"dir"}' \
		"${BASE_URL}/zosmf/restfiles/fs${CREATE_DIR_ALIAS}")

	assert_http_status "201" "$HTTP_CODE" "create directory with type=dir"

	echo ""
	echo "--- Create error cases ---"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X POST -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"mode":"rwxr-xr-x"}' \
		"${BASE_URL}/zosmf/restfiles/fs/tmp/test-no-type")

	assert_http_status "400" "$HTTP_CODE" "create without type returns 400"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X POST -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"type":"symlink"}' \
		"${BASE_URL}/zosmf/restfiles/fs/tmp/test-bad-type")

	assert_http_status "400" "$HTTP_CODE" "create with invalid type returns 400"

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

	# Cleanup
	cleanup "$CREATE_FILE"
	cleanup "$CREATE_FILE_MODE"
	cleanup "$CREATE_DIR"
	cleanup "$CREATE_DIR_ALIAS"
else
	echo ""
	echo "--- Create file/directory tests ---"
	skip "create: USS_TEST_FILE not set in .env, skipping create tests"
fi

# =========================================================================
# 6. Integration tests (full CRUD lifecycle, nested recursive delete)
# =========================================================================

if [ -n "$TEST_FILE" ]; then
	INT_DIR="$(dirname "$TEST_FILE")/curl-int-test-$$"
	INT_FILE="${INT_DIR}/testfile.txt"

	# Pre-cleanup in case a previous run left debris
	cleanup_recursive "$INT_DIR"

	echo ""
	echo "--- Integration: full CRUD lifecycle ---"

	# Create directory
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X POST -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"type":"directory"}' \
		"${BASE_URL}/zosmf/restfiles/fs${INT_DIR}")

	assert_http_status "201" "$HTTP_CODE" "integration: create directory"

	# Create file inside directory
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X POST -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"type":"file"}' \
		"${BASE_URL}/zosmf/restfiles/fs${INT_FILE}")

	assert_http_status "201" "$HTTP_CODE" "integration: create file"

	# Write content to file
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X PUT -u "$AUTH" \
		-d "Integration test content line 1" \
		"${BASE_URL}/zosmf/restfiles/fs${INT_FILE}")

	assert_http_status "204" "$HTTP_CODE" "integration: write file"

	# Read content back
	RESP=$(curl -s -w '\n%{http_code}' \
		-u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs${INT_FILE}")
	HTTP_CODE=$(echo "$RESP" | tail -1)
	BODY=$(echo "$RESP" | sed '$d')

	assert_http_status "200" "$HTTP_CODE" "integration: read file"
	if echo "$BODY" | grep -q "Integration test content line 1"; then
		pass "integration: content round-trip matches"
	else
		fail "integration: content round-trip" "content mismatch: '$BODY'"
	fi

	# List directory and verify file appears
	RESP=$(curl -s -w '\n%{http_code}' \
		-u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs?path=${INT_DIR}")
	HTTP_CODE=$(echo "$RESP" | tail -1)
	BODY=$(echo "$RESP" | sed '$d')

	assert_http_status "200" "$HTTP_CODE" "integration: list directory"

	HAS_FILE=$(echo "$BODY" | jq '[.items[].name] | index("testfile.txt") != null' 2>/dev/null)
	if [ "$HAS_FILE" = "true" ]; then
		pass "integration: created file appears in listing"
	else
		fail "integration: created file in listing" "testfile.txt not found"
	fi

	# Delete file
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X DELETE -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs${INT_FILE}")

	assert_http_status "204" "$HTTP_CODE" "integration: delete file"

	# Delete directory
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X DELETE -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs${INT_DIR}")

	assert_http_status "204" "$HTTP_CODE" "integration: delete empty directory"

	# Verify directory is gone
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs?path=${INT_DIR}")

	assert_http_status "404" "$HTTP_CODE" "integration: directory gone after delete"

	echo ""
	echo "--- Integration: nested recursive delete ---"

	NEST_DIR="${INT_DIR}"
	NEST_SUB="${NEST_DIR}/subdir"
	NEST_FILE1="${NEST_DIR}/top.txt"
	NEST_FILE2="${NEST_SUB}/nested.txt"

	# Create nested structure: dir/top.txt + dir/subdir/nested.txt
	curl -s -o /dev/null \
		-X POST -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"type":"directory"}' \
		"${BASE_URL}/zosmf/restfiles/fs${NEST_DIR}" 2>&1

	curl -s -o /dev/null \
		-X POST -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"type":"file"}' \
		"${BASE_URL}/zosmf/restfiles/fs${NEST_FILE1}" 2>&1

	curl -s -o /dev/null \
		-X POST -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"type":"directory"}' \
		"${BASE_URL}/zosmf/restfiles/fs${NEST_SUB}" 2>&1

	curl -s -o /dev/null \
		-X POST -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"type":"file"}' \
		"${BASE_URL}/zosmf/restfiles/fs${NEST_FILE2}" 2>&1

	# Non-recursive delete should fail
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X DELETE -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs${NEST_DIR}")

	assert_http_status "400" "$HTTP_CODE" "nested: non-recursive delete fails"

	# Recursive delete should succeed
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X DELETE -u "$AUTH" \
		-H "X-IBM-Option: recursive" \
		"${BASE_URL}/zosmf/restfiles/fs${NEST_DIR}")

	assert_http_status "204" "$HTTP_CODE" "nested: recursive delete succeeds"

	# Verify everything is gone
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs?path=${NEST_DIR}")

	assert_http_status "404" "$HTTP_CODE" "nested: directory tree gone after recursive delete"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs${NEST_FILE2}")

	assert_http_status "404" "$HTTP_CODE" "nested: nested file gone after recursive delete"
else
	echo ""
	echo "--- Integration tests ---"
	skip "integration: USS_TEST_FILE not set in .env, skipping integration tests"
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
