#!/bin/bash
# tests/soak-176.sh — long-running mixed-load soak hunting the console S0C4
# Usage: nohup ./tests/soak-176.sh > /dev/null 2>&1 &
#        tail -f soak-176-*.log

set -u
[ -f .env ] && . ./.env

# The other suites in tests/ read MVSMF_*; deploy tooling sets MBT_MVS_*.
# Accept either so this runs from the same .env as everything else.
MVSMF_HOST="${MVSMF_HOST:-${MBT_MVS_HOST:-}}"
MVSMF_PORT="${MVSMF_PORT:-${MBT_MVS_PORT:-}}"
MVSMF_USER="${MVSMF_USER:-${MBT_MVS_USER:-}}"
MVSMF_PASS="${MVSMF_PASS:-${MBT_MVS_PASS:-}}"


BASE="http://${MVSMF_HOST}:${MVSMF_PORT}"
AUTH="${MVSMF_USER}:${MVSMF_PASS}"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="soak-176-${STAMP}.log"
DELAY="${DELAY:-0.5}"

# Adjust to commands your system accepts. Variety of OUTPUT SHAPE is the
# point: short vs. long, single- vs. multi-line, and -- since #174 -- replies
# that come from a DIFFERENT address space than the issuer.
#
# The last one matters most now. Correlating a MODIFY reply makes the walk
# process entries the source predicate used to skip, and that is exactly what
# turned a raw mtentlen read into a live S0C4 while #174 was being tested. A
# soak that only issues D-commands never touches that path.
#
# Note for anyone reading an older copy of this file: it used to recommend a
# command producing '+' write-to-programmer WTOs, on the theory that the '+'
# shifted the MTT column layout. That theory was REFUTED on #174 -- the source
# field sits at the same offset either way. Do not spend time on it.
COMMANDS=(
	"D T"
	"D A,L"
	"D U,,,500,4"
	"F UFSD,STATUS"
)

CONSOLE="$BASE/zosmf/restconsoles/consoles/defcn"
CT='Content-Type: application/json'
CSRF='X-CSRF-ZOSMF-HEADER: true'

req() { # req <label> <curl args...>
	local label="$1"
	shift
	local code
	code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 90 "$@")
	echo "$(date +%H:%M:%S) $N $label $code" >>"$LOG"
	if [ "$code" != "200" ]; then
		echo "FAILED n=$N label=$label code=$code at $(date)" | tee -a "$LOG"
		curl -s "$BASE/zosmf/test?fn=mtt&step=3" -u "$AUTH" \
			>"mtt-at-fail-${STAMP}.json"
		curl -s "$BASE/zosmf/restconsoles/v1/log?timeRange=5m" -u "$AUTH" \
			>"log-at-fail-${STAMP}.json"
		exit 1
	fi
}

echo "soak started $(date) base=$BASE" | tee "$LOG"
N=0
START=$(date +%s)

while true; do
	N=$((N + 1))
	R=$((RANDOM % 100))

	if [ "$R" -lt 50 ]; then
		CMD="${COMMANDS[$((RANDOM % ${#COMMANDS[@]}))]}"
		req "cmd[$CMD]" -X PUT "$CONSOLE" -u "$AUTH" \
			-H "$CT" -H "$CSRF" \
			-d "{\"cmd\":\"$CMD\",\"async\":\"N\"}"

	elif [ "$R" -lt 80 ]; then
		req "log45m" "$BASE/zosmf/restconsoles/v1/log?timeRange=45m" -u "$AUTH"

	elif [ "$R" -lt 92 ]; then
		for TR in 5m 15m 2h; do
			req "log$TR" "$BASE/zosmf/restconsoles/v1/log?timeRange=$TR" -u "$AUTH"
		done

	else
		# unsol_sync — holds a worker in the 581-588 poll loop.
		# Dominant heap-churn driver: cmtt_new/cmtt_free per iteration.
		req "unsol" -X PUT "$CONSOLE" -u "$AUTH" -H "$CT" -H "$CSRF" \
			-d '{"cmd":"D T","unsol-key":"ZZZNOMATCH","unsol-detect-sync":"Y","unsol-detect-timeout":"10"}'
	fi

	if [ $((N % 100)) -eq 0 ]; then
		ELAPSED=$(($(date +%s) - START))
		echo "$(date +%H:%M:%S) --- n=$N elapsed=${ELAPSED}s" | tee -a "$LOG"
	fi

	sleep "$DELAY"
done
