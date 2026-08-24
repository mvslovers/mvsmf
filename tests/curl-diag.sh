#!/bin/bash
# =========================================================================
# mvsMF diagnostics endpoint (/zosmf/test) - curl test suite
#
# Focus: the CGI-level ESTAE recovery hooks (src/testapi.c).
#
#   GET /zosmf/test?fn=abend      deliberate S0C1
#   GET /zosmf/test?fn=jesabend   the same, with a JES spool handle open
#
# Until #343 these were gated on MVSMF_ABEND_TEST in the server environment
# and this suite asserted the DISABLED path -- 400, no fault. That gate
# existed because a CGI abend used to cost the address space its storage
# permanently (mvslovers/httpd#154), and it is gone because that is no longer
# true. So the suite now asserts the property that REPLACED it:
#
#   1. an abend is caught -- 500 with the abend code in the body, not a
#      dropped connection;
#   2. the server keeps serving afterwards;
#   3. it costs no storage. This is the regression guard for httpd#175
#      (request-lifetime CGI storage) and mvslovers/libc370#126 (recovery
#      frees what a handler was building). A leak here is what used to end in
#      every endpoint answering S80A until the STC was restarted.
#
# Prerequisites:
#   - Copy .env.example to .env at the repo root and fill in
#   - curl and jq must be installed
#   - a server that may be abended on purpose: this suite DOES fault the
#     worker, several times, by design
#
# Usage:
#   ./tests/curl-diag.sh
# =========================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
	echo "ERROR: ${ENV_FILE} not found."
	echo "Copy .env.example to .env and fill in your values."
	exit 1
fi

# shellcheck source=../.env
. "$ENV_FILE"

BASE_URL="http://${MVSMF_HOST}:${MVSMF_PORT}"
AUTH="${MVSMF_USER}:${MVSMF_PASS}"
TEST_URL="${BASE_URL}/zosmf/test"

PASSED=0
FAILED=0
TOTAL=0

pass() { PASSED=$((PASSED + 1)); TOTAL=$((TOTAL + 1)); echo "  PASS: $1"; }
fail() {
	FAILED=$((FAILED + 1)); TOTAL=$((TOTAL + 1)); echo "  FAIL: $1"
	[ -n "${2:-}" ] && echo "        $2"
}

assert_http_status() {
	# $1=expected $2=actual $3=label
	if [ "$2" = "$1" ]; then pass "$3 (HTTP $2)"
	else fail "$3" "expected HTTP $1, got $2"; fi
}

# GET a test fn, echo "BODY\nHTTP_CODE"
get_fn() {
	# $1 = fn value
	curl -s -w '\n%{http_code}' -u "$AUTH" "${TEST_URL}?fn=$1"
}

echo ""
echo "========================================"
echo " mvsMF diagnostics (/zosmf/test) - curl"
echo " Host: ${MVSMF_HOST}:${MVSMF_PORT}"
echo " User: ${MVSMF_USER}"
echo "========================================"

# storage sample: echo the largest free block, or empty on failure
storage_largest() {
	curl -s -u "$AUTH" "${TEST_URL}?fn=storage&total=1" |
		sed -n 's/.*"total": \([0-9]*\).*/\1/p'
}

# =========================================================================
# 1. fn=abend faults and the router's ESTAE catches it
# =========================================================================
echo ""
echo "--- fn=abend: deliberate S0C1, caught by the router ESTAE ---"
BEFORE=$(storage_largest)
if [ -z "$BEFORE" ]; then
	fail "baseline storage sample" "fn=storage&total=1 returned nothing"
	BEFORE=0
else
	pass "baseline storage sample (${BEFORE} bytes free)"
fi

RESP=$(get_fn abend)
CODE=$(echo "$RESP" | tail -1); BODY=$(echo "$RESP" | sed '$d')

# A caught abend is a formatted 500. A dropped connection (curl code 000) means
# nothing caught it, which is the failure this hook exists to detect.
assert_http_status "500" "$CODE" "fn=abend -> caught, formatted error"

