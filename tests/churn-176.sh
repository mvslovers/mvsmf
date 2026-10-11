#!/bin/bash
# tests/churn-176.sh — concurrent unsol churn, every request reports
set -u
# The connection comes from the mbt target (tests/lib/conn.sh): run this
# through `mbt run rest-tests -- churn-176`.
. "$(dirname "$0")/lib/conn.sh"

B="$BASE_URL"
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
			c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 90 -X PUT "$CONS" -K "$MVSMF_CURLRC" \
				-H "$CT" -H "$CSRF" \
				-d '{"cmd":"D T","unsol-key":"ZZZNOMATCH","unsol-detect-sync":"Y","unsol-detect-timeout":"20"}')
		else
			c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 90 -X PUT "$CONS" -K "$MVSMF_CURLRC" \
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
