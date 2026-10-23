#!/bin/bash
#
# tests/load-452.sh -- one load run for the four stability cases (#452)
#
#   reads   #372  strictly sequential member GETs, many more than 25,000, with
#                 small submit / spool / write / delete cycles in between
#   polls   #425  job status polls against an executing job (15 TSO steps of
#                 LISTCAT ALL), six jobs, ~1,860 polls
#   puts    #428  large binary PUTs (20 MB, 28 MB) into an FB 80 data set
#   lists   #436  concurrent GET /zosmf/restfiles/ds?dslevel=... (xargs -P)
#
# The scenarios run side by side (PARALLEL=1, the default: that is the point of
# a shared run) or one after the other (PARALLEL=0, to attribute a finding).
# Every scenario keeps its own tally in its own file; nothing is counted twice.
#
# Usage (from a throwaway container of your own, run locally):
#   eval "$(mvsce-target up)"
#   mbt run rest-tests --target env -- load-452 [reads] [polls] [puts] [lists]
#   mvsce-target down "$MVSCE_TARGET_NAME"; mvsce-target list
#
#   HERC_LOG_CMD='docker logs NAME' mbt run rest-tests ...   # see below
#
# On a shared machine set TMPDIR to a directory of your own: the session file
# lives in $TMPDIR/mvsmf-conn.* and a run is useless once something sweeps /tmp.
#
# Run through mbt: the connection and the session token come from the target
# (tests/lib/conn.sh). The token lives as long as the session max-age (480
# minutes unless the Parmlib says otherwise); a run longer than that answers
# 401 from then on, which shows in the tally as 401.
#
# Knobs (environment), defaults in brackets:
#   READS [30000]            member GETs; one pass over the library is a few
#                            thousand, the cycle repeats until READS is met
#   READ_LIB [SYS1.MACLIB]   library the members are read from
#   CYCLE_EVERY [500]        reads between two small job/data set cycles
#   POLL_JOBS [6]  POLL_STEPS [15]  POLL_DELAY [0.1]  POLL_MAX [600]
#   PUT_SIZES ["20000000 20000000 20000000 28000000"]   bytes, multiples of 80
#   LIST_N [600]  LIST_PASSES ["4 8"]  LIST_DSLEVEL [SYS1.PARMLIB]
#   SAMPLE_SECS [300]        in-flight fn=storage sample (never total=1)
#   QUIET_SECS [20]          wait before the "after" sample so workers are gone
#   CONSEC_FAIL_MAX [50]     reads stops after this many failures in a row
#                            (the server is gone: 503 until HTTPD is restarted)
#   PARALLEL [1]  OUT [./load-452-<stamp>]  KEEP [0]
#   HERC_LOG_CMD             a command that prints the guest console log. Set
#                            from MVSCE_TARGET_NAME (`docker logs mvsce-NAME`)
#                            when that is in the environment and docker is
#                            local. Before and after are counted for MVSMF901E,
#                            MVSMF007W, S213, U0801 ... Without it only what
#                            the HTTP answers carry is counted.
#
# What it does to the server, in order of weight:
#   - fn=storage&total=1 holds ALL free storage while it runs. It is taken only
#     before the scenarios start and after they have ended (internals/
#     storage-probe.md). In between there is only the default sample, which
#     holds its largest probe for microseconds.
#   - it creates <HLQ>.LOAD452.* data sets and LOAD452x jobs, and removes them
#     at the end, also on an abort.
#
# Output in $OUT: summary.md (paste it into the issue), storage.csv, one
# <scenario>.codes per scenario (seq, epoch, HTTP code, seconds, curl rc, note),
# console-before.txt / console-after.txt, version.json.

set -u

cd "$(dirname "$0")/.." || exit 1
. tests/lib/conn.sh

BASE="$BASE_URL"
USER_UC="$MVSMF_USER"

