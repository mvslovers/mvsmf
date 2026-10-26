#!/bin/bash
# =========================================================================
# mvsMF data set list under parallel requests - curl test suite (#436)
#
# GET /zosmf/restfiles/ds?dslevel=... lists through libc370's __listds(),
# which has IDCAMS write LISTC output into a temporary data set and reads it
# back. The data set is named by tmpnam(), whose counter starts again at 1 in
# every request, so its system name is SYSyyddd.Thhmmss.RA000.<job>.TMP00001:
# the same for two requests that start in the same second. One request's
# close scratched the data set the other was about to open, and the other
# abended S213-04 -- HTTP 500 and MVSMF901E, between 1 request in 30 and 1 in
# 55 at 4 in parallel (11 of 600, 14 of 400).
#
# This suite fires N requests, P at a time, and requires every one of them to
# be answered 200 with the one entry the level names. A wrong answer counts as
# much as a 500: two requests that shared the LISTC output would not abend,
# they would list the wrong thing.
#
# The level is SYS1.PARMLIB, which every MVS 3.8j system has.
#
# Prerequisites:
#   - Run through mbt (see Usage), which hands over the target's
#     connection (tests/lib/conn.sh)
#   - curl must be installed
#
# Usage:
#   mbt run rest-tests -- curl-dslist-parallel
#   DSLIST_REQUESTS=800 DSLIST_PARALLEL=8 mbt run rest-tests -- curl-dslist-parallel
#
# N and P come from DSLIST_REQUESTS (default 400) and DSLIST_PARALLEL (default
# 4), not from arguments: mbt hands every argument after the suite names to
# every shell suite, so a flag meant for another suite (--setup) must be
# harmless here.
# =========================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "${SCRIPT_DIR}/lib/conn.sh"

REQUESTS="${DSLIST_REQUESTS:-400}"
PARALLEL="${DSLIST_PARALLEL:-4}"
LEVEL="SYS1.PARMLIB"

case "$REQUESTS$PARALLEL" in
	*[!0-9]*|"") echo "ERROR: DSLIST_REQUESTS and DSLIST_PARALLEL must be numbers" >&2; exit 1 ;;
esac

OUT="${MVSMF_CONN_DIR}/dslist"
mkdir -p "$OUT"

PASSED=0
FAILED=0

pass() { PASSED=$((PASSED + 1)); echo "  PASS: $1"; }
fail() {
	FAILED=$((FAILED + 1)); echo "  FAIL: $1"
	[ -n "${2:-}" ] && echo "        $2"
}

echo "=== ${REQUESTS} x GET /zosmf/restfiles/ds?dslevel=${LEVEL}, ${PARALLEL} at a time ==="

export MVSMF_CURLRC OUT
export URL="${BASE_URL}/zosmf/restfiles/ds?dslevel=${LEVEL}"

seq "$REQUESTS" | xargs -P "$PARALLEL" -I{} bash -c '
	code=$(curl -s -K "$MVSMF_CURLRC" -o "$OUT/body.{}" -w "%{http_code}" "$URL")
	printf "%s\n" "$code" > "$OUT/code.{}"
'

answered=$(find "$OUT" -name 'code.*' | wc -l | tr -d ' ')
if [ "$answered" = "$REQUESTS" ]; then
	pass "every request was answered ($answered)"
else
	fail "every request was answered" "$answered of $REQUESTS wrote a status"
fi

# One 200 per request, and nothing else.
not200=$(cat "$OUT"/code.* | grep -vc '^200$')
if [ "$not200" = "0" ]; then
	pass "all ${REQUESTS} answered 200"
else
	fail "all ${REQUESTS} answered 200" \
		"$not200 did not: $(cat "$OUT"/code.* | grep -v '^200$' | sort | uniq -c | tr '\n' ' ')"
fi

# A 200 must carry exactly the entry the level names: not an empty list, not
# another request's listing.
wrong=0
for b in "$OUT"/body.*; do
	[ "$(cat "${OUT}/code.${b##*.}" 2>/dev/null)" = "200" ] || continue
	n=$(grep -c "\"dsname\": \"${LEVEL}\"" "$b")
	m=$(grep -c '"dsname"' "$b")
	if [ "$n" != "1" ] || [ "$m" != "1" ]; then
		wrong=$((wrong + 1))
	fi
done
if [ "$wrong" = "0" ]; then
	pass "every 200 lists ${LEVEL}, once and nothing else"
else
	fail "every 200 lists ${LEVEL}, once and nothing else" "$wrong bodies differ"
fi

# The server is still serving after the load.
code=$(curl -s -K "$MVSMF_CURLRC" -o /dev/null -w '%{http_code}' "$URL")
if [ "$code" = "200" ]; then
	pass "a request after the run is answered 200"
else
	fail "a request after the run is answered 200" "got HTTP $code"
fi

echo
echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
