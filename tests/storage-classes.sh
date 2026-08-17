#!/bin/sh
#
# storage-classes.sh -- the sampling protocol from issue #287.
#
# Runs one load class at a time against a server and samples free storage
# (/zosmf/test?fn=storage) before, during and after each class, so the
# consumer behind the S80A degradation can be named with a rate instead of
# reconstructed from a console log that has already rolled.
#
# Reading the CSV it prints:
#   total falls with largest      -> an ordinary leak; the slope is its rate
#   total flat while largest sinks-> fragmentation; watch `blocks` climb
#   nothing moves                 -> not per-request; look at what the suites
#                                    do that a loop does not
# The `static` class never enters the CGI. If it drops too, the consumer is
# in httpd's request handling and not in mvsMF at all -- which is what
# decides the repo the fix ticket goes to.
#
# Every sample is itself one request against the address space under test,
# and with total=1 it briefly holds ALL free storage (see docs/storage-probe.md).
# The loop below is strictly sequential for that reason: nothing else of ours
# is ever in flight while a sample runs.
#
# Usage:
#   tests/storage-classes.sh                    # all classes, 200 requests each
#   COUNT=50 tests/storage-classes.sh info      # one class, shorter run
#
# Reads .env for MBT_MVS_HOST / _PORT / _USER / _PASS.

set -u

cd "$(dirname "$0")/.." || exit 1
[ -f .env ] || { echo "no .env"; exit 1; }
set -a
. ./.env
set +a

BASE="http://${MBT_MVS_HOST}:${MBT_MVS_PORT}"
CRED="${MBT_MVS_USER}:${MBT_MVS_PASS}"
COUNT="${COUNT:-200}"
EVERY="${EVERY:-50}"

# Class -> URL.  Keep the payloads small: this measures per-request storage,
# not throughput, and a large response only adds noise.
#   static   plain httpd document, no CGI -- the control
#   info     cheapest CGI handler
#   probe    the sampler itself, to quantify what the instrument costs
#   datasets member read
#   uss      USS file read (UFS session per connection)
#   jobs     spool file list (jesopen()/jesclose() per request)
url_for() {
    case "$1" in
    static)   echo "/probe.txt" ;;
    info)     echo "/zosmf/info" ;;
    probe)    echo "/zosmf/test?fn=storage" ;;
    datasets) echo "/zosmf/restfiles/ds/${DS_MEMBER:-SYS1.PARMLIB(IEASYS00)}" ;;
    uss)      echo "/zosmf/restfiles/fs/${USS_FILE:-wwwroot/probe.txt}" ;;
    jobs)     echo "/zosmf/restjobs/jobs/${JOB_NAME:-MVSMFACT}/${JOB_ID:?set JOB_ID}/files" ;;
    *)        echo "" ;;
    esac
}

CLASSES="${*:-static info probe datasets uss jobs static}"

# One sample -> "largest total blocks".  Parsed with sed rather than a JSON
# tool so this runs anywhere curl does.
sample() {
    out=$(curl -s -u "$CRED" "$BASE/zosmf/test?fn=storage&total=1")
    largest=$(echo "$out" | sed -n 's/.*"largest": \([0-9]*\).*/\1/p')
    total=$(echo "$out" | sed -n 's/.*"total": \([0-9]*\).*/\1/p')
    blocks=$(echo "$out" | sed -n 's/.*"blocks": \([0-9]*\).*/\1/p')
    errs=$(echo "$out" | sed -n 's/.*"free_errors": \([0-9]*\).*/\1/p')
    if [ -z "$largest" ]; then
        echo "SAMPLE FAILED: $out" >&2
        return 1
    fi
    # A probe that could not give its storage back has changed the thing it
    # measures; every later sample from this server is suspect.
    if [ "${errs:-0}" != "0" ]; then
        echo "free_errors=$errs -- the probe leaked; restart the server" >&2
        return 1
    fi
    echo "$largest $total ${blocks:-0}"
}

emit() { printf '%s,%s,%s,%s,%s,%s\n' "$1" "$2" "$3" "$4" "$5" "$6"; }

echo "# base=$BASE count=$COUNT every=$EVERY"
echo "# build=$(curl -s -u "$CRED" "$BASE/zosmf/test?fn=version" |
              sed -n 's/.*"build": "\([^"]*\)".*/\1/p')"
emit class requests largest total blocks seconds

s=$(sample) || exit 1
emit baseline 0 $s 0

for class in $CLASSES; do
    url=$(url_for "$class")
    [ -n "$url" ] || { echo "unknown class: $class" >&2; continue; }

    code=$(curl -s -o /dev/null -w '%{http_code}' -u "$CRED" "$BASE$url")
    case "$code" in
    200) ;;
    *)   echo "$class: $url answered $code, skipping" >&2; continue ;;
    esac

    i=0
    t0=$(date +%s)
    while [ "$i" -lt "$COUNT" ]; do
        curl -s -o /dev/null -u "$CRED" "$BASE$url"
        i=$((i + 1))
        if [ $((i % EVERY)) -eq 0 ]; then
            t=$(( $(date +%s) - t0 ))
            s=$(sample) || exit 1
            emit "$class" "$i" $s "$t"
        fi
    done
done