READS="${READS:-30000}"
READ_LIB="${READ_LIB:-SYS1.MACLIB}"
CYCLE_EVERY="${CYCLE_EVERY:-500}"
POLL_JOBS="${POLL_JOBS:-6}"
POLL_STEPS="${POLL_STEPS:-15}"
POLL_DELAY="${POLL_DELAY:-0.1}"
POLL_MAX="${POLL_MAX:-600}"
PUT_SIZES="${PUT_SIZES:-20000000 20000000 20000000 28000000}"
LIST_N="${LIST_N:-600}"
LIST_PASSES="${LIST_PASSES:-4 8}"
LIST_DSLEVEL="${LIST_DSLEVEL:-SYS1.PARMLIB}"
SAMPLE_SECS="${SAMPLE_SECS:-300}"
QUIET_SECS="${QUIET_SECS:-20}"
CONSEC_FAIL_MAX="${CONSEC_FAIL_MAX:-50}"
PARALLEL="${PARALLEL:-1}"
KEEP="${KEEP:-0}"
# The console log of a local mvsce-target container, unless told otherwise.
if [ -z "${HERC_LOG_CMD:-}" ] && [ -n "${MVSCE_TARGET_NAME:-}" ] && command -v docker >/dev/null 2>&1; then
	HERC_LOG_CMD="docker logs mvsce-${MVSCE_TARGET_NAME} 2>&1"
fi
HERC_LOG_CMD="${HERC_LOG_CMD:-}"

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${OUT:-$PWD/load-452-${STAMP}}"
WORK="${MVSMF_CONN_DIR}/work"
mkdir -p "$OUT" "$WORK" || exit 1

SCENARIOS="${*:-reads polls puts lists}"
for s in $SCENARIOS; do
	case "$s" in
		reads|polls|puts|lists) ;;
		*) echo "ERROR: unknown scenario '$s' (reads polls puts lists)" >&2; exit 1 ;;
	esac
done

PUT_DSN="${USER_UC}.LOAD452.PUT"
CYC_DSN="${USER_UC}.LOAD452.CYC"

now() { date +%s; }
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$OUT/run.log" >&2; }

# One request, one line in $OUT/<scenario>.codes:
#   seq epoch http-code seconds rc=<curl exit> note
# The note is the start of the body for anything but 200/204, which is where
# an abend shows ("Internal server error (abend S213)").
req() {
	local sc="$1" seq="$2" meta code t rc note
	shift 2
	local body="$WORK/${sc}.$$.body"
	meta=$(curl -s -K "$MVSMF_CURLRC" -o "$body" -w '%{http_code} %{time_total}' "$@")
	rc=$?
	code="${meta%% *}"
	t="${meta##* }"
	note="-"
	case "$code" in
		200|204) ;;
		*) note=$(head -c 200 "$body" 2>/dev/null | tr -d '\n' | tr ' ' '_')
		   [ -n "$note" ] || note="-" ;;
	esac
	echo "$seq $(now) $code $t rc=$rc $note" >> "$OUT/${sc}.codes"
	LAST_CODE="$code"
	LAST_BODY="$body"
}

# --- storage ---------------------------------------------------------------
echo "label,epoch,largest,largest_at,total,blocks,probes,free_errors" > "$OUT/storage.csv"

# sample LABEL [total]
sample() {
	local label="$1" q="fn=storage" out
	[ "${2:-}" = "total" ] && q="fn=storage&total=1"
	out=$(curl -s -m 120 -K "$MVSMF_CURLRC" "$BASE/zosmf/test?${q}")
	echo "$label $(now) $out" >> "$OUT/storage-raw.txt"
	echo "$out" | jq -r --arg l "$label" --arg e "$(now)" \
		'[$l, $e, (.largest // "?"), (.largest_at // "?"), (.total // "-"), (.blocks // "-"), (.probes // "?"), (.free_errors // "?")] | @csv' \
		>> "$OUT/storage.csv" 2>/dev/null ||
		echo "\"$label\",$(now),\"unparsable: $(echo "$out" | head -c 80 | tr -d '\n,"')\"" >> "$OUT/storage.csv"
}

