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
TEST_VSEQ="${MVSMF_USER}.CURL.TESTBVB"
TEST_VPDS="${MVSMF_USER}.CURL.TESTBVBP"
TEST_VBIN="${MVSMF_USER}.CURL.TESTBVBB"
TEST_VBSS="${MVSMF_USER}.CURL.TESTBVBS"

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
	curl -s -X DELETE -K "$MVSMF_CURLRC" "${BASE_URL}/zosmf/restfiles/ds/${TEST_VSEQ}" >/dev/null 2>&1 || true
	curl -s -X DELETE -K "$MVSMF_CURLRC" "${BASE_URL}/zosmf/restfiles/ds/${TEST_VPDS}" >/dev/null 2>&1 || true
	curl -s -X DELETE -K "$MVSMF_CURLRC" "${BASE_URL}/zosmf/restfiles/ds/${TEST_VBIN}" >/dev/null 2>&1 || true
	curl -s -X DELETE -K "$MVSMF_CURLRC" "${BASE_URL}/zosmf/restfiles/ds/${TEST_VBSS}" >/dev/null 2>&1 || true
}

# The start of a body, printable characters only, for a failure message.
body_head() {
	head -c 200 "$1" | tr -c '[:print:]' '?'
}

# Four bytes of a file as hex: the length prefix of a record-mode read.
first4_hex() {
	head -c 4 "$1" | od -An -tx1 | tr -d ' \n'
}

# Record mode on a RECFM=V data set must be refused, with no data in the
# answer (issue #455). $1 = URL, $2 = label, $3 = a string that is in the
# data and so must not be in the answer (checked in ASCII, and as the EBCDIC
# bytes of "VBRECORD").
assert_record_refused() {
	local url="$1" label="$2" marker="$3"
	local code
	code=$(curl -s -w '%{http_code}' -o "$DOWNLOAD_FILE" \
		-K "$MVSMF_CURLRC" \
		-H "X-IBM-Data-Type: record" \
		"$url")
	assert_http_status "400" "$code" "$label: record read is refused"
	if [ "$(jq -r '[.category, .rc, .reason] | join(",")' "$DOWNLOAD_FILE" 2>/dev/null)" = "6,8,12" ]; then
		pass "$label: error report is category 6, rc 8, reason 12"
	else
		fail "$label: error report is category 6, rc 8, reason 12" "body: $(body_head "$DOWNLOAD_FILE")"
	fi
	# The message tells the client what to use instead (issue #524).
	local msg
	msg=$(jq -r '.message // ""' "$DOWNLOAD_FILE" 2>/dev/null)
	if echo "$msg" | grep -q "RECFM=V" \
		&& echo "$msg" | grep -q "binary" \
		&& echo "$msg" | grep -q "text"; then
		pass "$label: the message names RECFM=V and says to use binary or text"
	else
		fail "$label: the message names RECFM=V and says to use binary or text" "message: $msg"
	fi
	# The data reaches the client as it is stored, EBCDIC: look for both.
	if LC_ALL=C grep -qa "$marker" "$DOWNLOAD_FILE" \
		|| LC_ALL=C grep -qa "$(printf '\345\302\331\305\303\326\331\304')" "$DOWNLOAD_FILE"; then
		fail "$label: no data in the answer" "the body contains the data set's content"
	else
		pass "$label: no data in the answer"
	fi
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
echo "--- Record Read from Sequential Dataset, RECFM=FB (issue #455 control) ---"

HTTP_CODE=$(curl -s -w '%{http_code}' -o "$DOWNLOAD_FILE" \
	-K "$MVSMF_CURLRC" \
	-H "X-IBM-Data-Type: record" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_SEQ}")
assert_http_status "200" "$HTTP_CODE" "record read of an FB dataset"
if [ "$(first4_hex "$DOWNLOAD_FILE")" = "00000050" ] \
	&& [ "$(tail -c +5 "$DOWNLOAD_FILE" | head -c 80 | od -An -tx1 | tr -d ' \n')" = "$(head -c 80 "$BINARY_FILE" | od -An -tx1 | tr -d ' \n')" ]; then
	pass "record read of an FB dataset: 4-byte length 80, then the record"
else
	fail "record read of an FB dataset: 4-byte length 80, then the record" "prefix $(first4_hex "$DOWNLOAD_FILE")"
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

echo ""
echo "--- Record Read from PDS Member, RECFM=FB (issue #455 control) ---"

HTTP_CODE=$(curl -s -w '%{http_code}' -o "$DOWNLOAD_FILE" \
	-K "$MVSMF_CURLRC" \
	-H "X-IBM-Data-Type: record" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(BINMBR)")
assert_http_status "200" "$HTTP_CODE" "record read of an FB member"
if [ "$(first4_hex "$DOWNLOAD_FILE")" = "00000050" ] \
	&& [ "$(tail -c +5 "$DOWNLOAD_FILE" | head -c 80 | od -An -tx1 | tr -d ' \n')" = "$(head -c 80 "$BINARY_FILE" | od -An -tx1 | tr -d ' \n')" ]; then
	pass "record read of an FB member: 4-byte length 80, then the record"
else
	fail "record read of an FB member: 4-byte length 80, then the record" "prefix $(first4_hex "$DOWNLOAD_FILE")"
fi

# -----------------------------------------------------------------
# Record mode on RECFM=V is refused (issue #455)
#
# Until a correct RECFM=V record mode exists (#244, #245, #361), a record read
# of a variable-length data set returned LRECL-sized chunks that cross record
# boundaries. Lines of unequal length make that visible; the answer must now be
# an error report and never data.
# -----------------------------------------------------------------

echo ""
echo "--- Record Read, RECFM=VB (issue #455) ---"

BODY='{"dsorg":"PS","recfm":"VB","lrecl":84,"blksize":3120,"alcunit":"TRK","primary":1,"secondary":1}'
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X POST -K "$MVSMF_CURLRC" \
	-H "Content-Type: application/json" \
	-d "$BODY" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_VSEQ}")
assert_http_status "201" "$HTTP_CODE" "create VB sequential dataset"

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X PUT -K "$MVSMF_CURLRC" \
	-H "X-IBM-Data-Type: text" \
	--data-binary $'VBRECORD ONE\nVBRECORD TWO IS LONGER\nVBRECORD 3\n' \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_VSEQ}")
