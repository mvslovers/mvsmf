#!/bin/bash
# tests/churn-176.sh — concurrent unsol churn, every request reports
set -u
[ -f .env ] && . ./.env

# The other suites in tests/ read MVSMF_*; deploy tooling sets MBT_MVS_*.
# Accept either so this runs from the same .env as everything else.
MVSMF_HOST="${MVSMF_HOST:-${MBT_MVS_HOST:-}}"
MVSMF_PORT="${MVSMF_PORT:-${MBT_MVS_PORT:-}}"
MVSMF_USER="${MVSMF_USER:-${MBT_MVS_USER:-}}"
MVSMF_PASS="${MVSMF_PASS:-${MBT_MVS_PASS:-}}"

B="http://${MVSMF_HOST}:${MVSMF_PORT}"
A="${MVSMF_USER}:${MVSMF_PASS}"
CT='Content-Type: application/json'
CSRF='X-CSRF-ZOSMF-HEADER: true'
CONS="$B/zosmf/restconsoles/consoles/defcn"
LOG="churn-176-$(date +%H%M%S).log"
THREADS="${THREADS:-4}"

echo "start $(date) threads=$THREADS" | tee "$LOG"

worker() { # $1 = id, $2 = mode
	local n=0 c
	while true; do
		n=$((n + 1))
		if [ "$2" = "unsol" ]; then
			c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 90 -X PUT "$CONS" -u "$A" \
				-H "$CT" -H "$CSRF" \
				-d '{"cmd":"D T","unsol-key":"ZZZNOMATCH","unsol-detect-sync":"Y","unsol-detect-timeout":"20"}')
		else
			c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 90 -X PUT "$CONS" -u "$A" \
				-H "$CT" -H "$CSRF" -d '{"cmd":"D T","async":"N"}')
		fi
		echo "$(date +%H:%M:%S) t$1 $n $c" >>"$LOG"
		case "$c" in
		200) ;;
		000) ;; # client timeout / reset -- not a server error
		*) echo "HIT t$1 n=$n code=$c $(date)" | tee -a "$LOG" ;;
		esac
		sleep 0.2
	done
}

for i in $(seq 1 "$THREADS"); do worker "$i" unsol & done
worker P plain &
echo "running -- Ctrl-C to stop; watch for HIT lines in the log"
wait