sampler() {
	local n=0
	while [ ! -e "$OUT/done" ]; do
		sleep "$SAMPLE_SECS"
		[ -e "$OUT/done" ] && break
		n=$((n + 1))
		sample "during-$n"
	done
}

# --- small helpers -----------------------------------------------------------
console() { [ -n "$HERC_LOG_CMD" ] && bash -c "$HERC_LOG_CMD" 2>&1; }

submit_jcl() {
	# stdout: "<jobname> <jobid>"; empty on failure
	local jcl="$1" resp
	resp=$(curl -s -K "$MVSMF_CURLRC" -X PUT -H "Content-Type: text/plain" \
		--data-binary "$jcl" "$BASE/zosmf/restjobs/jobs") || return 1
	echo "$resp" | jq -r 'select(.jobid) | "\(.jobname) \(.jobid)"' 2>/dev/null
}

purge_job() {
	curl -s -o /dev/null -K "$MVSMF_CURLRC" -X DELETE \
		"$BASE/zosmf/restjobs/jobs/$1/$2"
}

job_status() {
	curl -s -K "$MVSMF_CURLRC" "$BASE/zosmf/restjobs/jobs/$1/$2" | jq -r '.status // empty' 2>/dev/null
}

# --- scenario 1: reads (#372) ------------------------------------------------
cycle_jcl() {
	cat <<EOF
//LOAD452C JOB (ACCT),'LOAD452 CYCLE',CLASS=A,MSGCLASS=H,
//         NOTIFY=&SYSUID
//S1       EXEC PGM=IEFBR14
EOF
}

small_cycle() {
	# submit -> wait -> spool -> write a data set -> read it -> delete it
	local n="$1" id name jid st i body
	id=$(submit_jcl "$(cycle_jcl)")
	if [ -z "$id" ]; then echo "$n $(now) 000 0 rc=0 cycle-submit-failed" >> "$OUT/cycle.codes"; return; fi
	name="${id% *}"; jid="${id#* }"
	echo "$n $(now) 200 0 rc=0 cycle-submit:$jid" >> "$OUT/cycle.codes"
	for i in $(seq 1 60); do
		st=$(job_status "$name" "$jid")
		[ "$st" = "OUTPUT" ] && break
		sleep 1
	done
	req cycle "$n" "$BASE/zosmf/restjobs/jobs/$name/$jid/files"
	req cycle "$n" "$BASE/zosmf/restjobs/jobs/$name/$jid/files/2/records"
	req cycle "$n" -X POST -H "Content-Type: application/json" \
		-d '{"dsorg":"PS","recfm":"FB","lrecl":80,"blksize":3120,"alcunit":"TRK","primary":1,"secondary":1}' \
		"$BASE/zosmf/restfiles/ds/$CYC_DSN"
	body="LOAD452 CYCLE $n"
	req cycle "$n" -X PUT -H "Content-Type: text/plain" --data-binary "$body" "$BASE/zosmf/restfiles/ds/$CYC_DSN"
	req cycle "$n" "$BASE/zosmf/restfiles/ds/$CYC_DSN"
	req cycle "$n" -X DELETE "$BASE/zosmf/restfiles/ds/$CYC_DSN"
	purge_job "$name" "$jid"
}

