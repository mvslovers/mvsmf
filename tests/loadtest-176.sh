#!/bin/bash
# tests/loadtest-176.sh — hunt the intermittent S0C4 in the console handler
# Usage: mbt run rest-tests -- loadtest-176 <A|B|C> [iterations]
#   A = full PUT      (MGCR + capture_response + correlate_once + nt_set)
#   B = /test fn=cmd  (MGCR + MTT poll, no correlate_once, no nt_set)
#   C = /v1/log       (MTT read only, no command)
# Restart the HTTPD STC before every run.

set -u
# The connection comes from the mbt target (tests/lib/conn.sh): run this
# through `mbt run rest-tests -- loadtest-176`.
. "$(dirname "$0")/lib/conn.sh"


ARM="${1:?arm required: A, B or C}"
N="${2:-500}"
BASE="$BASE_URL"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="loadtest-176-${ARM}-${STAMP}.log"

echo "arm=$ARM iterations=$N base=$BASE" | tee "$LOG"

for i in $(seq 1 "$N"); do
	case "$ARM" in
	A) code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
		"$BASE/zosmf/restconsoles/consoles/defcn" -K "$MVSMF_CURLRC" \
		-H 'Content-Type: application/json' \
		-H 'X-CSRF-ZOSMF-HEADER: true' \
		-d '{"cmd":"D T","async":"N"}') ;;
	B) code=$(curl -s -o /dev/null -w '%{http_code}' \
		"$BASE/zosmf/test?fn=cmd&cmd=D+T" -K "$MVSMF_CURLRC") ;;
	C) code=$(curl -s -o /dev/null -w '%{http_code}' \
		"$BASE/zosmf/restconsoles/v1/log" -K "$MVSMF_CURLRC") ;;
	*)
		echo "unknown arm: $ARM"
		exit 2
		;;
	esac

	echo "$i $code" >>"$LOG"
	[ $((i % 25)) -eq 0 ] && echo "  ... $i ($code)"

	if [ "$code" != "200" ]; then
		echo "FAILED arm=$ARM N=$i code=$code" | tee -a "$LOG"
		# snapshot while the address space is still alive
		curl -s "$BASE/zosmf/test?fn=mtt&step=3" -K "$MVSMF_CURLRC" \
			>"mtt-at-fail-${ARM}-${STAMP}.json"
		curl -s "$BASE/zosmf/restconsoles/v1/log" -K "$MVSMF_CURLRC" \
			>"log-at-fail-${ARM}-${STAMP}.json"
		echo "snapshots written" | tee -a "$LOG"
		exit 1
	fi
done

echo "arm=$ARM survived $N iterations" | tee -a "$LOG"