assert_http_status "204" "$HTTP_CODE" "upload three lines of unequal length to the VB dataset"

assert_record_refused "${BASE_URL}/zosmf/restfiles/ds/${TEST_VSEQ}" \
	"VB sequential dataset" "VBRECORD"

HTTP_CODE=$(curl -s -w '%{http_code}' -o "$DOWNLOAD_FILE" \
	-K "$MVSMF_CURLRC" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_VSEQ}")
assert_http_status "200" "$HTTP_CODE" "text read of the VB dataset is unaffected"
if [ "$(grep -c VBRECORD "$DOWNLOAD_FILE")" = "3" ]; then
	pass "text read of the VB dataset returns the three lines"
else
	fail "text read of the VB dataset returns the three lines" "body: $(body_head "$DOWNLOAD_FILE")"
fi

echo ""
echo "--- Record Read from PDS Member, RECFM=VB (issue #455) ---"

BODY='{"dsorg":"PO","recfm":"VB","lrecl":84,"blksize":3120,"alcunit":"TRK","primary":1,"secondary":1,"dirblk":5}'
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X POST -K "$MVSMF_CURLRC" \
	-H "Content-Type: application/json" \
	-d "$BODY" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_VPDS}")
assert_http_status "201" "$HTTP_CODE" "create VB PDS"

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X PUT -K "$MVSMF_CURLRC" \
	-H "X-IBM-Data-Type: text" \
	--data-binary $'VBRECORD ONE\nVBRECORD TWO IS LONGER\nVBRECORD 3\n' \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_VPDS}(VBMBR)")
assert_http_status "204" "$HTTP_CODE" "upload three lines of unequal length to the VB member"

assert_record_refused "${BASE_URL}/zosmf/restfiles/ds/${TEST_VPDS}(VBMBR)" \
	"VB member" "VBRECORD"

# -----------------------------------------------------------------
# Binary on RECFM=VB and VBS (issues #570, #244)
#
# Until now binary was only tried on FB. The upload is cut into LRECL-sized
# pieces, so a body that is a whole number of LRECLs comes back as it went in
# -- the contract is that, and nothing more: how a body that is not is padded
# is a different question. The bodies below are 100 whole records and cross
# block boundaries on purpose.
#
# VBS takes its own data set: a record of LRECL bytes written into a spanned
# data set abends in libc370 (U0002, answered as HTTP 500) -- the same access
# method code as libc370#757, and unchecked against its fix.
# -----------------------------------------------------------------

VB_BIN_BYTES=8400	# 100 records of the VB data set's LRECL 84 = 35 x binary80.bin
VB_BIN_FILE=$(mktemp)
VBS_BIN_FILE=$(mktemp)
mvsmf_on_exit 'rm -f "$VB_BIN_FILE" "$VBS_BIN_FILE"'
i=0
while [ "$i" -lt $((VB_BIN_BYTES / 240)) ]; do
	cat "$BINARY_FILE"
	i=$((i + 1))