if echo "$BODY" | grep -qi "abend"; then
	pass "fn=abend body names the abend"
else
	fail "fn=abend body names the abend" "got: ${BODY}"
fi

echo ""
echo "--- server still serving after the abend ---"
CODE2=$(get_fn version | tail -1)
assert_http_status "200" "$CODE2" "server alive after fn=abend (fn=version)"

# =========================================================================
# 2. fn=jesabend: the same, with a JES handle open
#
# Recovery has to close the spool handle (MVSMF908I on the console) instead of
# leaking the JES2 spool DCBs -- issue #286. What is checkable from here is
# that the jobs API still works afterwards: a leaked handle takes the spool
# DCBs with it.
# =========================================================================
echo ""
echo "--- fn=jesabend: abend with a spool handle open ---"
CODE=$(get_fn jesabend | tail -1)
assert_http_status "500" "$CODE" "fn=jesabend -> caught, formatted error"

echo ""
echo "--- jobs API still works after the abend ---"
CODE2=$(curl -s -o /dev/null -w '%{http_code}' -u "$AUTH" \
	"${BASE_URL}/zosmf/restjobs/jobs?owner=*&prefix=HTTPD*")
assert_http_status "200" "$CODE2" "jobs list after fn=jesabend"

# =========================================================================
# 3. the abends cost no storage
#
# This is the assertion that replaced the production gate. Ten abends used to
# be measured at 4096 bytes between them (#287); the tolerance below is far
# wider than that and still far below one CGI stack, so a real leak fails it
# while ordinary allocator noise does not.
# =========================================================================
echo ""
echo "--- storage after the abends (the guard that replaced the gate) ---"
for _ in 1 2 3 4 5; do
	curl -s -o /dev/null -u "$AUTH" "${TEST_URL}?fn=abend"
done
CODE2=$(get_fn version | tail -1)
assert_http_status "200" "$CODE2" "server alive after five more abends"

AFTER=$(storage_largest)
if [ -z "$AFTER" ]; then
	fail "storage sample after the abends" "fn=storage&total=1 returned nothing"
elif [ "$BEFORE" -eq 0 ]; then
	fail "storage delta" "no usable baseline"
else
	LOST=$((BEFORE - AFTER))
	if [ "$LOST" -lt 65536 ]; then
		pass "seven abends cost ${LOST} bytes (< 64K)"
	else
		fail "seven abends cost ${LOST} bytes" \
			"a CGI abend must not leak (httpd#175, mvslovers/libc370#126). \
Before ${BEFORE}, after ${AFTER}."
	fi
fi

# =========================================================================
# 4. the response is framed (issue #355)
#
# httpd injects Transfer-Encoding: chunked only when it recognises the header
# terminator, and it recognises it by shape: the blank line has to arrive as
# its own http_printf() call. Glued to the Content-Type header, every
# /zosmf/test reply went out with no Content-Length and no Transfer-Encoding
# while announcing keep-alive, so the client had to wait for the socket to
# close -- 4.6 s measured against 0.11 s for /zosmf/info.
#
# Assert the header, not the clock: a timing assertion would go green on any
# stand whose idle timeout is short.
# =========================================================================
echo ""
echo "--- the response is framed (issue #355) ---"
HDRS=$(curl -s -D - -o /dev/null -u "$AUTH" "${TEST_URL}?fn=version")

if echo "$HDRS" | grep -qi "^Transfer-Encoding: chunked"; then
	pass "fn=version response is chunked"
elif echo "$HDRS" | grep -qi "^Content-Length:"; then
	pass "fn=version response carries a Content-Length"
else
	fail "fn=version response is framed" \
		"neither Transfer-Encoding nor Content-Length -- the client must \
wait out the idle timeout to learn the body ended"
fi

# =========================================================================
# summary
# =========================================================================
echo ""
echo "========================================"
echo " Diagnostics: ${PASSED}/${TOTAL} passed, ${FAILED} failed"
echo "========================================"

[ "$FAILED" -eq 0 ]
