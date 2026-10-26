#!/bin/bash
#
# reads-372.sh -- strictly sequential member GETs with a storage reading every
# N requests (issue #372).
#
# The question: does free storage in the HTTPD address space fall with the
# number of member reads, and if so, how fast? The load is one client, one
# connection per request, never two requests in flight -- the pattern of the
# macro-library snapshots the report came from.
#
# Every EVERY reads it takes one fn=storage sample (internals/storage-probe.md).
# While the largest free block is above NEAR_BYTES the sample is taken with
# total=1 (total and block count as well); below that it is the plain bisect,
# because total=1 holds all free storage and near the cliff would fire the
# very abend being watched for.
#
# The reading is the slope: summary.txt gives bytes per read as
# (total at the first sample - total at the last) / reads, and with total=1
# unavailable it falls back to the largest block:
#   about 128-140        the CRT block of mvslovers/libc370#546 (fixed in
#                        libc370 2.12.1) -- a build older than that loses it
#   about 0              nothing per request; look elsewhere (job/spool paths)
# Whether it is the member read itself and not the CGI start is decided by the
# comparison classes: CLASS=static, CLASS=info or CLASS=probe use the same
# loop against a URL that does not read a member.
#
# Usage (from a throwaway container of your own, run locally):
#   eval "$(mvsce-target up)"
#   READS=50000 mbt run rest-tests --target env -- reads-372
#   CLASS=info READS=5000 mbt run rest-tests --target env -- reads-372
#
# Knobs (environment), defaults in brackets:
#   READS [50000]          GETs in total; the member list is cycled
#   READ_LIB [SYS1.MACLIB] library the members come from
#   MEMBERS [0]            read at most this many distinct members (0 = all)
#   CLASS [member]         member | info | static | probe
#   EVERY [2500]           reads between two storage samples
#   NEAR_BYTES [2097152]   largest block below which total=1 is not used
#   CONSEC_FAIL_MAX [20]   stop after this many failures in a row (the server
#                          is gone: 503 until HTTPD is restarted)
#   OUT [./reads-372-<stamp>]
#
# Output in $OUT: storage.csv (requests,largest,total,blocks,probes,seconds),
# codes.txt (HTTP status -> count), summary.txt, version.json.
#
# The run creates nothing on the server: member reads and samples only.

set -u

cd "$(dirname "$0")/.." || exit 1
. tests/lib/conn.sh

BASE="$BASE_URL"
READS="${READS:-50000}"
READ_LIB="${READ_LIB:-SYS1.MACLIB}"
MEMBERS="${MEMBERS:-0}"
CLASS="${CLASS:-member}"
EVERY="${EVERY:-2500}"
NEAR_BYTES="${NEAR_BYTES:-2097152}"
CONSEC_FAIL_MAX="${CONSEC_FAIL_MAX:-20}"
OUT="${OUT:-./reads-372-$(date +%Y%m%d-%H%M%S)}"

mkdir -p "$OUT" || exit 1
CODES="$OUT/codes.raw"
: > "$CODES"

curl_get() { curl -s -K "$MVSMF_CURLRC" "$@"; }

curl_get "$BASE/zosmf/test?fn=version" > "$OUT/version.json"
echo "# base=$BASE class=$CLASS reads=$READS every=$EVERY lib=$READ_LIB" >&2
echo "# $(cat "$OUT/version.json")" >&2

# --- the URLs to read --------------------------------------------------------
URLS="$OUT/urls.txt"
case "$CLASS" in
member)
	curl_get -H 'X-IBM-Max-Items: 0' "$BASE/zosmf/restfiles/ds/$READ_LIB/member" |
		grep -o '"member": *"[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/' > "$OUT/members.txt"
	if [ "$MEMBERS" -gt 0 ]; then
		head -n "$MEMBERS" "$OUT/members.txt" > "$OUT/members.cut" &&
			mv "$OUT/members.cut" "$OUT/members.txt"
	fi
	[ -s "$OUT/members.txt" ] || { echo "no members in $READ_LIB" >&2; exit 1; }
	# '$' and '@' and '#' are legal in member names; the parentheses and the
	# '$' need escaping on the URL
	sed "s|.*|/zosmf/restfiles/ds/$READ_LIB(&)|; s|\\$|%24|g; s|#|%23|g; s|@|%40|g" \
		"$OUT/members.txt" > "$URLS" ;;
