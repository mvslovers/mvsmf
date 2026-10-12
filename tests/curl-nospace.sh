#!/bin/bash
# =========================================================================
# mvsMF Datasets REST API - out-of-space write test (#366, #371)
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
# A PUT whose last block is PARTIAL fails later, at CLOSE: libc370's
# @@ACLOSE writes that block, and fclose() reports it since libc370#182 --
# EOF with errno ENOSPC. mvsMF discarded that result until #371, so the
# counts between the capacity and the next block boundary answered 204 with
# records missing. And a body smaller than one block, written as a member
# into a full PDS, answered 204 and left a member with no records at all.
# Both must answer 500 now.
#
# Prerequisites:
#   - Run through mbt (see Usage), which hands over the target's
#     connection (tests/lib/conn.sh)
#   - curl must be installed
#
# Usage:
#   mbt run rest-tests -- curl-nospace
# =========================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/lib/conn.sh"

TEST_DS="${MVSMF_USER}.CURL.NOSPACE"
TEST_PDS="${MVSMF_USER}.CURL.NOSPACE.PDS"

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
	curl -s -o /dev/null -X DELETE -K "$MVSMF_CURLRC" "${BASE_URL}/zosmf/restfiles/ds/${TEST_DS}"
	curl -s -o /dev/null -X DELETE -K "$MVSMF_CURLRC" "${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}"
}
mvsmf_on_exit cleanup

# put <n>  -> echoes "<status> <records on disk>"
put() {
	local n=$1 st got
	st=$(awk -v n="$n" -v w=$((LRECL - 8)) \
	       'BEGIN{for(i=1;i<=n;i++) printf "%0*d\n", w, i}' \
	     | curl -s -o /dev/null -w '%{http_code}' -K "$MVSMF_CURLRC" -X PUT \
	       -H 'Content-Type: text/plain' -H 'X-IBM-Data-Type: text' \
	       --data-binary @- "${BASE_URL}/zosmf/restfiles/ds/${TEST_DS}")
	got=$(curl -s -K "$MVSMF_CURLRC" "${BASE_URL}/zosmf/restfiles/ds/${TEST_DS}" | grep -c .)
	echo "$st $got"
}

echo "=== mvsMF out-of-space write (#366, #371) ==="
echo

echo "Allocating ${TEST_DS} (PS FB/${LRECL}, BLKSIZE ${BLKSIZE}, TRK(1,0))..."
curl -s -o /dev/null -X DELETE -K "$MVSMF_CURLRC" "${BASE_URL}/zosmf/restfiles/ds/${TEST_DS}"
alloc=$(curl -s -o /dev/null -w '%{http_code}' -K "$MVSMF_CURLRC" -X POST \
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

# --- 4. nor below it: a partial last block fails at CLOSE (#371) -----------
# Every count between the capacity and the boundary ends in a partial block,
# which goes out in fclose(). Its failure is the only report of those records.
silent_close=0
n=$((CAP + 1))
while [ "$n" -lt "$BOUND" ]; do
	read -r st got <<<"$(put "$n")"
	if [ "${st:0:1}" = "2" ] && [ "$got" -lt "$n" ]; then
		silent_close=$((silent_close + 1))
		info "N=${n}: ${st} with ${got} stored"
	fi
	n=$((n + 1))
done
if [ "$silent_close" -eq 0 ]; then
	pass "no silent loss below the block boundary (partial last block, CLOSE)"
else
	fail "${silent_close} counts between ${CAP} and ${BOUND} answer 2xx with records missing" \
	     "#371: the fclose() result is not being checked"
fi

# --- 5. a member smaller than one block into a full PDS (#371) -------------
# The shape that lost a whole body: no record of it completes a block, so no
# fflush() fails, and the one block it fills is written at CLOSE. Fill a
# one-track PDS first; that PUT itself is #366's case and must fail too.
echo
echo "Allocating ${TEST_PDS} (PO FB/${LRECL}, BLKSIZE ${BLKSIZE}, TRK(1,0), 1 directory block)..."
curl -s -o /dev/null -X DELETE -K "$MVSMF_CURLRC" "${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}"
alloc=$(curl -s -o /dev/null -w '%{http_code}' -K "$MVSMF_CURLRC" -X POST \
	-H 'Content-Type: application/json' \
	-d "{\"dsorg\":\"PO\",\"alcunit\":\"TRK\",\"primary\":1,\"secondary\":0,\"dirblk\":1,\"recfm\":\"FB\",\"blksize\":${BLKSIZE},\"lrecl\":${LRECL}}" \
	"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}")
case "$alloc" in
	20*) info "allocated (${alloc})" ;;
	*) fail "allocate ${TEST_PDS} returned ${alloc}" ;;
esac

if [ "${alloc:0:1}" = "2" ]; then
	# put_member <member> <records>  -> echoes the status
	put_member() {
		awk -v n="$2" -v w=$((LRECL - 8)) \
		    'BEGIN{for(i=1;i<=n;i++) printf "%0*d\n", w, i}' \
		| curl -s -o /dev/null -w '%{http_code}' -K "$MVSMF_CURLRC" -X PUT \
		  -H 'Content-Type: text/plain' -H 'X-IBM-Data-Type: text' \
		  --data-binary @- "${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}($1)"
	}

	st=$(put_member FILL $((CAP + 4 * BLKFACT)))
	case "$st" in
		2*) fail "filling ${TEST_PDS} with more than a track answered ${st}" ;;
		*)  info "filled: FILL answered ${st}" ;;
	esac

	# A short block can still fit where a full one did not, so a small member
	# may legitimately land in the rest of the track. Add them until one does
	# not fit; that one must not answer 2xx.
	small=$((BLKFACT / 2))
	verdict=""
	for i in 1 2 3 4 5 6 7 8; do
		st=$(put_member "SMALL${i}" "$small")
		if [ "${st:0:1}" != "2" ]; then
			pass "a member smaller than one block into a full PDS is reported (${st})"
			verdict=done
			break
		fi
		got=$(curl -s -K "$MVSMF_CURLRC" "${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(SMALL${i})" | grep -c .)
		if [ "$got" -lt "$small" ]; then
			fail "a ${small}-record member into the full PDS answered ${st} with ${got} stored" \
			     "#371: the whole body sat in the block written at CLOSE"
			verdict=done
			break
		fi
		info "SMALL${i}: ${small} records still fit (${st})"
	done
	[ -n "$verdict" ] || fail "eight ${small}-record members fit after the PDS was full" \
		"the full-PDS case was not exercised"
fi

echo
echo "========================================================================="
echo "  Passed:  ${PASSED}"
echo "  Failed:  ${FAILED}"
echo "  Total:   ${TOTAL}"
echo "========================================================================="
[ "$FAILED" -eq 0 ]
