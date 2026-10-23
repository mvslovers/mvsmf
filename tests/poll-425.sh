#!/bin/bash
# =========================================================================
# tests/poll-425.sh -- the #425 scenario: status polls on a running job
#
# Submits a read-only job that runs about a minute (tests/jcl/longro.jcl) and
# polls GET /zosmf/restjobs/jobs/{name}/{id} from submit to OUTPUT, with
# several clients at once so that requests overlap. Around it:
#
#   - fn=version, fn=storage (no &total=1) before and after the whole run
#   - fn=textsum: a sample every few seconds while the pollers run, and one
#     before and one after each run. The first sample at a load point is the
#     baseline; a later sample at the same load point that differs by even
#     one block is reported (a relocated copy is compared with its own
#     baseline, not with another load's). Limit: damage already present in
#     the first sample at a load point becomes the baseline.
#   - the hardcopy log, searched for MVSMF901E, 913I, 914I, 007W
#
# What it cannot do: stop HTTPD. Run `P HTTPD` afterwards from the operator
# console and look for the socket thread and all workers stopping and for
# SA03; that is part of the measurement, and it is the operator's step.
#
# Usage:
#   mbt run rest-tests -- poll-425 [--label NAME] [--runs N] [--clients N]
#                                  [--pause SECONDS] [--timeout SECONDS]
#
#   --label    names the result directory and the summary (e.g. resident-yes)
#   --runs     jobs to submit, one after the other (default 6)
#   --clients  pollers per job (default 3)
#   --pause    sleep between two polls of one client (default 0)
#   --timeout  give up on a job after this many seconds (default 240)
#
# Results go to ./poll-425-LABEL-STAMP/. The exit status is 0 when every poll
# answered 200 and no block changed, no MVSMF901E/913I/914I/007W was logged.
# =========================================================================

set -u
. "$(dirname "$0")/lib/conn.sh"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL=run
RUNS=6
CLIENTS=3
PAUSE=0
TIMEOUT=240
while [ $# -gt 0 ]; do
	case "$1" in
	--label)   LABEL="$2"; shift 2 ;;
	--runs)    RUNS="$2"; shift 2 ;;
	--clients) CLIENTS="$2"; shift 2 ;;
	--pause)   PAUSE="$2"; shift 2 ;;
	--timeout) TIMEOUT="$2"; shift 2 ;;
	*) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
	esac
done

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="poll-425-${LABEL}-${STAMP}"
mkdir -p "$OUT/base"
START_EPOCH=$(date +%s)

get() { curl -s -m 30 -K "$MVSMF_CURLRC" "$@"; }

say() { echo "$*" | tee -a "$OUT/summary.txt"; }

# One textsum sample: compares against the baseline at its load point.
# Prints nothing; appends to textsum.log and, on a difference, to diffs.log.
sample_text() {
	local when="$1" body load key
	body=$(get "${BASE_URL}/zosmf/test?fn=textsum") || body=""
	load=$(printf '%s' "$body" | jq -r '.load // empty' 2>/dev/null)
	if [ -z "$load" ]; then
		echo "$(date +%H:%M:%S) $when NO-SAMPLE $body" >>"$OUT/textsum.log"
		echo "$when" >>"$OUT/textsum-missing.log"
		return 0
	fi
	key="$OUT/base/${load}"
	printf '%s' "$body" | jq -r '.sums | join(" ")' >"$key.new"
	echo "$(date +%H:%M:%S) $when load=$load cde=$(printf '%s' "$body" | jq -r .cde)" \
		"use=$(printf '%s' "$body" | jq -r .use) len=$(printf '%s' "$body" | jq -r .len)" \
		"build=$(printf '%s' "$body" | jq -r .build)" >>"$OUT/textsum.log"
	if [ ! -f "$key.sums" ]; then
		mv "$key.new" "$key.sums"
	elif ! cmp -s "$key.new" "$key.sums"; then
		echo "$(date +%H:%M:%S) $when DIFFERS at load=$load" >>"$OUT/diffs.log"
		cp "$key.new" "$OUT/diff-$(date +%H%M%S)-$load.sums"
	fi
	rm -f "$key.new"
}

# One client: poll until OUTPUT. Writes "polls non200 status" to a file.
poller() {
	local name="$1" id="$2" file="$3" deadline code st polls=0 bad=0 body
	deadline=$(( $(date +%s) + TIMEOUT ))
	st=""
	while [ "$(date +%s)" -lt "$deadline" ]; do
		body=$(get -w '\n%{http_code}' "${BASE_URL}/zosmf/restjobs/jobs/${name}/${id}")
		code=$(printf '%s' "$body" | tail -n1)
		polls=$((polls + 1))
		if [ "$code" != "200" ]; then
			bad=$((bad + 1))
			echo "$(date +%H:%M:%S) ${name}/${id} http=$code" >>"$OUT/bad-polls.log"
		else
			st=$(printf '%s' "$body" | sed '$d' | jq -r '.status // empty' 2>/dev/null)
			[ "$st" = "OUTPUT" ] && break
		fi
		[ "$PAUSE" != "0" ] && sleep "$PAUSE"
	done
	echo "$polls $bad ${st:-none}" >"$file"
}