info)   echo "/zosmf/info" > "$URLS" ;;
static) echo "/probe.txt" > "$URLS" ;;
probe)  echo "/zosmf/test?fn=storage" > "$URLS" ;;
*)      echo "unknown CLASS: $CLASS" >&2; exit 1 ;;
esac
mapfile -t URLARR < "$URLS"
NURLS=${#URLARR[@]}
echo "# $NURLS distinct URLs" >&2

# --- one storage sample -> "largest total blocks probes" ------------------------
LAST_LARGEST=0
sample() {
	local q out largest total blocks probes errs
	q="fn=storage"
	if [ "$LAST_LARGEST" -eq 0 ] || [ "$LAST_LARGEST" -gt "$NEAR_BYTES" ]; then
		q="fn=storage&total=1"
	fi
	out=$(curl_get "$BASE/zosmf/test?$q")
	largest=$(echo "$out" | sed -n 's/.*"largest": \([0-9]*\).*/\1/p')
	total=$(echo "$out" | sed -n 's/.*"total": \([0-9]*\).*/\1/p')
	blocks=$(echo "$out" | sed -n 's/.*"blocks": \([0-9]*\).*/\1/p')
	probes=$(echo "$out" | sed -n 's/.*"probes": \([0-9]*\).*/\1/p')
	errs=$(echo "$out" | sed -n 's/.*"free_errors": \([0-9]*\).*/\1/p')
	if [ -z "$largest" ]; then
		echo "SAMPLE FAILED: $out" >&2
		return 1
	fi
	if [ "${errs:-0}" != "0" ]; then
		echo "free_errors=$errs -- the probe leaked; restart the server" >&2
		return 1
	fi
	LAST_LARGEST=$largest
	echo "$largest ${total:--} ${blocks:--} ${probes:--}"
}

CSV="$OUT/storage.csv"
echo "requests,largest,total,blocks,probes,seconds" > "$CSV"
emit() { echo "$1,${2// /,},$3" | tee -a "$CSV" >&2; }

t0=$(date +%s)
s=$(sample) || exit 1
emit 0 "$s" 0

i=0
consec=0
aborted=0
while [ "$i" -lt "$READS" ]; do
	url=${URLARR[$(( i % NURLS ))]}
	code=$(curl_get -o /dev/null -w '%{http_code}' "$BASE$url")
	i=$((i + 1))
	echo "$code" >> "$CODES"
	if [ "$code" = "200" ]; then
		consec=0
	else
		consec=$((consec + 1))
		if [ "$consec" -ge "$CONSEC_FAIL_MAX" ]; then
			echo "$consec failures in a row at request $i (last: $code) -- stopping" >&2
			aborted=1
			break
		fi
	fi
	if [ $((i % EVERY)) -eq 0 ]; then
		s=$(sample) || { aborted=1; break; }
		emit "$i" "$s" "$(( $(date +%s) - t0 ))"
	fi
done

# the final reading, unless the loop just took one
if [ $((i % EVERY)) -ne 0 ]; then
	# let the last worker finish before the sample overlaps its stack
	sleep 5
	s=$(sample) && emit "$i" "$s" "$(( $(date +%s) - t0 ))"
fi

# --- summary -----------------------------------------------------------------
sort "$CODES" | uniq -c | awk '{print $2, $1}' > "$OUT/codes.txt"
rm -f "$CODES"
{
	echo "class=$CLASS lib=$READ_LIB reads_sent=$i aborted=$aborted"
	echo "build: $(cat "$OUT/version.json")"
	echo "status counts:"
	sed 's/^/  /' "$OUT/codes.txt"
	awk -F, 'NR == 2 { f = $0; fr = $1; fl = $2; ft = $3 }
	         NR > 2  { l = $0; lr = $1; ll = $2; lt = $3 }
	         END {
	             if (lr > fr) {
	                 printf "first: %s\nlast:  %s\n", f, l
	                 printf "largest: %d -> %d  (%.1f bytes per read)\n", fl, ll, (fl - ll) / (lr - fr)
	                 if (ft != "-" && lt != "-")
	                     printf "total:   %d -> %d  (%.1f bytes per read)\n", ft, lt, (ft - lt) / (lr - fr)
	             }
	         }' "$CSV"
	echo "threshold link_stack: see fn=storage (65584 with __stklen, else 262328)"
} | tee "$OUT/summary.txt"

[ "$aborted" -eq 0 ]