scenario_reads() {
	local members i=0 n fail=0 name
	members="$WORK/members.txt"
	if ! curl -s -K "$MVSMF_CURLRC" -H "X-IBM-Max-Items: 0" \
		"$BASE/zosmf/restfiles/ds/${READ_LIB}/member" | jq -r '.items[].member | @uri' > "$members" ||
		[ ! -s "$members" ]; then
		log "reads: no member list for $READ_LIB, scenario not run"
		echo "ABORT no-member-list" > "$OUT/reads.state"
		return
	fi
	n=$(wc -l < "$members")
	log "reads: $READ_LIB has $n members, $READS reads, small cycle every $CYCLE_EVERY"
	while [ "$i" -lt "$READS" ] && [ ! -e "$OUT/abort" ]; do
		while IFS= read -r name; do
			i=$((i + 1))
			[ "$i" -gt "$READS" ] && break
			req reads "$i" "$BASE/zosmf/restfiles/ds/${READ_LIB}(${name})"
			case "$LAST_CODE" in
				200) fail=0 ;;
				*) fail=$((fail + 1)) ;;
			esac
			if [ "$fail" -ge "$CONSEC_FAIL_MAX" ]; then
				log "reads: $fail failures in a row at read $i, stopping"
				echo "STOPPED consecutive-failures at $i" > "$OUT/reads.state"
				return
			fi
			[ $((i % CYCLE_EVERY)) -eq 0 ] && small_cycle "$i"
			[ -e "$OUT/abort" ] && break
		done < "$members"
	done
	echo "DONE $i" > "$OUT/reads.state"
}

# --- scenario 2: polls (#425) ------------------------------------------------
polls_jcl() {
	local i
	printf '//LOAD452P JOB (ACCT),'"'"'LOAD452 POLL'"'"',CLASS=A,MSGCLASS=H,\n//         NOTIFY=&SYSUID\n'
	for i in $(seq 1 "$POLL_STEPS"); do
		printf '//S%02d      EXEC PGM=IKJEFT01\n//SYSTSPRT DD SYSOUT=*\n//SYSTSIN  DD *\n LISTCAT ALL\n/*\n' "$i"
	done
}

scenario_polls() {
	local j id name jid t0 st n=0
	local jcl
	jcl=$(polls_jcl)
	for j in $(seq 1 "$POLL_JOBS"); do
		[ -e "$OUT/abort" ] && break
		id=$(submit_jcl "$jcl")
		if [ -z "$id" ]; then
			log "polls: submit $j failed"
			echo "$j $(now) 000 0 rc=0 submit-failed" >> "$OUT/polls.codes"
			continue
		fi
		name="${id% *}"; jid="${id#* }"
		t0=$SECONDS
		log "polls: job $j/$POLL_JOBS is $name/$jid"
		while [ $((SECONDS - t0)) -lt "$POLL_MAX" ] && [ ! -e "$OUT/abort" ]; do
			n=$((n + 1))
			req polls "$n" "$BASE/zosmf/restjobs/jobs/$name/$jid"
			echo "$jid" > "$OUT/polls.lastjob"
			if [ "$LAST_CODE" = "200" ]; then
				st=$(jq -r '.status // empty' "$LAST_BODY" 2>/dev/null)
				echo "$st" >> "$OUT/polls.status"
				[ "$st" = "OUTPUT" ] && break
			fi
			sleep "$POLL_DELAY"
		done
		echo "$jid $((SECONDS - t0))s" >> "$OUT/polls.jobs"
		purge_job "$name" "$jid"
	done
	echo "DONE $n" > "$OUT/polls.state"
}

# --- scenario 3: puts (#428) -------------------------------------------------
scenario_puts() {
	local sz max=0 n=0 trks f="$WORK/put.bin" tmo
	for sz in $PUT_SIZES; do [ "$sz" -gt "$max" ] && max="$sz"; done
	trks=$((max / 14000 + 50))
	req puts 0 -X POST -H "Content-Type: application/json" \
		-d "{\"dsorg\":\"PS\",\"recfm\":\"FB\",\"lrecl\":80,\"blksize\":3120,\"alcunit\":\"TRK\",\"primary\":${trks},\"secondary\":10}" \
		"$BASE/zosmf/restfiles/ds/$PUT_DSN"
	case "$LAST_CODE" in
		201|200|204) ;;
		*) log "puts: allocating $PUT_DSN answered $LAST_CODE: $(head -c 200 "$LAST_BODY")"
		   echo "ABORT allocate-$LAST_CODE" > "$OUT/puts.state"; return ;;
	esac
	for sz in $PUT_SIZES; do
		[ -e "$OUT/abort" ] && break
		n=$((n + 1))
		head -c "$sz" /dev/urandom > "$f"
		tmo=$((120 + 20 * (sz / 1000000)))
		log "puts: PUT $n, $sz bytes"
		req puts "$n" -m "$tmo" -X PUT -H "X-IBM-Data-Type: binary" \
			-H "Content-Type: application/octet-stream" --data-binary @"$f" \
			"$BASE/zosmf/restfiles/ds/$PUT_DSN"
		echo "$n $sz" >> "$OUT/puts.sizes"
	done
	rm -f "$f"
	echo "DONE $n" > "$OUT/puts.state"
}

