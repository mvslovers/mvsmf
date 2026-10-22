#!/bin/bash
# =========================================================================
# mvsMF Datasets REST API - curl binary transfer test suite
#
# Tests binary upload/download for sequential datasets and PDS members.
# Uploads a known binary file, downloads it back, and compares byte-exact.
#
# Prerequisites:
#   - Run through mbt (see Usage), which hands over the target's
#     connection (tests/lib/conn.sh)
#   - curl and jq must be installed
#
# Usage:
#   mbt run rest-tests -- curl-binary
# =========================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY_FILE="${SCRIPT_DIR}/data/binary80.bin"

if [ ! -f "$BINARY_FILE" ]; then
	echo "ERROR: ${BINARY_FILE} not found."
	exit 1
fi

. "${SCRIPT_DIR}/lib/conn.sh"

# Test dataset names
TEST_SEQ="${MVSMF_USER}.CURL.TESTBIN"
TEST_PDS="${MVSMF_USER}.CURL.TESTBPDS"
TEST_BLK="${MVSMF_USER}.CURL.TESTBBLK"

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

# =========================================================================
# Cleanup helper
# =========================================================================

cleanup_datasets() {
	curl -s -X DELETE -K "$MVSMF_CURLRC" "${BASE_URL}/zosmf/restfiles/ds/${TEST_SEQ}" >/dev/null 2>&1 || true
	curl -s -X DELETE -K "$MVSMF_CURLRC" "${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}" >/dev/null 2>&1 || true
	curl -s -X DELETE -K "$MVSMF_CURLRC" "${BASE_URL}/zosmf/restfiles/ds/${TEST_BLK}" >/dev/null 2>&1 || true
}

# =========================================================================
# Tests
# =========================================================================

echo ""
echo "========================================"
echo " mvsMF Datasets API - curl binary tests"
echo " Host: ${MVSMF_HOST}:${MVSMF_PORT}"
echo " User: ${MVSMF_USER}"
echo "========================================"

# Clean up leftovers
cleanup_datasets

# -----------------------------------------------------------------
# Sequential dataset: binary round-trip
# -----------------------------------------------------------------

echo ""
echo "--- Create Sequential Dataset (FB80) ---"

BODY='{"dsorg":"PS","recfm":"FB","lrecl":80,"blksize":3120,"alcunit":"TRK","primary":1,"secondary":1}'
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X POST -K "$MVSMF_CURLRC" \
	-H "Content-Type: application/json" \
	-d "$BODY" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_SEQ}")
assert_http_status "201" "$HTTP_CODE" "create sequential dataset"

echo ""
echo "--- Upload Binary to Sequential Dataset ---"

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X PUT -K "$MVSMF_CURLRC" \
	-H "Content-Type: application/octet-stream" \
	-H "X-IBM-Data-Type: binary" \
	--data-binary @"$BINARY_FILE" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_SEQ}")
assert_http_status "204" "$HTTP_CODE" "upload binary to sequential dataset"

echo ""
echo "--- Download Binary from Sequential Dataset ---"

HTTP_CODE=$(curl -s -w '%{http_code}' -o "$DOWNLOAD_FILE" \
	-K "$MVSMF_CURLRC" \
	-H "X-IBM-Data-Type: binary" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_SEQ}")
assert_http_status "200" "$HTTP_CODE" "download binary from sequential dataset"

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

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X DELETE -K "$MVSMF_CURLRC" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_SEQ}")
assert_http_status "204" "$HTTP_CODE" "delete sequential dataset"

# -----------------------------------------------------------------
# Blocks per track (issue #439): a data set of more than one track
# -----------------------------------------------------------------

echo ""
echo "--- Blocks per track agree with the last-block pointer (issue #439) ---"

# What the binary read caps at is lstar_tt * blocks_per_track + lstar_r, the
# record count's source. The data set must run over a track boundary: with
# lstar_tt = 0 the product drops blocks_per_track and any value passes. 26
# blocks of BLKSIZE 3120 take 2 tracks on a 3380 (13 blocks per track) and 6
# on a 3350 (5 per track).
# Fails with the byte-overhead formula on a 3380: it gives 15 blocks per
# track, the pointer (TT 1, R 13) is read as 1 * 15 + 13 = 28 blocks, 26 were
# written. Passes with the cell formula: 1 * 13 + 13 = 26.
BLOCKS_BYTES=81120	# 26 blocks of 39 records of 80 bytes = 338 x binary80.bin
BLOCKS_FILE=$(mktemp)
mvsmf_on_exit 'rm -f "$BLOCKS_FILE"'
i=0
while [ "$i" -lt $((BLOCKS_BYTES / 240)) ]; do
	cat "$BINARY_FILE"
	i=$((i + 1))