# --- before -----------------------------------------------------------
VER=$(get "${BASE_URL}/zosmf/test?fn=version")
say "label=$LABEL runs=$RUNS clients=$CLIENTS pause=$PAUSE"
say "version: $VER"
STG0=$(get "${BASE_URL}/zosmf/test?fn=storage&sp=0")
say "storage before: $STG0"
sample_text "start"

JCL=$(cat "$HERE/jcl/longro.jcl")
TOTAL_POLLS=0
TOTAL_BAD=0
NOT_OUTPUT=0
SUBMIT_FAIL=0

for r in $(seq 1 "$RUNS"); do
	resp=$(get -w '\n%{http_code}' -X PUT -H 'Content-Type: text/plain' \
		-H 'X-CSRF-ZOSMF-HEADER: true' --data-binary "$JCL" \
		"${BASE_URL}/zosmf/restjobs/jobs")
	code=$(printf '%s' "$resp" | tail -n1)
	body=$(printf '%s' "$resp" | sed '$d')
	name=$(printf '%s' "$body" | jq -r '.jobname // empty' 2>/dev/null)
	id=$(printf '%s' "$body" | jq -r '.jobid // empty' 2>/dev/null)
	if [ "$code" != "200" ] || [ -z "$id" ]; then
		say "run $r: submit failed http=$code $body"
		SUBMIT_FAIL=$((SUBMIT_FAIL + 1))
		continue
	fi
	sample_text "run$r-submit"

	pids=""
	for c in $(seq 1 "$CLIENTS"); do
		poller "$name" "$id" "$OUT/run$r.c$c" &
		pids="$pids $!"
	done
	# textsum while the pollers run: a damaged copy lives only while
	# requests overlap, so look during the overlap
	(
		while :; do
			sleep 3
			sample_text "run$r-during"
		done
	) &
	sampler=$!
	# shellcheck disable=SC2086
	wait $pids
	kill "$sampler" 2>/dev/null
	wait "$sampler" 2>/dev/null
	sample_text "run$r-end"

	rp=0; rb=0; rnot=0
	for c in $(seq 1 "$CLIENTS"); do
		read -r p b s <"$OUT/run$r.c$c" || { p=0; b=0; s=none; }
		rp=$((rp + p)); rb=$((rb + b))
		[ "$s" = "OUTPUT" ] || rnot=$((rnot + 1))
	done
	TOTAL_POLLS=$((TOTAL_POLLS + rp))
	TOTAL_BAD=$((TOTAL_BAD + rb))
	NOT_OUTPUT=$((NOT_OUTPUT + rnot))
	say "run $r: ${name}/${id} polls=$rp non200=$rb clients-not-at-OUTPUT=$rnot"
done

# --- after ------------------------------------------------------------
STG1=$(get "${BASE_URL}/zosmf/test?fn=storage&sp=0")
say "storage after: $STG1"
sample_text "final"

# the hardcopy log (MTT window) since the start of this run
MINS=$(( ( $(date +%s) - START_EPOCH ) / 60 + 2 ))
[ "$MINS" -gt 999 ] && MINS=999
get "${BASE_URL}/zosmf/restconsoles/v1/log?timeRange=${MINS}m" >"$OUT/hardcopy.json"
HITS=$(jq -r '.items[]?.message' "$OUT/hardcopy.json" 2>/dev/null |
	grep -E 'MVSMF(901E|913I|914I|007W)' || true)
printf '%s\n' "$HITS" | sed '/^$/d' >"$OUT/console-hits.txt"
NHITS=$(wc -l <"$OUT/console-hits.txt" | tr -d ' ')
LOGITEMS=$(jq -r '.totalitems // "unreadable"' "$OUT/hardcopy.json" 2>/dev/null)

NDIFF=0
[ -f "$OUT/diffs.log" ] && NDIFF=$(wc -l <"$OUT/diffs.log" | tr -d ' ')
NMISS=0
[ -f "$OUT/textsum-missing.log" ] && NMISS=$(wc -l <"$OUT/textsum-missing.log" | tr -d ' ')
LOADS=$(find "$OUT/base" -name '*.sums' | wc -l | tr -d ' ')

say "---- result ($LABEL) ----"
say "polls=$TOTAL_POLLS non200=$TOTAL_BAD clients-not-at-OUTPUT=$NOT_OUTPUT submit-failed=$SUBMIT_FAIL"
say "textsum: distinct load points=$LOADS, differing samples=$NDIFF, samples without an answer=$NMISS"
say "console: $NHITS line(s) MVSMF901E/913I/914I/007W in $LOGITEMS log items (MTT window, ${MINS}m)"
say "next: P HTTPD from the operator console; socket thread and every worker must stop, no SA03."

[ "$TOTAL_BAD" -eq 0 ] && [ "$NDIFF" -eq 0 ] && [ "$NHITS" -eq 0 ] &&
	[ "$NOT_OUTPUT" -eq 0 ] && [ "$SUBMIT_FAIL" -eq 0 ]