# --- scenario 4: lists (#436) ------------------------------------------------
scenario_lists() {
	local p
	for p in $LIST_PASSES; do
		[ -e "$OUT/abort" ] && break
		log "lists: $LIST_N requests, $p in parallel"
		seq "$LIST_N" | xargs -P "$p" -I{} bash -c '
			o=$(curl -s -K "$1" -w "\n@@%{http_code} %{time_total}" "$2")
			meta=${o##*@@}; body=${o%@@*}; code=${meta%% *}; t=${meta##* }; note=-
			[ "$code" = 200 ] || note=$(printf %s "$body" | head -c 200 | tr -d "\n" | tr " " _)
			echo "$3 $(date +%s) $code $t $note"' _ "$MVSMF_CURLRC" \
			"$BASE/zosmf/restfiles/ds?dslevel=${LIST_DSLEVEL}" "$p" >> "$OUT/lists.raw"
	done
	awk '{printf "%d %s %s %s rc=0 %s P=%s\n", NR, $2, $3, $4, $5, $1}' "$OUT/lists.raw" > "$OUT/lists.codes"
	echo "DONE" > "$OUT/lists.state"
}

# --- cleanup -----------------------------------------------------------------
cleanup() {
	touch "$OUT/abort" "$OUT/done"
	for pid in $PIDS; do kill "$pid" 2>/dev/null; done
	wait 2>/dev/null
	if [ "$KEEP" != "1" ]; then
		# A PUT that was cut off may still hold the data set for a while.
		for d in "$PUT_DSN" "$CYC_DSN"; do
			for t in 1 2 3; do
				c=$(curl -s -o /dev/null -w '%{http_code}' -K "$MVSMF_CURLRC" -X DELETE \
					"$BASE/zosmf/restfiles/ds/$d")
				case "$c" in 204|404) break ;; esac
				sleep 10
			done
			case "$c" in 204|404) ;; *) log "cleanup: DELETE $d answered $c, remove it by hand" ;; esac
		done
	fi
}
PIDS=""
mvsmf_on_exit cleanup
trap 'log "interrupted"; exit 130' INT TERM

# --- summary -----------------------------------------------------------------
tally() {
	# tally FILE -> "n  200:x 500:y ...  first-non-2xx=SEQ"
	local f="$1"
	[ -s "$f" ] || { echo "0 requests"; return; }
	awk '{c[$3]++; n++; if ($3 !~ /^2[0-9][0-9]$/ && first == "") first=$1}
	     END {s=""; for (k in c) s=s " " k "x" c[k]; print n " requests;" s "; first non-2xx: " (first == "" ? "none" : first)}' "$f"
}

# `docker logs` carries a message twice, as the console stream ("HH:MM:SS / ...")
# and again in the tail of the hardcopy log; count the console stream only.
console_count() {
	grep -E '^[0-9]{2}:[0-9]{2}:[0-9]{2} / ' "$1" 2>/dev/null | grep -c -E "$2"
}

