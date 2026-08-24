#!/bin/bash
# =========================================================================
# Regression test for issue #214, collect half. Written as a reproduction
# (2/2 on the build before the fix); it is kept as the test because the two
# experiments below are the measurement the fix was designed against.
#
# consoleCollectHandler() re-correlates on every poll instead of resuming.
# It used to anchor on the NEWEST MTT entry whose text CONTAINED the stored
# command, so a matching entry written after the key was handed out took the
# anchor away from the block the key belongs to. The fix records the MTT
# second of the command's own echo in the cursor and asks for that entry
# again, and narrows the match from "contains" to "is" the command.
# #214's serialization never reached this -- the lock is held by the issuing
# path only, and collect runs long afterwards and outside it.
#
# This script does NOT need two clients. Both experiments are sequential.
#
#   1. Two "D T" commands, identical text, seconds apart. IEE136I carries the
#      time, so the reply itself says which block was returned. async:"Y" is
#      used so the cursor starts at delivered=0 and collect must return the
#      whole block. The hardcopy log supplies the expected time independently.
#
#   2. A cursor for "D A" against a later "D A,L". The old anchor was a
#      strstr(), not an equality test, so any later command whose echo merely
#      CONTAINED the stored text took it -- a wider surface than "the same
#      command issued twice", and "D A" then "D A,L" is an ordinary operator
#      sequence. (Wider still: strstr ran over the whole formatted line, so
#      "RAKF0004 INVALID ATTEMPT TO ACCESS SYSTEM" matches a "D A" cursor.)
#
# Only display commands are issued; nothing on the system is changed.
#
# Exit status: 0 = correct (expected), 1 = the defect is back, 2 = inconclusive
# (the system did not give the script what it needs -- rerun).
#
# Usage:  ./tests/repro-214-collect.sh
# =========================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
	echo "ERROR: ${ENV_FILE} not found. Copy .env.example and fill it in."
	exit 2
fi
# shellcheck source=../.env
. "$ENV_FILE"

BASE_URL="http://${MVSMF_HOST}:${MVSMF_PORT}"
AUTH="${MVSMF_USER}:${MVSMF_PASS}"
CONSOLE="${BASE_URL}/zosmf/restconsoles/consoles/defcn"
LOG="${BASE_URL}/zosmf/restconsoles/v1/log"

DEFECTS=0

issue() {  # $1 = json body -> whole response body
	curl -s -m 30 -u "$AUTH" -X PUT -H 'Content-Type: application/json' \
		-d "$1" "$CONSOLE"
}
collect() {  # $1 = key -> cmd-response with \r turned into newlines
	curl -s -m 30 -u "$AUTH" "${CONSOLE}/solmsgs/$1" |
		jq -r '.["cmd-response"] // ""' | tr '\r' '\n'
}
newest_time() {  # newest IEE136I in the trace table -> its TIME=hh.mm.ss
	curl -s -m 30 -u "$AUTH" "${LOG}?timeRange=5m" |
		jq -r '[.items[] | select(.message | test("IEE136I"))] | last | .message' |
		sed -n 's/.*LOCAL: TIME=\([0-9.]*\).*/\1/p'
}

echo ""
echo "========================================"
echo " #214 collect: does the anchor move?"
echo " Host: ${MVSMF_HOST}:${MVSMF_PORT}"
echo "========================================"

# -------------------------------------------------------------------------
# 1. Same command text, twice
# -------------------------------------------------------------------------
echo ""
echo "--- 1. two async 'D T', collect the FIRST key ---"

K1=$(issue '{"cmd":"D T","async":"Y"}' | jq -r '.["cmd-response-key"] // ""')
T1=$(newest_time)
echo "  command #1: key=${K1}  its reply says TIME=${T1}"

sleep 5

K2=$(issue '{"cmd":"D T","async":"Y"}' | jq -r '.["cmd-response-key"] // ""')
T2=$(newest_time)
echo "  command #2: key=${K2}  its reply says TIME=${T2}"

if [ -z "$K1" ] || [ -z "$T1" ] || [ -z "$T2" ]; then
	echo "  INCONCLUSIVE: could not read a key or a time from the system"
	exit 2
fi
if [ "$T1" = "$T2" ]; then
	echo "  INCONCLUSIVE: both commands report the same time -- rerun"
	exit 2
fi

R1=$(collect "$K1")
echo "  collect(key of #1) -> ${R1:-(empty)}"

case "$R1" in
	*"$T1"*) echo "  OK: the first key returned its own block" ;;
	*"$T2"*) echo "  DEFECT: the first key returned command #2's block (${T2}, not ${T1})"
	         DEFECTS=$((DEFECTS + 1)) ;;
	*)       echo "  INCONCLUSIVE: neither time in the reply" ;;
esac

# -------------------------------------------------------------------------
# 2. A later command whose echo merely CONTAINS the stored text
# -------------------------------------------------------------------------
echo ""
echo "--- 2. cursor for 'D A', then issue 'D A,L' ---"

KA=$(issue '{"cmd":"D A","async":"Y"}' | jq -r '.["cmd-response-key"] // ""')
echo "  cursor for 'D A': key=${KA}"
sleep 2
issue '{"cmd":"D A,L"}' >/dev/null
sleep 1

RA=$(collect "$KA")
echo "  collect(key of 'D A') returned $(printf '%s' "$RA" | grep -c .) line(s):"
printf '%s\n' "$RA" | sed 's/^/    /'

# A plain "D A" answers a four-line activity summary and never lists address
# spaces; a per-address-space line is proof the D A,L block was returned.
if printf '%s' "$RA" | grep -q 'IEFPROC'; then
	echo "  DEFECT: the 'D A' key returned the 'D A,L' block"
	DEFECTS=$((DEFECTS + 1))
else
	echo "  OK: the 'D A' key did not pick up the 'D A,L' block"
fi

echo ""
echo "========================================"
if [ "$DEFECTS" -gt 0 ]; then
	echo " #214 collect half REPRODUCED (${DEFECTS}/2) -- REGRESSION"
	echo "========================================"
	exit 1
fi
echo " both keys returned their own block -- OK"
echo "========================================"
