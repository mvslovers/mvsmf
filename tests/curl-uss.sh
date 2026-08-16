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

# Only the stat query and the read tests need TEST_FILE to already exist -
# the write/create/delete blocks make their own. Their guard covered an unset
# variable but not a configured path that is absent on the target, so a stale
# USS_TEST_FILE produced five failures claiming the endpoints were broken when
# they had correctly answered 404. Probe once; the two read-only blocks below
# skip on TEST_FILE_EXISTS, everything else keeps using TEST_FILE.
TEST_FILE_EXISTS=""
if [ -n "$TEST_FILE" ]; then
	if [ "$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" \
			"${BASE_URL}/zosmf/restfiles/fs?path=${TEST_FILE}")" = "200" ]; then
		TEST_FILE_EXISTS=1
	else
		echo "NOTE: USS_TEST_FILE=${TEST_FILE} is not on the target;" \
			"the stat and read tests that need it will be skipped."
	fi
fi

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

# No X-IBM-Max-Items, so this is a complete listing and stays 200 even though
# the handler applies a default cap of its own -- 206 answers the client's
# limit, not ours (#249). See the max-items block below for the truncated case.
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

RETURNED=$(echo "$BODY" | jq -r '.returnedRows' 2>/dev/null)
TOTAL_ROWS=$(echo "$BODY" | jq -r '.totalRows' 2>/dev/null)
if [ -n "$RETURNED" ] && [ "$RETURNED" -le 2 ] 2>/dev/null; then
	pass "list max-items: returnedRows ($RETURNED) <= 2"
else
	fail "list max-items: returnedRows" "expected <= 2, got '$RETURNED'"
fi

# Whether this directory has more than two entries decides both the status and
# moreRows, and the point of asserting them together is that they must agree:
# a 206 next to moreRows false (or the reverse) is the failure #249 is about.
if [ -n "$TOTAL_ROWS" ] && [ "$TOTAL_ROWS" -gt 2 ] 2>/dev/null; then
	assert_http_status "206" "$HTTP_CODE" "list with max-items=2 (truncated)"
	assert_json_field "$BODY" ".moreRows" "true" "list max-items: moreRows is true when truncated"
else
	assert_http_status "200" "$HTTP_CODE" "list with max-items=2 (not truncated)"
	assert_json_field "$BODY" ".moreRows" "false" "list max-items: moreRows is false when complete"
fi

# a limit nothing reaches is a complete listing: the header being present is
# not what makes a response partial
RESP=$(curl -s -w '\n%{http_code}' \
	-u "$AUTH" \
	-H "X-IBM-Max-Items: 10000" \
	"${BASE_URL}/zosmf/restfiles/fs?path=${TEST_DIR}")
HTTP_CODE=$(echo "$RESP" | tail -1)
BODY=$(echo "$RESP" | sed '$d')

assert_http_status "200" "$HTTP_CODE" "list with max-items above the entry count"
assert_json_field "$BODY" ".moreRows" "false" "list max-items=10000: moreRows is false"

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

