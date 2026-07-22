#!/bin/bash
# =========================================================================
# mvsMF diagnostics endpoint (/zosmf/test) - curl test suite
#
# Focus: the fn=abend ESTAE recovery test hook (src/testapi.c).
#
#   GET /zosmf/test?fn=abend
#
# This suite verifies the PRODUCTION-SAFETY guard, i.e. the DISABLED path:
# when the server environment does NOT set MVSMF_ABEND_TEST, fn=abend must
# return HTTP 400 and must NOT fault -- the server keeps serving. That is
# the "cannot fire in a production deployment" guarantee.
#
# The ENABLED path (MVSMF_ABEND_TEST=1 -> deliberate S0C1 -> router ESTAE
# failed() -> MVSMF97W + MVSMF99E + HTTP 500) is the CGI-level recovery path
# exercised by the httpd#123 shutdown acceptance test, not here. Running this
# suite against a server that HAS MVSMF_ABEND_TEST set will (correctly) report
# the abend test as enabled and skip the disabled-path assertions.
#
# Prerequisites:
#   - Copy .env.example to .env at the repo root and fill in
#   - curl and jq must be installed
#   - the server must NOT have MVSMF_ABEND_TEST set (production-like)
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

# =========================================================================
# 1. fn=abend is guarded: DISABLED by default -> 400, no fault
# =========================================================================
echo ""
echo "--- fn=abend guard (expect DISABLED in production) ---"
RESP=$(get_fn abend)
CODE=$(echo "$RESP" | tail -1); BODY=$(echo "$RESP" | sed '$d')

if [ "$CODE" = "400" ]; then
	pass "fn=abend disabled -> HTTP 400"

	# =====================================================================
	# 2. server survived the guarded call (did not abend/crash)
	# =====================================================================
	echo ""
	echo "--- server still serving after guarded fn=abend ---"
	RESP2=$(get_fn version)
	CODE2=$(echo "$RESP2" | tail -1)
	assert_http_status "200" "$CODE2" "server alive after fn=abend (fn=version)"
else
	# 500 (or a dropped connection) means the guard did not hold and the
	# handler actually faulted -- fail loudly, this is the safety property.
	fail "fn=abend disabled -> HTTP 400" \
		"got HTTP '${CODE}'. If 500, MVSMF_ABEND_TEST is set on the server: \
this suite must run against a production-like server with it UNSET."
fi

# =========================================================================
# summary
# =========================================================================
echo ""
echo "========================================"
echo " Diagnostics: ${PASSED}/${TOTAL} passed, ${FAILED} failed"
echo "========================================"

[ "$FAILED" -eq 0 ]