done > "$BLOCKS_FILE"

BODY='{"dsorg":"PS","recfm":"FB","lrecl":80,"blksize":3120,"alcunit":"TRK","primary":3,"secondary":1}'
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X POST -K "$MVSMF_CURLRC" \
	-H "Content-Type: application/json" \
	-d "$BODY" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_BLK}")
assert_http_status "201" "$HTTP_CODE" "create the multi-track sequential dataset"

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X PUT -K "$MVSMF_CURLRC" \
	-H "Content-Type: application/octet-stream" \
	-H "X-IBM-Data-Type: binary" \
	--data-binary @"$BLOCKS_FILE" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_BLK}")
assert_http_status "204" "$HTTP_CODE" "upload 26 blocks to the multi-track dataset"

DSCB_JSON=$(curl -s -K "$MVSMF_CURLRC" \
	"${BASE_URL}/zosmf/test?fn=dscb&dsn=${TEST_BLK}")
BPT=$(echo "$DSCB_JSON" | jq -r '.blocks_per_track // empty')
if [ -z "$BPT" ] || [ "$BPT" = "0" ]; then
	skip "blocks per track: device not known to the estimate (devfg=$(echo "$DSCB_JSON" | jq -r '.devfg // "?"'))"
else
	LSTAR_TT=$(echo "$DSCB_JSON" | jq -r '.lstar_tt')
	LSTAR_R=$(echo "$DSCB_JSON" | jq -r '.lstar_r')
	WRITTEN=$(( ($(wc -c < "$BLOCKS_FILE" | tr -d ' ') / 80 + 38) / 39 ))
	GOT=$(( LSTAR_TT * BPT + LSTAR_R ))
	if [ "$LSTAR_TT" -lt 1 ]; then
		fail "blocks per track ${BPT}: the data set stayed on one track" "lstar_tt=${LSTAR_TT}, the check proves nothing"
	elif [ "$GOT" = "$WRITTEN" ]; then
		pass "blocks per track ${BPT}: ${GOT} blocks over ${LSTAR_TT}+1 tracks, as written"
	else
		fail "blocks per track ${BPT}: last-block pointer names ${GOT} blocks" "expected ${WRITTEN}, lstar_tt=${LSTAR_TT} lstar_r=${LSTAR_R}"
	fi
fi

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X DELETE -K "$MVSMF_CURLRC" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_BLK}")
assert_http_status "204" "$HTTP_CODE" "delete the multi-track dataset"

# -----------------------------------------------------------------
# PDS member: binary round-trip
# -----------------------------------------------------------------

echo ""
echo "--- Create PDS (FB80) ---"

BODY='{"dsorg":"PO","recfm":"FB","lrecl":80,"blksize":3120,"alcunit":"TRK","primary":1,"secondary":1,"dirblk":5}'
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X POST -K "$MVSMF_CURLRC" \
	-H "Content-Type: application/json" \
	-d "$BODY" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}")
assert_http_status "201" "$HTTP_CODE" "create PDS"

echo ""
echo "--- Upload Binary to PDS Member ---"

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X PUT -K "$MVSMF_CURLRC" \
	-H "Content-Type: application/octet-stream" \
	-H "X-IBM-Data-Type: binary" \
	--data-binary @"$BINARY_FILE" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(BINMBR)")
assert_http_status "204" "$HTTP_CODE" "upload binary to PDS member"

echo ""
echo "--- Download Binary from PDS Member ---"

HTTP_CODE=$(curl -s -w '%{http_code}' -o "$DOWNLOAD_FILE" \
	-K "$MVSMF_CURLRC" \
	-H "X-IBM-Data-Type: binary" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(BINMBR)")
assert_http_status "200" "$HTTP_CODE" "download binary from PDS member"

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

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X DELETE -K "$MVSMF_CURLRC" \
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
