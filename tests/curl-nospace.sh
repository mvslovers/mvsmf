#!/bin/bash
# =========================================================================
# mvsMF Datasets REST API - out-of-space write test (#366)
#
# A PUT that fills its target must not answer 2xx. Before #366 it could:
# libc370 1.0.6 turned an out-of-space write from ABEND SD37 into a return
# code, and the fflush() that carries it was being discarded -- so a PUT
# whose last record completed the last block answered 204 with records
# missing. Measured on mvsdev 2026-09-14: 200 records into a 194-record
# data set lost ten and reported success.
#
# The physical I/O is per BLOCK, not per record, which is what makes the
# boundary predictable: fflush() hands one record to the access method and
# the block reaches DASD when it fills. So the record that COMPLETES a
# block is the one whose write can fail inside a PUT, and that is the case
# this test pins.
#
# KNOWN GAP, deliberately not a failure here: a PUT whose last block is
# PARTIAL is written by libc370's @@ACLOSE, which ends FUNEXIT RC=0
# unconditionally, and fclose() discards even that. Those records are still
# lost silently and nothing in mvsMF can see it -- libc370#182. The test
# reports that band so it stays visible, and fails only if the silent band
# reaches the block boundary, which is the regression #366 fixed.
#
# Prerequisites:
#   - Copy .env.example to .env at the repo root and fill in
#   - curl must be installed
#
# Usage:
#   ./tests/curl-nospace.sh
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
TEST_DS="${MVSMF_USER}.CURL.NOSPACE"

# One track, no secondary: the target has to fill. LRECL/BLKSIZE give the
# blocking factor, which is where the boundary sits.
LRECL=80
BLKSIZE=800
BLKFACT=$((BLKSIZE / LRECL))

PASSED=0
FAILED=0
TOTAL=0

pass() { PASSED=$((PASSED + 1)); TOTAL=$((TOTAL + 1)); echo "  PASS: $1"; }
fail() {
	FAILED=$((FAILED + 1)); TOTAL=$((TOTAL + 1)); echo "  FAIL: $1"
	[ -n "${2:-}" ] && echo "        $2"
}
info() { echo "  ..   $1"; }

cleanup() {
	curl -s -o /dev/null -X DELETE -u "$AUTH" "${BASE_URL}/zosmf/restfiles/ds/${TEST_DS}"
}
trap cleanup EXIT

# put <n>  -> echoes "<status> <records on disk>"
put() {
	local n=$1 st got
	st=$(awk -v n="$n" -v w=$((LRECL - 8)) \
	       'BEGIN{for(i=1;i<=n;i++) printf "%0*d\n", w, i}' \
	     | curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" -X PUT \
	       -H 'Content-Type: text/plain' -H 'X-IBM-Data-Type: text' \
	       --data-binary @- "${BASE_URL}/zosmf/restfiles/ds/${TEST_DS}")
	got=$(curl -s -u "$AUTH" "${BASE_URL}/zosmf/restfiles/ds/${TEST_DS}" | grep -c .)
	echo "$st $got"
}

echo "=== mvsMF out-of-space write (#366) ==="
echo

echo "Allocating ${TEST_DS} (PS FB/${LRECL}, BLKSIZE ${BLKSIZE}, TRK(1,0))..."
curl -s -o /dev/null -X DELETE -u "$AUTH" "${BASE_URL}/zosmf/restfiles/ds/${TEST_DS}"
alloc=$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" -X POST \
	-H 'Content-Type: application/json' \
	-d "{\"dsorg\":\"PS\",\"alcunit\":\"TRK\",\"primary\":1,\"secondary\":0,\"recfm\":\"FB\",\"blksize\":${BLKSIZE},\"lrecl\":${LRECL}}" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_DS}")
case "$alloc" in
	20*|201) info "allocated (${alloc})" ;;
	*) echo "  FAIL: allocate returned ${alloc}"; exit 1 ;;
