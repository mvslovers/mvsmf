#!/bin/bash
# tests/watch-workers.sh — catch the FIRST httpd worker that wedges, and record
# the exact instruction it is sitting on.
#
# Usage:  ./tests/watch-workers.sh &            # alongside a soak run
#         SOAKLOG=soak-176-*.log ./tests/watch-workers.sh &
#
# Tunables (env): INTERVAL SOAKLOG HERC_HOST HERC_PORT SSH_HOST HERC_LOG
#
# WHY
#   Under sustained console load, workers stop dispatching one at a time while
#   still reporting STATE RUNNING (#217). The server keeps serving on the ones
#   that are left, so nothing is visible until the last one goes -- by which
#   point the server answers nothing and cannot be interrogated at all.
#
#   The window between the first wedge and the last is long (half an hour or
#   more was observed). This watches for the first one, while the server is
#   still healthy enough to answer questions about itself.
#
# HOW IT READS THE WEDGED TASK
#   Through httpd's own .dm CGI, NOT through the Hercules storage display.
#   Hercules resolves addresses in whatever address space is currently
#   dispatched, and TCBs live in private storage -- reading a worker TCB that
#   way returns unrelated bytes (it looks like plausible code, which makes the
#   mistake easy to miss). .dm runs inside httpd, so the addresses mean what
#   they say.
#
#   The chain, verified against a healthy worker:
#       TCB +00       -> RBP, the current request block
#       RB  +10       -> RBOPSW: mask, then the instruction address
#       RB  +1C       -> links back to the TCB (use this to confirm)
#
#   Sampling that address several times says whether the task is looping and
#   over what span -- which is what distinguishes a loop from a long operation,
#   and what no amount of system-wide PSW sampling can tell you.
#
# NOTE ON BASH
#   /bin/bash on macOS is 3.2: no associative arrays. Per-round state is kept
#   in a temp file deliberately, not as a style choice.

set -u
[ -f .env ] && . ./.env

# The other suites in tests/ read MVSMF_*; deploy tooling sets MBT_MVS_*.
MVSMF_HOST="${MVSMF_HOST:-${MBT_MVS_HOST:-}}"
MVSMF_PORT="${MVSMF_PORT:-${MBT_MVS_PORT:-}}"
MVSMF_USER="${MVSMF_USER:-${MBT_MVS_USER:-}}"
MVSMF_PASS="${MVSMF_PASS:-${MBT_MVS_PASS:-}}"

BASE_HTTP="http://${MVSMF_HOST}:${MVSMF_PORT}"
AUTH="${MVSMF_USER}:${MVSMF_PASS}"

# Hercules' own HTTP server, used only to issue MVS console commands.
HERC_HOST="${HERC_HOST:-$MVSMF_HOST}"
HERC_PORT="${HERC_PORT:-8181}"
HERC="http://${HERC_HOST}:${HERC_PORT}/cgi-bin/api/v1/syslog"

# The emulator host's log, where httpd's replies land. Optional: without ssh
# access the thread display cannot be read back and this script cannot work.
SSH_HOST="${SSH_HOST:-$MVSMF_HOST}"
HERC_LOG="${HERC_LOG:-/home/mike/MVSCE/hercules.log}"

INTERVAL="${INTERVAL:-90}"
SOAKLOG="${SOAKLOG:-}"
OUT="worker-watch-$(date +%Y%m%d-%H%M%S).txt"

herc() { curl -s -m 20 -G --data-urlencode "command=$1" "$HERC" >/dev/null; }

dm() { # dm <addr> [len] -> "+00000 wwwwwwww wwwwwwww ..."
	curl -s -m 30 -u "$AUTH" "$BASE_HTTP/.dm?memory=$1&length=${2:-48}&chunk=16" \
		| LC_ALL=C sed -e 's/<[^>]*>/ /g' | LC_ALL=C tr -s ' \n' ' \n' | grep -aE '^\+'
}

