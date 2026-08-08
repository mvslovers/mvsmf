#!/bin/bash
# tests/soak-176.sh — long-running mixed console load.
#
# Usage: nohup ./tests/soak-176.sh > /dev/null 2>&1 &
#        tail -f soak-176-*.log
#
# Tunables (env): DELAY SLOW_SECS MAXTIME RING_EVERY SOAK_HERC_LOG
#
# WHAT THIS IS FOR
#   Originally written to hunt the intermittent console S0C4 (#176) and kept as
#   the load-validation harness the release epic (#185) asks for. It has since
#   found a second, different failure: the server HANGS under sustained load
#   (#217) rather than faulting.
#
# WHY IT CAPTURES THE WAY IT DOES
#   The first #217 run produced two 0-byte snapshots. It only reacted to a
#   FAILED request, and by then the server was gone, so the capture requests
#   failed too. Everything below follows from that:
#
#     - trip on a SLOW response, not a failed one, so the capture happens while
#       the server may still be partly alive;
#     - classify what is still answering (see triage()) instead of assuming;
#     - keep a rolling pre-failure MTT snapshot, because the state that explains
#       a hang is the state from BEFORE it.

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
TRIAGE="soak-triage-${STAMP}.txt"

DELAY="${DELAY:-0.5}"
# Trip the triage well below the hard timeout. The console sync capture polls
# for ~3 s by design, so anything past ~15 s is already abnormal, and waiting
# out a 90 s timeout is how the first run lost its evidence.
SLOW_SECS="${SLOW_SECS:-15}"
MAXTIME="${MAXTIME:-45}"
RING_EVERY="${RING_EVERY:-50}"     # rolling MTT snapshot cadence, in iterations
RING_KEEP=3
# Optional: user@host:/path/to/hercules.log — the abend/console evidence lives
# on the emulator host, not in any HTTP response.
HERC_LOG="${SOAK_HERC_LOG:-}"

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

# ---------------------------------------------------------------------------
# triage — the point of the whole harness
#
# A hang looks the same from one endpoint no matter what caused it. This ladder
# runs from "no mvsMF involved" to "the console path", each with a short
# timeout, and the pattern of what still answers says which layer is stuck:
#
#   everything answers        -> the slow request was an outlier, not a wedge
#   httpd yes, mvsMF no       -> the module cannot be loaded (the S80A shape,
#                                i.e. storage — see #212 / httpd#154)
#   mvsMF yes, console no     -> a console-specific hang; suspect shared state
#                                (the ntstore latch in consapi/ntstore.c is one
#                                candidate: held across an abend it is never
#                                released)
#   nothing answers           -> every worker is parked; whatever holds them is
#                                upstream of the console handlers
#
# Read the STATUS CODE as "did something answer", not as "was it happy".
# httpd-root answers 404 on a healthy system (no index document) and that is a
# pass for this purpose: httpd took the connection and replied. What matters is
# the boundary in the ladder where answers stop, and how long each one took.
# ---------------------------------------------------------------------------
triage() { # triage <why>
	{
		echo ""
		echo "=== TRIAGE ($1) n=$N at $(date) ==="
		while IFS='|' read -r name url; do
			[ -z "$name" ] && continue
			printf '  %-14s ' "$name"
			curl -s -o /dev/null -m 10 -u "$AUTH" \
				-w 'HTTP %{http_code}  %{time_total}s\n' "$url" \
				|| echo "no answer within 10s"
		done <<-PROBES
			httpd-root|$BASE/
			httpd-jes|$BASE/jes/status
			mvsmf-info|$BASE/zosmf/info
			mvsmf-version|$BASE/zosmf/test?fn=version
			console-log|$BASE/zosmf/restconsoles/v1/log?timeRange=5m
		PROBES
	} 2>&1 | tee -a "$TRIAGE" | tee -a "$LOG"

	if [ -n "$HERC_LOG" ]; then
		local hhost="${HERC_LOG%%:*}"
		local hpath="${HERC_LOG#*:}"
		echo "  capturing hercules log tail from $hhost" | tee -a "$LOG"
		ssh -o ConnectTimeout=10 "$hhost" "tail -300 '$hpath'" \
			> "herc-at-fail-${STAMP}.log" 2>/dev/null \
			&& echo "  -> herc-at-fail-${STAMP}.log" | tee -a "$LOG"
	fi
}

# Rolling MTT snapshot. A hang is explained by the state BEFORE it, which is
# exactly the state a post-mortem capture can no longer reach.
ring_snapshot() {
	local f="mtt-ring-${STAMP}-$((N / RING_EVERY % RING_KEEP)).json"
	curl -s -m 20 -u "$AUTH" "$BASE/zosmf/test?fn=mtt&step=3" > "$f" 2>/dev/null
}

req() { # req <label> <curl args...>
	local label="$1"
	shift
	local out code secs

	out=$(curl -s -o /dev/null -m "$MAXTIME" \
		-w '%{http_code} %{time_total}' "$@")
	code="${out%% *}"
	secs="${out##* }"

	echo "$(date +%H:%M:%S) $N $label $code ${secs}s" >>"$LOG"

	# slow but still answering: capture NOW, while there is something to ask
	if [ "$code" = "200" ] &&
	   [ "$(printf '%.0f' "${secs:-0}" 2>/dev/null || echo 0)" -ge "$SLOW_SECS" ]; then
		echo "SLOW n=$N label=$label ${secs}s at $(date)" | tee -a "$LOG"
		triage "slow response: $label took ${secs}s"
		return 0
	fi

	if [ "$code" != "200" ]; then
		echo "FAILED n=$N label=$label code=$code at $(date)" | tee -a "$LOG"
		triage "request failed: $label code=$code"
		echo "evidence: $LOG $TRIAGE mtt-ring-${STAMP}-*.json" | tee -a "$LOG"
		exit 1
	fi
}

echo "soak started $(date) base=$BASE" | tee "$LOG"
echo "  slow>=${SLOW_SECS}s  maxtime=${MAXTIME}s  ring every ${RING_EVERY}" | tee -a "$LOG"
[ -n "$HERC_LOG" ] && echo "  hercules log: $HERC_LOG" | tee -a "$LOG"
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
		# unsol_sync — holds a worker in the poll loop.
		# Dominant heap-churn driver: cmtt_new/cmtt_free per iteration.
		req "unsol" -X PUT "$CONSOLE" -u "$AUTH" -H "$CT" -H "$CSRF" \
			-d '{"cmd":"D T","unsol-key":"ZZZNOMATCH","unsol-detect-sync":"Y","unsol-detect-timeout":"10"}'
	fi

	[ $((N % RING_EVERY)) -eq 0 ] && ring_snapshot

	if [ $((N % 100)) -eq 0 ]; then
		ELAPSED=$(($(date +%s) - START))
		echo "$(date +%H:%M:%S) --- n=$N elapsed=${ELAPSED}s" | tee -a "$LOG"
	fi

	sleep "$DELAY"
done