summarize() {
	local f s b a pat
	{
		echo "# Load run $STAMP"
		echo
		echo '```'
		cat "$OUT/version.json" 2>/dev/null
		echo
		echo '```'
		echo
		echo "Banner lines from the console log:"
		echo '```'
		grep -E '^[0-9:]{8} / HTTPD00[05]I' "$OUT/console-after.txt" 2>/dev/null | tail -2
		echo '```'
		echo
		echo "| scenario | result |"
		echo "|---|---|"
		for s in reads polls puts lists cycle; do
			f="$OUT/$s.codes"
			[ -e "$f" ] || continue
			echo "| $s | $(tally "$f") |"
		done
		echo
		echo "States: $(cat "$OUT"/*.state 2>/dev/null | tr '\n' ';')"
		echo
		echo "## Abends seen in the HTTP answers (500 bodies)"
		echo '```'
		cat "$OUT"/*.codes 2>/dev/null | awk '$3 == "500"' | sed 's/.*abend_\(S[0-9A-F]*\|U[0-9]*\).*/\1/' |
			sort | uniq -c
		echo '```'
		echo
		echo "## Console log (new lines since the run started)"
		if [ -s "$OUT/console-after.txt" ]; then
			echo "| pattern | before | after | new |"
			echo "|---|---:|---:|---:|"
			for pat in MVSMF901E MVSMF007W 'S213' 'U0801' HTTPD908E 'S0C[0-9]' SA03 MVSMF106E MVSMF913I MVSMF914I; do
				b=$(console_count "$OUT/console-before.txt" "$pat")
				a=$(console_count "$OUT/console-after.txt" "$pat")
				echo "| \`$pat\` | $b | $a | $((a - b)) |"
			done
			echo
			echo "New abend lines (console stream):"
			echo '```'
			grep -E '^[0-9]{2}:[0-9]{2}:[0-9]{2} / (MVSMF901E|MVSMF913I|MVSMF914I|HTTPD908E|MVSMF007W)' "$OUT/console-after.txt" |
				grep -F -x -v -f "$OUT/console-before.txt" 2>/dev/null
			echo '```'
		else
			echo "HERC_LOG_CMD was not set: only the HTTP answers above are counted."
		fi
		echo
		echo "## fn=storage"
		echo '```'
		cat "$OUT/storage.csv"
		echo '```'
		echo
		echo "Status seen by the polls (a poll against an executing job is ACTIVE):"
		echo '```'
		sort "$OUT/polls.status" 2>/dev/null | uniq -c
		echo '```'
		echo "Polled jobs (id, seconds to OUTPUT):"
		echo '```'
		cat "$OUT/polls.jobs" 2>/dev/null
		echo '```'
		echo "PUT sizes sent:"
		echo '```'
		cat "$OUT/puts.sizes" 2>/dev/null
		echo '```'
	} > "$OUT/summary.md"
}

# --- run ---------------------------------------------------------------------
log "load-452 against $BASE as $USER_UC, scenarios: $SCENARIOS, parallel=$PARALLEL, out=$OUT"

curl -s -K "$MVSMF_CURLRC" "$BASE/zosmf/test?fn=version" > "$OUT/version.json"
log "version: $(tr -d '\n' < "$OUT/version.json" | head -c 200)"
console > "$OUT/console-before.txt"

sample before-total total
sample before
log "before: $(tail -2 "$OUT/storage.csv" | tr '\n' ' ')"

sampler &
PIDS="$!"

START=$SECONDS
for s in $SCENARIOS; do
	if [ "$PARALLEL" = "1" ]; then
		"scenario_$s" &
		PIDS="$PIDS $!"
	else
		"scenario_$s"
	fi
done
for pid in $PIDS; do
	# the sampler stops on $OUT/done, set once the scenarios have ended
	[ "$pid" = "${PIDS%% *}" ] && continue
	wait "$pid"
done
touch "$OUT/done"
log "scenarios done after $((SECONDS - START)) s"

sleep "$QUIET_SECS"
sample after
sample after-total total
log "after: $(tail -2 "$OUT/storage.csv" | tr '\n' ' ')"

console > "$OUT/console-after.txt"
summarize
cat "$OUT/summary.md"
log "result in $OUT"
exit 0