resume_psw() { # resume_psw <tcb>
	local rb psw back
	rb=$(dm "$1" 16 | head -1 | awk '{print $2}')
	if [ -z "$rb" ]; then echo "  TCB $1: unreadable"; return; fi
	psw=$(dm "$rb" 32 | awk '$1=="+00010" {print $2, $3}')
	back=$(dm "$rb" 32 | awk '$1=="+00010" {print $5}')
	echo "  TCB $1  RB $rb  RBOPSW $psw  (RB+1C=$back)"
}

# One "tcb disp state" line per worker, newest state only: the log tail can
# span more than one D THREADS block and a round must never mix two dumps.
snap() {
	herc "/F HTTPD,D THREADS"
	sleep 6
	ssh -o ConnectTimeout=10 "$SSH_HOST" "tail -220 '$HERC_LOG'" 2>/dev/null | awk '
		/HTTPD104I/ { for(i=1;i<=NF;i++) if($i ~ /TCB$/ && $i !~ /OWNTCB/) tcb=$(i+1) }
		/HTTPD114I/ { st=$NF }
		/HTTPD117I/ { d=""
		              for(i=1;i<=NF;i++) if($i ~ /^[0-9A-F]{16}$/) d=$i
		              if (tcb != "" && d != "") print tcb, d, st
		              tcb=""; d=""; st="" }' \
		| awk '{ last[$1] = $0 } END { for (k in last) print last[k] }'
}

echo "watching every ${INTERVAL}s -> $OUT" | tee "$OUT"
PREV=$(mktemp)
trap 'rm -f "$PREV"' EXIT
round=0

while true; do
	round=$((round + 1))
	now=$(snap)
	if [ -z "$now" ]; then
		echo "$(date +%H:%M:%S) round $round: no thread data (server gone?)" | tee -a "$OUT"
		sleep "$INTERVAL"; continue
	fi

	stuck=""
	while read -r tcb disp state; do
		[ -z "${tcb:-}" ] && continue
		# RUNNING with an unchanged dispatch stamp across a whole interval:
		# it is not serving a slow request, it has stopped coming back.
		if [ "$state" = "RUNNING" ] && grep -q "^$tcb $disp\$" "$PREV" 2>/dev/null; then
			stuck="$stuck $tcb"
		fi
	done <<< "$now"
	echo "$now" | awk '{print $1, $2}' > "$PREV"

	{
		echo "$(date +%H:%M:%S) round $round:"
		echo "$now" | sed 's/^/    /'
	} | tee -a "$OUT"

	if [ -n "$stuck" ]; then
		{
			echo ""
			echo "*** WEDGED (RUNNING, dispatch frozen across ${INTERVAL}s):$stuck"
			echo ""
			echo "--- resume PSW, 5 samples 4s apart ---"
			echo "    a fixed or narrowly ranging address is the loop"
		} | tee -a "$OUT"

		for pass in 1 2 3 4 5; do
			echo "  pass $pass:" | tee -a "$OUT"
			for t in $stuck; do resume_psw "$t" | tee -a "$OUT"; done
			sleep 4
		done

		echo "--- httpd stats ---" | tee -a "$OUT"
		herc "/F HTTPD,D STATS"; sleep 5
		ssh "$SSH_HOST" "tail -12 '$HERC_LOG'" 2>/dev/null | grep -E "HTTPD41[12]I" | tee -a "$OUT"

		echo "--- hercules tail ---" | tee -a "$OUT"
		ssh "$SSH_HOST" "tail -60 '$HERC_LOG'" >> "$OUT" 2>/dev/null

		if [ -n "$SOAKLOG" ] && [ -f "$SOAKLOG" ]; then
			echo "--- soak requests in flight (last 25) ---" | tee -a "$OUT"
			tail -25 "$SOAKLOG" | tee -a "$OUT"
		fi

		echo "*** evidence in $OUT" | tee -a "$OUT"
		exit 0
	fi

	sleep "$INTERVAL"
done
