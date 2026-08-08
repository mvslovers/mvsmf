#!/bin/bash
# tests/loadtest-176.sh — hunt the intermittent S0C4 in the console handler
# Usage: ./tests/loadtest-176.sh <A|B|C> [iterations]
#   A = full PUT      (MGCR + capture_response + correlate_once + nt_set)
#   B = /test fn=cmd  (MGCR + MTT poll, no correlate_once, no nt_set)
#   C = /v1/log       (MTT read only, no command)
# Restart the HTTPD STC before every run.

set -u
[ -f .env ] && . ./.env

# The other suites in tests/ read MVSMF_*; deploy tooling sets MBT_MVS_*.
# Accept either so this runs from the same .env as everything else.
MVSMF_HOST="${MVSMF_HOST:-${MBT_MVS_HOST:-}}"
MVSMF_PORT="${MVSMF_PORT:-${MBT_MVS_PORT:-}}"
MVSMF_USER="${MVSMF_USER:-${MBT_MVS_USER:-}}"
MVSMF_PASS="${MVSMF_PASS:-${MBT_MVS_PASS:-}}"


ARM="${1:?arm required: A, B or C}"
N="${2:-500}"
BASE="http://${MVSMF_HOST}:${MVSMF_PORT}"
AUTH="${MVSMF_USER}:${MVSMF_PASS}"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="loadtest-176-${ARM}-${STAMP}.log"

echo "arm=$ARM iterations=$N base=$BASE" | tee "$LOG"

for i in $(seq 1 "$N"); do
	case "$ARM" in
	A) code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
		"$BASE/zosmf/restconsoles/consoles/defcn" -u "$AUTH" \
		-H 'Content-Type: application/json' \
		-H 'X-CSRF-ZOSMF-HEADER: true' \
		-d '{"cmd":"D T","async":"N"}') ;;
	B) code=$(curl -s -o /dev/null -w '%{http_code}' \
		"$BASE/zosmf/test?fn=cmd&cmd=D+T" -u "$AUTH") ;;
	C) code=$(curl -s -o /dev/null -w '%{http_code}' \
		"$BASE/zosmf/restconsoles/v1/log" -u "$AUTH") ;;
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
		curl -s "$BASE/zosmf/test?fn=mtt&step=3" -u "$AUTH" \
			>"mtt-at-fail-${ARM}-${STAMP}.json"
		curl -s "$BASE/zosmf/restconsoles/v1/log" -u "$AUTH" \
			>"log-at-fail-${ARM}-${STAMP}.json"
		echo "snapshots written" | tee -a "$LOG"
		exit 1
	fi
done

echo "arm=$ARM survived $N iterations" | tee -a "$LOG"