done > "$VB_BIN_FILE"
# 100 records of the VBS data set's LRECL 255, cut from the same pattern
i=0
while [ "$i" -lt 107 ]; do
	cat "$BINARY_FILE"
	i=$((i + 1))
done | head -c 25500 > "$VBS_BIN_FILE"

# $1 label, $2 URL, $3 file to upload
binary_vb_roundtrip() {
	local label="$1" url="$2" file="$3" want got
	HTTP_CODE=$(curl -s -w '%{http_code}' -o "$DOWNLOAD_FILE" \
		-X PUT -K "$MVSMF_CURLRC" \
		-H "Content-Type: application/octet-stream" \
		-H "X-IBM-Data-Type: binary" \
		--data-binary @"$file" \
		"$url")
	assert_http_status "204" "$HTTP_CODE" "${label}: upload binary"
	if [ "$HTTP_CODE" != "204" ]; then
		echo "        body: $(body_head "$DOWNLOAD_FILE")"
	fi

	HTTP_CODE=$(curl -s -w '%{http_code}' -o "$DOWNLOAD_FILE" \
		-K "$MVSMF_CURLRC" \
		-H "X-IBM-Data-Type: binary" \
		"$url")
	assert_http_status "200" "$HTTP_CODE" "${label}: download binary"

	want=$(wc -c < "$file" | tr -d ' ')
	got=$(wc -c < "$DOWNLOAD_FILE" | tr -d ' ')
	if cmp -s "$file" "$DOWNLOAD_FILE"; then
		pass "${label}: binary round-trip matches (${want} bytes)"
	else
		fail "${label}: binary round-trip matches" \
			"sizes: orig=${want} dl=${got}; $(cmp "$file" "$DOWNLOAD_FILE" 2>&1 | head -n 1)"
	fi
}

echo ""
echo "--- Binary round trip, RECFM=VB sequential, LRECL 84 (issue #570) ---"

BODY='{"dsorg":"PS","recfm":"VB","lrecl":84,"blksize":3120,"alcunit":"TRK","primary":1,"secondary":1}'
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X POST -K "$MVSMF_CURLRC" \
	-H "Content-Type: application/json" \
	-d "$BODY" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_VBIN}")
assert_http_status "201" "$HTTP_CODE" "create VB sequential dataset for binary"
binary_vb_roundtrip "VB sequential" "${BASE_URL}/zosmf/restfiles/ds/${TEST_VBIN}" "$VB_BIN_FILE"

echo ""
echo "--- Binary round trip, RECFM=VB member, LRECL 84 (issue #570) ---"

binary_vb_roundtrip "VB member" "${BASE_URL}/zosmf/restfiles/ds/${TEST_VPDS}(VBBIN)" "$VB_BIN_FILE"

echo ""
echo "--- Binary round trip, RECFM=VBS sequential, LRECL 255 (issue #570) ---"

BODY='{"dsorg":"PS","recfm":"VBS","lrecl":255,"blksize":6233,"alcunit":"TRK","primary":5,"secondary":5}'
HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X POST -K "$MVSMF_CURLRC" \
	-H "Content-Type: application/json" \
	-d "$BODY" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_VBSS}")
assert_http_status "201" "$HTTP_CODE" "create VBS sequential dataset for binary"
binary_vb_roundtrip "VBS sequential" "${BASE_URL}/zosmf/restfiles/ds/${TEST_VBSS}" "$VBS_BIN_FILE"

# -----------------------------------------------------------------
# Cleanup
# -----------------------------------------------------------------

echo ""
echo "--- Cleanup ---"

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X DELETE -K "$MVSMF_CURLRC" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_VBIN}")
assert_http_status "204" "$HTTP_CODE" "cleanup: delete VB binary dataset"

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X DELETE -K "$MVSMF_CURLRC" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_VBSS}")
assert_http_status "204" "$HTTP_CODE" "cleanup: delete VBS binary dataset"

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X DELETE -K "$MVSMF_CURLRC" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}")
assert_http_status "204" "$HTTP_CODE" "cleanup: delete PDS"

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X DELETE -K "$MVSMF_CURLRC" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_VPDS}")
assert_http_status "204" "$HTTP_CODE" "cleanup: delete VB PDS"

HTTP_CODE=$(curl -s -w '%{http_code}' -o /dev/null \
	-X DELETE -K "$MVSMF_CURLRC" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_VSEQ}")
assert_http_status "204" "$HTTP_CODE" "cleanup: delete VB sequential dataset"

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