if [ -n "$TEST_FILE_EXISTS" ]; then
	echo ""
	echo "--- List file path (stat-like query) ---"

	RESP=$(curl -s -w '\n%{http_code}' \
		-u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs?path=${TEST_FILE}")
	HTTP_CODE=$(echo "$RESP" | tail -1)
	BODY=$(echo "$RESP" | sed '$d')

	assert_http_status "200" "$HTTP_CODE" "list file path returns 200 (stat query)"

	RETURNED=$(echo "$BODY" | grep -o '"returnedRows": *[0-9]*' | grep -o '[0-9]*')
	if [ "$RETURNED" = "1" ]; then
		pass "stat query: returnedRows is 1"
	else
		fail "stat query: returnedRows expected 1, got ${RETURNED}"
	fi

	if echo "$BODY" | grep -q "\"name\": \"${TEST_FILE}\""; then
		pass "stat query: name contains full path"
	else
		fail "stat query: name does not contain full path ${TEST_FILE}"
	fi
fi

# =========================================================================
# 2. Read file tests (read-only, no cleanup needed)
# =========================================================================

if [ -n "$TEST_FILE_EXISTS" ]; then
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

	# Reading a directory as a file is asserted in the "Directory as a file
	# path" block below, not here: this section needs USS_TEST_FILE to be
	# present on the target, and the directory case needs only a fixture it
	# makes itself. Aiming it at TEST_DIR was what hid issue #269 -- see the
	# comment there.
else
	echo ""
	echo "--- Read file tests ---"
	skip "read file: USS_TEST_FILE is unset in .env or absent on the target"
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
	echo "--- Write file (chunked transfer encoding) ---"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X PUT -u "$AUTH" \
		-H "Transfer-Encoding: chunked" \
		-d "Hello from chunked transfer test" \
		"${BASE_URL}/zosmf/restfiles/fs${WRITE_FILE}")

	assert_http_status "204" "$HTTP_CODE" "write file chunked mode ${WRITE_FILE}"

	# Read it back and verify content
	RESP=$(curl -s -w '\n%{http_code}' \
		-u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs${WRITE_FILE}")
	HTTP_CODE=$(echo "$RESP" | tail -1)
	BODY=$(echo "$RESP" | sed '$d')

	assert_http_status "200" "$HTTP_CODE" "read back chunked-written file"
	if echo "$BODY" | grep -q "Hello from chunked transfer test"; then
		pass "chunked write+read round-trip: content matches"
	else
		fail "chunked write+read round-trip" "content mismatch: '$BODY'"
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
	echo "--- USS utilities: chtag list ---"

	RESP=$(curl -s -w '\n%{http_code}' \
		-X PUT -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"request":"chtag","action":"list"}' \
		"${BASE_URL}/zosmf/restfiles/fs${WRITE_FILE}")
	HTTP_CODE=$(echo "$RESP" | tail -1)
	BODY=$(echo "$RESP" | sed '$d')

	assert_http_status "200" "$HTTP_CODE" "chtag list returns 200"
	assert_json_field_exists "$BODY" ".stdout" "chtag list: stdout array present"

	STDOUT_VAL=$(echo "$BODY" | jq -r '.stdout[0]' 2>/dev/null) || STDOUT_VAL=""
	if echo "$STDOUT_VAL" | grep -q "untagged"; then
		pass "chtag list: stdout contains 'untagged'"
	else
		fail "chtag list: stdout contains 'untagged'" "got '$STDOUT_VAL'"
	fi

	if echo "$STDOUT_VAL" | grep -q "T=off"; then
		pass "chtag list: stdout contains 'T=off'"
	else
		fail "chtag list: stdout contains 'T=off'" "got '$STDOUT_VAL'"
	fi

	echo ""
	echo "--- USS utilities: chtag set (no-op) ---"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X PUT -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"request":"chtag","action":"set","type":"text","codeset":"IBM-1047"}' \
		"${BASE_URL}/zosmf/restfiles/fs${WRITE_FILE}")

	assert_http_status "200" "$HTTP_CODE" "chtag set returns 200 (no-op)"

	echo ""
	echo "--- USS utilities: chtag remove (no-op) ---"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X PUT -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"request":"chtag","action":"remove"}' \
		"${BASE_URL}/zosmf/restfiles/fs${WRITE_FILE}")

	assert_http_status "200" "$HTTP_CODE" "chtag remove returns 200 (no-op)"

	echo ""
	echo "--- USS utilities: unimplemented utility ---"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X PUT -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"request":"chmod","action":"set","mode":"0755"}' \
		"${BASE_URL}/zosmf/restfiles/fs${WRITE_FILE}")

	assert_http_status "501" "$HTTP_CODE" "chmod returns 501 (not implemented)"

	echo ""
	echo "--- Write file error cases ---"

	echo ""
	echo "--- Directory as a file path ---"

	# Its own directory, not TEST_DIR. TEST_DIR defaults to "/", which the
	# wildcard captures as the empty string -- the handler's missing-path
	# guard then answers 400 before ever reaching UFSD, so the assertion
	# passed without testing ISDIR at all.
	DIR_FIXTURE="${TEST_FILE}.dirtest"
	cleanup_recursive "$DIR_FIXTURE"
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X POST -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"type":"directory"}' \
		"${BASE_URL}/zosmf/restfiles/fs${DIR_FIXTURE}")
	assert_http_status "201" "$HTTP_CODE" "write-to-dir: create the fixture"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X PUT -u "$AUTH" \
		-H "Content-Length: 10" \
		-d "some data!" \
		"${BASE_URL}/zosmf/restfiles/fs${DIR_FIXTURE}")

	# 400 ISDIR, the row the mapping table in CLAUDE.md always promised.
	# Answered 404 until issue #269: ufs_fopen() returns NULL for a directory
	# rather than a handle carrying the error, so the diagnosis has to be
	# read off the session with ufs_last_rc(), not off the handle.
	assert_http_status "400" "$HTTP_CODE" "write to directory returns 400 (ISDIR)"

	# The GET side of the same NULL open, on the same fixture. It lives here
	# rather than with the read tests because those need USS_TEST_FILE to be
	# present on the target and this needs only a directory it makes itself.
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs${DIR_FIXTURE}")

	assert_http_status "400" "$HTTP_CODE" "read directory as file returns 400 (ISDIR)"

	# Neither answer may swallow a genuine 404: a path that is simply absent
	# is still not found, on both verbs.
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs${DIR_FIXTURE}.nosuch")

	assert_http_status "404" "$HTTP_CODE" "read a missing path still returns 404"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X PUT -u "$AUTH" \
		-d "x" \
		"${BASE_URL}/zosmf/restfiles/fs${DIR_FIXTURE}.nosuch/file.txt")

	assert_http_status "404" "$HTTP_CODE" "write below a missing parent still returns 404"

	# The empty path is a different 400, and worth holding separately so the
	# two cannot be confused again.
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X PUT -u "$AUTH" \
		-d "some data!" \
		"${BASE_URL}/zosmf/restfiles/fs/")

	assert_http_status "400" "$HTTP_CODE" "write to an empty path returns 400"

	# Cleanup
	cleanup "$WRITE_FILE"
	cleanup_recursive "$DIR_FIXTURE"

	# -----------------------------------------------------------------
	# ETag / optimistic locking (issue #264)
	#
	# Its own file: the section rewrites the content several times and
	# compares stamps across those writes, so sharing WRITE_FILE with the
	# blocks above would make a failure here look like a write failure there.
	# -----------------------------------------------------------------

	echo ""
	echo "--- ETag: optimistic locking (issue #264) ---"

	ETAG_FILE="${TEST_FILE}.etagtest"
	cleanup "$ETAG_FILE"

	# Pull the ETag out of a response header dump. Case-insensitive, CR
	# stripped: curl writes the header block verbatim, MVS sends CRLF.
	get_etag() {
		grep -i '^ETag:' "$1" | tr -d '\r' | sed 's/^[Ee][Tt][Aa][Gg]:[ ]*//'
	}

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X PUT -u "$AUTH" \
		-d "LINE ONE AND LINE TWO" \
		"${BASE_URL}/zosmf/restfiles/fs${ETAG_FILE}")
	assert_http_status "204" "$HTTP_CODE" "etag: seed the file"

	# An ETag costs an extra read pass, so it is opt-in: no header, no ETag.
	curl -s -o /dev/null -D /tmp/curl_uss_h1.txt -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs${ETAG_FILE}"
	if [ -z "$(get_etag /tmp/curl_uss_h1.txt)" ]; then
		pass "etag: a plain GET returns no ETag"
	else
		fail "etag: a plain GET returns no ETag" \
			"got $(get_etag /tmp/curl_uss_h1.txt)"
	fi

	curl -s -o /dev/null -D /tmp/curl_uss_h1.txt -u "$AUTH" \
		-H "X-IBM-Return-Etag: true" \
		"${BASE_URL}/zosmf/restfiles/fs${ETAG_FILE}"
	ETAG1=$(get_etag /tmp/curl_uss_h1.txt)
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

	# Stability: an unstable stamp 412s saves that should have succeeded.
	curl -s -o /dev/null -D /tmp/curl_uss_h2.txt -u "$AUTH" \
		-H "X-IBM-Return-Etag: true" \
		"${BASE_URL}/zosmf/restfiles/fs${ETAG_FILE}"
	ETAG2=$(get_etag /tmp/curl_uss_h2.txt)
	if [ "$ETAG1" = "$ETAG2" ]; then
		pass "etag: an unchanged file stamps the same twice"
	else
		fail "etag: an unchanged file stamps the same twice" "$ETAG1 vs $ETAG2"
	fi

	# The stamp is over the stored bytes, so the read mode cannot change it.
	# Text and binary differ in the codepage translation on the way out; if
	# that reached the hash, a client reading text could not write binary.
	curl -s -o /dev/null -D /tmp/curl_uss_h3.txt -u "$AUTH" \
		-H "X-IBM-Return-Etag: true" \
		-H "X-IBM-Data-Type: binary" \
		"${BASE_URL}/zosmf/restfiles/fs${ETAG_FILE}"
	ETAG3=$(get_etag /tmp/curl_uss_h3.txt)
	if [ "$ETAG1" = "$ETAG3" ]; then
		pass "etag: text and binary reads stamp alike"
	else
		fail "etag: text and binary reads stamp alike" "$ETAG1 vs $ETAG3"
	fi

	# A stale If-Match must be refused, and must not have written anything.
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X PUT -u "$AUTH" \
		-H "If-Match: 0000000000000000" \
		-d "OVERWRITTEN" \
		"${BASE_URL}/zosmf/restfiles/fs${ETAG_FILE}")
	assert_http_status "412" "$HTTP_CODE" "etag: a stale If-Match is refused"

	BODY=$(curl -s -u "$AUTH" "${BASE_URL}/zosmf/restfiles/fs${ETAG_FILE}")
	if echo "$BODY" | grep -q "LINE ONE AND LINE TWO"; then
		pass "etag: the refused write left the file untouched"
	else
		fail "etag: the refused write left the file untouched" \
			"content is now '$BODY'"
	fi

	# The current stamp is accepted, and the PUT hands back the new one.
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-D /tmp/curl_uss_h4.txt \
		-X PUT -u "$AUTH" \
		-H "If-Match: ${ETAG1}" \
		-H "X-IBM-Return-Etag: true" \
		-d "LINE ONE AND LINE TWO CHANGED" \
		"${BASE_URL}/zosmf/restfiles/fs${ETAG_FILE}")
	assert_http_status "204" "$HTTP_CODE" "etag: a current If-Match is accepted"

	ETAG4=$(get_etag /tmp/curl_uss_h4.txt)
	if [ -n "$ETAG4" ] && [ "$ETAG4" != "$ETAG1" ]; then
		pass "etag: the PUT returns the new stamp ($ETAG4)"
	else
		fail "etag: the PUT returns the new stamp" "got '$ETAG4', was '$ETAG1'"
	fi

	# The PUT stamp comes from re-reading the closed file, so it must equal
	# what the next GET computes. If it did not, every second save would 412.
	curl -s -o /dev/null -D /tmp/curl_uss_h5.txt -u "$AUTH" \
		-H "X-IBM-Return-Etag: true" \
		"${BASE_URL}/zosmf/restfiles/fs${ETAG_FILE}"
	ETAG5=$(get_etag /tmp/curl_uss_h5.txt)
	if [ "$ETAG4" = "$ETAG5" ]; then
		pass "etag: the PUT stamp matches the next GET stamp"
	else
		fail "etag: the PUT stamp matches the next GET stamp" "$ETAG4 vs $ETAG5"
	fi

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X PUT -u "$AUTH" \
		-H "If-Match: ${ETAG4}" \
		-d "LINE ONE AND LINE TWO" \
		"${BASE_URL}/zosmf/restfiles/fs${ETAG_FILE}")
	assert_http_status "204" "$HTTP_CODE" \
		"etag: a second save with the returned stamp"

	# The forms clients actually send: quoted and weak validators.
	curl -s -o /dev/null -D /tmp/curl_uss_h6.txt -u "$AUTH" \
		-H "X-IBM-Return-Etag: true" \
		"${BASE_URL}/zosmf/restfiles/fs${ETAG_FILE}"
	ETAG6=$(get_etag /tmp/curl_uss_h6.txt)

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X PUT -u "$AUTH" \
		-H "If-Match: \"${ETAG6}\"" \
		-d "QUOTED FORM" \
		"${BASE_URL}/zosmf/restfiles/fs${ETAG_FILE}")
	assert_http_status "204" "$HTTP_CODE" "etag: a quoted If-Match is accepted"

	curl -s -o /dev/null -D /tmp/curl_uss_h7.txt -u "$AUTH" \
		-H "X-IBM-Return-Etag: true" \
		"${BASE_URL}/zosmf/restfiles/fs${ETAG_FILE}"
	ETAG7=$(get_etag /tmp/curl_uss_h7.txt)

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X PUT -u "$AUTH" \
		-H "If-Match: W/\"${ETAG7}\"" \
		-d "WEAK FORM" \
		"${BASE_URL}/zosmf/restfiles/fs${ETAG_FILE}")
	assert_http_status "204" "$HTTP_CODE" "etag: a weak If-Match is accepted"

	# "*" asserts only that the file exists.
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X PUT -u "$AUTH" \
		-H "If-Match: *" \
		-d "WILDCARD FORM" \
		"${BASE_URL}/zosmf/restfiles/fs${ETAG_FILE}")
	assert_http_status "204" "$HTTP_CODE" \
		"etag: If-Match: * on an existing file is accepted"

	# ... and on a path that is not there it fails. A PUT creates, so there
	# is no 404 to compete with: the precondition is the whole answer.
	MISSING_FILE="${TEST_FILE}.etagmissing"
	cleanup "$MISSING_FILE"
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X PUT -u "$AUTH" \
		-H "If-Match: *" \
		-d "SHOULD NOT BE CREATED" \
		"${BASE_URL}/zosmf/restfiles/fs${MISSING_FILE}")
	assert_http_status "412" "$HTTP_CODE" \
		"etag: If-Match: * on a missing file is refused"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null -u "$AUTH" \
		"${BASE_URL}/zosmf/restfiles/fs${MISSING_FILE}")
	assert_http_status "404" "$HTTP_CODE" \
		"etag: the refused write created nothing"

	# Adding If-Match must not change how a directory is answered: the same
	# 400 ISDIR as the unconditional write above, not 412. Needs a real
	# directory -- see the write-to-directory block for why TEST_DIR will not
	# do. It was 404 on both sides before issue #269; what matters here is
	# that the two stay identical, whatever the write path answers.
	ETAG_DIR="${TEST_FILE}.etagdir"
	cleanup_recursive "$ETAG_DIR"
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X POST -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"type":"directory"}' \
		"${BASE_URL}/zosmf/restfiles/fs${ETAG_DIR}")
	assert_http_status "201" "$HTTP_CODE" "etag: create the directory fixture"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X PUT -u "$AUTH" \
		-H "If-Match: *" \
		-d "some data!" \
		"${BASE_URL}/zosmf/restfiles/fs${ETAG_DIR}")
	assert_http_status "400" "$HTTP_CODE" \
		"etag: If-Match on a directory answers as the plain write does"

	cleanup_recursive "$ETAG_DIR"

	# A write with no If-Match is unconditional, as before the feature.
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X PUT -u "$AUTH" \
		-d "UNCONDITIONAL" \
		"${BASE_URL}/zosmf/restfiles/fs${ETAG_FILE}")
	assert_http_status "204" "$HTTP_CODE" \
		"etag: a write without If-Match is unconditional"

	# -----------------------------------------------------------------
	# ETag: conditional reads / If-None-Match (issue #271)
	#
	# The read half of the same stamp. Shares ETAG_FILE with the block
	# above deliberately: the value a write returns and the value a read
	# compares against have to be the same one, and a section of its own
	# would hide a drift between them behind a fresh fixture.
	# -----------------------------------------------------------------

	echo ""
	echo "--- ETag: conditional reads / If-None-Match (issue #271) ---"

	# One value drives every check below: the stamp the file returns right
	# now. The read half computes its own stamp for the comparison, so if
	# that pass ever drifted from the one behind X-IBM-Return-Etag, it would
	# surface here as a 200 where a 304 was asked for -- which is why the two
	# are hashed in one pass.
	curl -s -D /tmp/curl_uss_c1.txt -o /dev/null -u "$AUTH" \
		-H "X-IBM-Return-Etag: true" \
		"${BASE_URL}/zosmf/restfiles/fs${ETAG_FILE}"
	CETAG=$(get_etag /tmp/curl_uss_c1.txt)

	HTTP_CODE=$(curl -s -w '%{http_code}' \
		-D /tmp/curl_uss_c2.txt -o /tmp/curl_uss_c2.body \
		-u "$AUTH" -H "If-None-Match: ${CETAG}" \
		"${BASE_URL}/zosmf/restfiles/fs${ETAG_FILE}")
	assert_http_status "304" "$HTTP_CODE" "cond: a current If-None-Match is 304"

	# A body is the one thing the status promises not to send.
	if [ ! -s /tmp/curl_uss_c2.body ]; then
		pass "cond: the 304 carries no body"
	else
		fail "cond: the 304 carries no body" \
			"got $(wc -c < /tmp/curl_uss_c2.body) bytes"
	fi

	# The ETag rides along without X-IBM-Return-Etag being sent: a client on
	# If-None-Match is already speaking the protocol, and the stamp had to be
	# computed to answer at all.
	if [ "$(get_etag /tmp/curl_uss_c2.txt)" = "$CETAG" ]; then
		pass "cond: the 304 carries the ETag it confirmed"
	else
		fail "cond: the 304 carries the ETag it confirmed" \
			"got '$(get_etag /tmp/curl_uss_c2.txt)', expected '$CETAG'"
	fi

	# The forms clients send, and the wildcard. "*" fails the If-None-Match
	# condition whenever a representation exists (RFC 9110 13.1.2), and a
	# failed condition on a GET is a 304 -- the opposite reading, "only if it
	# does not exist", is the conditional-create semantic of a PUT.
	for FORM in "\"${CETAG}\"" "W/\"${CETAG}\"" \
		"\"0000000000000000\", \"${CETAG}\"" "*"; do
		HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null -u "$AUTH" \
			-H "If-None-Match: ${FORM}" \
			"${BASE_URL}/zosmf/restfiles/fs${ETAG_FILE}")
		assert_http_status "304" "$HTTP_CODE" \
			"cond: If-None-Match ${FORM} is 304"
	done

	HTTP_CODE=$(curl -s -w '%{http_code}' \
		-D /tmp/curl_uss_c3.txt -o /tmp/curl_uss_c3.body -u "$AUTH" \
		-H "If-None-Match: 0000000000000000" \
		"${BASE_URL}/zosmf/restfiles/fs${ETAG_FILE}")
	assert_http_status "200" "$HTTP_CODE" "cond: a stale If-None-Match is 200"

	if [ -s /tmp/curl_uss_c3.body ]; then
		pass "cond: the 200 still carries the content"
	else
		fail "cond: the 200 still carries the content" "empty body"
	fi

	# The miss carries the stamp as well, without X-IBM-Return-Etag being
	# sent -- If-None-Match alone now widens the pass that computes it. A
	# reader polling on that header would otherwise receive the changed
	# content and no validator to ask about the next change with.
	if [ "$(get_etag /tmp/curl_uss_c3.txt)" = "$CETAG" ]; then
		pass "cond: the 200 carries the current ETag too"
	else
		fail "cond: the 200 carries the current ETag too" \
			"got '$(get_etag /tmp/curl_uss_c3.txt)', expected '$CETAG'"
	fi

	# The stamp is over the stored bytes, so it does not depend on
	# X-IBM-Data-Type -- and neither does the 304 it answers. The stamp above
	# came from a text read; this one asks in binary.
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null -u "$AUTH" \
		-H "X-IBM-Data-Type: binary" \
		-H "If-None-Match: ${CETAG}" \
		"${BASE_URL}/zosmf/restfiles/fs${ETAG_FILE}")
	assert_http_status "304" "$HTTP_CODE" "cond: a binary read is 304 too"

	# 304 has to be a statement about the current content, not about the
	# header having been seen once. Change the file and the same stamp must
	# stop matching.
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X PUT -u "$AUTH" \
		-d "CHANGED UNDERNEATH THE POLL" \
		"${BASE_URL}/zosmf/restfiles/fs${ETAG_FILE}")
	assert_http_status "204" "$HTTP_CODE" "cond: rewrite the file"

	HTTP_CODE=$(curl -s -w '%{http_code}' -D /tmp/curl_uss_c4.txt -o /dev/null \
		-u "$AUTH" -H "If-None-Match: ${CETAG}" \
		"${BASE_URL}/zosmf/restfiles/fs${ETAG_FILE}")
	assert_http_status "200" "$HTTP_CODE" "cond: a changed file is 200 again"

	# ... and the stamp it hands back is the new one, which is what lets the
	# poll continue from here without a second request.
	CETAGNEW=$(get_etag /tmp/curl_uss_c4.txt)
	if [ -n "$CETAGNEW" ] && [ "$CETAGNEW" != "$CETAG" ]; then
		pass "cond: the 200 after a change carries the new stamp ($CETAGNEW)"
	else
		fail "cond: the 200 after a change carries the new stamp" \
			"got '$CETAGNEW', was '$CETAG'"
	fi

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null -u "$AUTH" \
		-H "If-None-Match: ${CETAGNEW}" \
		"${BASE_URL}/zosmf/restfiles/fs${ETAG_FILE}")
	assert_http_status "304" "$HTTP_CODE" "cond: the new stamp is 304 in turn"

	# Nothing to be fresh about: the 404 is the more specific answer and wins.
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null -u "$AUTH" \
		-H "If-None-Match: *" \
		"${BASE_URL}/zosmf/restfiles/fs${MISSING_FILE}")
	assert_http_status "404" "$HTTP_CODE" "cond: a missing file is 404, not 304"

	# A directory is the case where the plain wildcard reading gives the wrong
	# answer: it exists, so "*" would be 304 -- but a directory has no
	# representation to hand back and the unconditional GET answers 400 ISDIR
	# (issue #269). Adding If-None-Match must not change that.
	cleanup_recursive "$ETAG_DIR"
	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
		-X POST -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"type":"directory"}' \
		"${BASE_URL}/zosmf/restfiles/fs${ETAG_DIR}")
	assert_http_status "201" "$HTTP_CODE" "cond: create the directory fixture"

	HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null -u "$AUTH" \
		-H "If-None-Match: *" \
		"${BASE_URL}/zosmf/restfiles/fs${ETAG_DIR}")
	assert_http_status "400" "$HTTP_CODE" \
		"cond: If-None-Match on a directory answers as the plain read does"

	cleanup_recursive "$ETAG_DIR"

	# A bodiless response is framed by its header block alone. If that framing
	# were wrong the next request on the same connection would hang or read the
	# previous response's tail -- curl reuses the connection when both URLs are
	# given in one invocation, so a second 304 here is the evidence.
	CODES=$(curl -s --max-time 30 -o /dev/null -w '%{http_code} ' -u "$AUTH" \
		-H "If-None-Match: ${CETAGNEW}" \
		"${BASE_URL}/zosmf/restfiles/fs${ETAG_FILE}" \
		"${BASE_URL}/zosmf/restfiles/fs${ETAG_FILE}")
	if [ "$CODES" = "304 304 " ]; then
		pass "cond: a second request on the same connection still answers"
	else
		fail "cond: a second request on the same connection still answers" \
			"got '$CODES', expected '304 304 '"
	fi

	cleanup "$ETAG_FILE"
	rm -f /tmp/curl_uss_h1.txt /tmp/curl_uss_h2.txt /tmp/curl_uss_h3.txt \
		/tmp/curl_uss_h4.txt /tmp/curl_uss_h5.txt /tmp/curl_uss_h6.txt \
		/tmp/curl_uss_h7.txt /tmp/curl_uss_c1.txt /tmp/curl_uss_c2.txt \
		/tmp/curl_uss_c2.body /tmp/curl_uss_c3.txt /tmp/curl_uss_c3.body \
		/tmp/curl_uss_c4.txt
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