esac
echo

# --- capacity: the largest N that is stored in full -----------------------
# Device geometry differs per volume (3350 vs 3390 vs ...), so measure it
# rather than assume it. A count "fits" only when the status says so AND the
# records are actually there -- the whole point of #366 is that those two
# can disagree.
echo "Measuring capacity by bisection..."
lo=1
hi=512
while [ $lo -lt $hi ]; do
	mid=$(( (lo + hi + 1) / 2 ))
	read -r st got <<<"$(put $mid)"
	if [ "$st" = "204" ] && [ "$got" -eq "$mid" ]; then
		lo=$mid
	else
		hi=$((mid - 1))
	fi
done
CAP=$lo
info "capacity: ${CAP} records (${BLKFACT} per block)"

if [ "$CAP" -lt "$BLKFACT" ]; then
	fail "capacity ${CAP} is below one block -- cannot exercise the boundary"
	exit 1
fi
echo

# --- 1. a PUT that fits must still be reported as success -----------------
read -r st got <<<"$(put "$CAP")"
if [ "$st" = "204" ] && [ "$got" -eq "$CAP" ]; then
	pass "a PUT that exactly fills the data set answers 204 with all records"
else
	fail "a full-but-fitting PUT of ${CAP} answered ${st} with ${got} records"
fi

# --- 2. the block-completing record must be reported ----------------------
# This is #366 itself. The first multiple of the blocking factor above the
# capacity is the record whose write completes a block, so its failure
# happens inside the PUT, where mvsMF can see it. Answering 204 here means
# the fflush() return value is being discarded again.
BOUND=$(( (CAP / BLKFACT + 1) * BLKFACT ))
read -r st got <<<"$(put "$BOUND")"
if [ "$st" = "204" ]; then
	fail "a PUT of ${BOUND} records answered 204 with only ${got} stored" \
	     "#366 regression: the out-of-space fflush() is not being checked"
else
	pass "a PUT whose last record completes a block is reported (${st}, ${got} stored)"
fi

# --- 3. nothing above the boundary may be silent --------------------------
silent_above=0
for extra in 1 2 5; do
	n=$((BOUND + extra))
	read -r st got <<<"$(put "$n")"
	if [ "$st" = "204" ] && [ "$got" -lt "$n" ]; then
		silent_above=$((silent_above + 1))
		info "N=${n}: 204 with ${got} stored"
	fi
done
if [ "$silent_above" -eq 0 ]; then
	pass "no silent loss above the block boundary"
else
	fail "${silent_above} counts above the boundary still answer 204 with records missing"
fi

# --- 4. the known CLOSE-time gap, reported but not failed -----------------
# A partial last block goes out at CLOSE, where libc370 reports nothing at
# all. Keep it visible: when libc370#182 lands this band should shrink to
# zero, and this block is where that will show.
gap=0
n=$((CAP + 1))
while [ "$n" -lt "$BOUND" ]; do
	read -r st got <<<"$(put "$n")"
	[ "$st" = "204" ] && [ "$got" -lt "$n" ] && gap=$((gap + 1))
	n=$((n + 1))
done
echo
if [ "$gap" -gt 0 ]; then
	echo "  KNOWN GAP: ${gap} record counts between ${CAP} and ${BOUND} answer 204"
	echo "             with records missing (partial last block, written at CLOSE)."
	echo "             Not a defect in this repo -- libc370#182. When that is"
	echo "             fixed this number should reach 0."
else
	echo "  NOTE: the CLOSE-time gap is gone -- libc370#182 appears to be fixed."
	echo "        Tighten this test to assert 0 rather than report it."
fi

echo
echo "========================================================================="
echo "  Passed:  ${PASSED}"
echo "  Failed:  ${FAILED}"
echo "  Total:   ${TOTAL}"
echo "========================================================================="
[ "$FAILED" -eq 0 ]
