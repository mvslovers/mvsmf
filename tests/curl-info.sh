#!/bin/bash
# =========================================================================
# mvsMF Information service REST API - curl test suite
#
# Tests GET /zosmf/info, with the emphasis on how zosmf_port is derived
# from the request headers:
#
#   Host: name:port          -> that port, unchanged
#   Host: name               -> RFC 7230 5.4: the port is implied by the
#                               scheme, so it comes from X-Forwarded-Port,
#                               else X-Forwarded-Proto, else 80 (issue #175)
#
# A Host header this handler cannot make sense of must never fail the
# request: /zosmf/info is the first call every client makes. Before #175 a
# port-less Host answered nothing at all and dropped the connection (curl
# exit 52 / HTTP 000).
#
# The endpoint is NOT unauthenticated, though it was documented as such
# until #324 -- including in this header. Every request below therefore
# carries -u, and the last test pins the credential-less 401 down so the
# exemption does not get added back off a stale doc line.
#
# Prerequisites:
#   - Copy .env.example to .env at the repo root and fill in
#   - curl and jq must be installed
#
# Usage:
#   ./tests/curl-info.sh
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
INFO_URL="${BASE_URL}/zosmf/info"
AUTH="${MVSMF_USER}:${MVSMF_PASS}"

# The name used in the Host header under test. Deliberately not the address
# curl dials, so a response echoing it proves the header was the source.
TEST_HOST="mvsmf.test.example"

# --- state ---
PASSED=0
FAILED=0
TOTAL=0

pass() { PASSED=$((PASSED + 1)); TOTAL=$((TOTAL + 1)); echo "  PASS: $1"; }
fail() {
	FAILED=$((FAILED + 1)); TOTAL=$((TOTAL + 1)); echo "  FAIL: $1"
	[ -n "${2:-}" ] && echo "        $2"
}

assert_http_status() {
	if [ "$2" = "$1" ]; then pass "$3 (HTTP $2)"
	else fail "$3" "expected HTTP $1, got $2"; fi
}

assert_json_field() {
	local actual
	actual=$(echo "$1" | jq -r "$2" 2>/dev/null) || actual=""
	if [ "$actual" = "$3" ]; then pass "$4 ($2=$actual)"
	else fail "$4" "$2: expected '$3', got '$actual'"; fi
}

BODYF=$(mktemp)
trap 'rm -f "$BODYF"' EXIT

# GET /zosmf/info with the given extra headers; sets CODE and BODY.
# Every argument is passed to curl verbatim (use one -H per header).
info() {
	CODE=$(curl -s -u "$AUTH" -o "$BODYF" -w '%{http_code}' "$@" "$INFO_URL")
	BODY=$(cat "$BODYF")
}

# The same call with NO credentials at all -- not even an empty -u, which would
# still send an Authorization header and test something else.
info_anon() {
	CODE=$(curl -s -o "$BODYF" -w '%{http_code}' "$@" "$INFO_URL")
	BODY=$(cat "$BODYF")
}

# Credential-less, capturing the response HEADERS into HDRS.
info_anon_hdrs() {
	HDRS=$(curl -s -D- -o /dev/null "$@" "$INFO_URL")
}

# Assert a header is present / absent (case-insensitive name match).
assert_header() {
	if echo "$HDRS" | grep -iq "^$1"; then pass "$2"
	else fail "$2" "expected header '$1', got: $(echo "$HDRS" | grep -ic .) lines without it"; fi
}
assert_no_header() {
	if echo "$HDRS" | grep -iq "^$1"; then fail "$2" "header '$1' should not be present"
	else pass "$2"; fi
}

echo "========================================"
echo " mvsMF Information service - curl tests"
echo " Host: ${MVSMF_HOST}:${MVSMF_PORT}"
echo "========================================"

# =========================================================================
# 1. Host with an explicit port
# =========================================================================
echo ""
echo "--- Host with an explicit port ---"

info -H "Host: ${TEST_HOST}:${MVSMF_PORT}"
assert_http_status "200" "$CODE" "explicit port is accepted"
assert_json_field "$BODY" ".zosmf_hostname" "$TEST_HOST" "hostname comes from Host"
assert_json_field "$BODY" ".zosmf_port" "$MVSMF_PORT" "port comes from Host"

info -H "Host: ${TEST_HOST}:443"
assert_http_status "200" "$CODE" "a port mvsMF does not listen on is echoed"
assert_json_field "$BODY" ".zosmf_port" "443" "port 443 from Host"

# =========================================================================
# 2. Host without a port (issue #175)
# =========================================================================
echo ""
echo "--- Host without a port ---"

info -H "Host: ${TEST_HOST}"
assert_http_status "200" "$CODE" "port-less Host does not drop the connection"
assert_json_field "$BODY" ".zosmf_hostname" "$TEST_HOST" "hostname still comes from Host"
assert_json_field "$BODY" ".zosmf_port" "80" "port defaults to the http scheme"

info -H "Host: 127.0.0.1"
assert_http_status "200" "$CODE" "port-less Host, bare address"
assert_json_field "$BODY" ".zosmf_port" "80" "port defaults to 80"

# =========================================================================
# 3. Port-less Host behind a reverse proxy
# =========================================================================
echo ""
echo "--- port-less Host with X-Forwarded-* ---"

info -H "Host: ${TEST_HOST}" -H "X-Forwarded-Proto: https"
assert_http_status "200" "$CODE" "X-Forwarded-Proto: https"
assert_json_field "$BODY" ".zosmf_port" "443" "https implies port 443"

info -H "Host: ${TEST_HOST}" -H "X-Forwarded-Proto: http"
assert_http_status "200" "$CODE" "X-Forwarded-Proto: http"
assert_json_field "$BODY" ".zosmf_port" "80" "http implies port 80"

# Chained proxies append their own value; the leftmost is the client's.
info -H "Host: ${TEST_HOST}" -H "X-Forwarded-Proto: https, http"
assert_http_status "200" "$CODE" "X-Forwarded-Proto list"
assert_json_field "$BODY" ".zosmf_port" "443" "leftmost value of the list wins"

# A non-default public port: only X-Forwarded-Port can carry it.
info -H "Host: ${TEST_HOST}" -H "X-Forwarded-Proto: https" -H "X-Forwarded-Port: 8443"
assert_http_status "200" "$CODE" "X-Forwarded-Port"
assert_json_field "$BODY" ".zosmf_port" "8443" "X-Forwarded-Port wins over the scheme"

# An explicit port in Host is the client's own statement - it is not
# overridden by what a proxy claims.
info -H "Host: ${TEST_HOST}:8080" -H "X-Forwarded-Port: 8443"
assert_http_status "200" "$CODE" "Host port with X-Forwarded-Port"
assert_json_field "$BODY" ".zosmf_port" "8080" "Host port wins over X-Forwarded-Port"

# =========================================================================
# 4. Malformed input degrades, it does not fail
# =========================================================================
echo ""
echo "--- malformed Host ---"

info -H "Host: ${TEST_HOST}:"
assert_http_status "200" "$CODE" "trailing colon, no port"
assert_json_field "$BODY" ".zosmf_port" "80" "empty port falls back to 80"

info -H "Host: ${TEST_HOST}:99999999"
assert_http_status "200" "$CODE" "over-long port"
assert_json_field "$BODY" ".zosmf_port" "80" "unparsable port falls back to 80"

info -H "Host: ${TEST_HOST}:abc"
assert_http_status "200" "$CODE" "non-numeric port"
assert_json_field "$BODY" ".zosmf_port" "80" "invalid port falls back to 80"

info -H "Host: ${TEST_HOST}:0"
assert_http_status "200" "$CODE" "port 0"
assert_json_field "$BODY" ".zosmf_port" "80" "out-of-range port falls back to 80"

info -H "Host: ${TEST_HOST}" -H "X-Forwarded-Port: nonsense"
assert_http_status "200" "$CODE" "invalid X-Forwarded-Port"
assert_json_field "$BODY" ".zosmf_port" "80" "invalid X-Forwarded-Port is ignored"

# A Host with no name in front of the colon used to parse as SUCCESS with an
# empty string, so the handler's fallback to DEFAULT_HOST never ran and the
# client got "zosmf_hostname":"" (issue #260). The port fell back correctly in
# the same request, which is what hid it.
info -H "Host: :::garbage:::"
assert_http_status "200" "$CODE" "Host with no host name"
assert_json_field "$BODY" ".zosmf_hostname" "127.0.0.1" "hostname falls back to the default"
assert_json_field "$BODY" ".zosmf_port" "80" "unparsable port falls back to 80"

info -H "Host: :8080"
assert_http_status "200" "$CODE" "Host that is only a port"
assert_json_field "$BODY" ".zosmf_hostname" "127.0.0.1" "hostname falls back to the default"
assert_json_field "$BODY" ".zosmf_port" "8080" "the port is still taken from the header"

# =========================================================================
# 5. The rest of the payload
# =========================================================================
echo ""
echo "--- payload ---"

info -H "Host: ${TEST_HOST}:${MVSMF_PORT}"
assert_json_field "$BODY" ".zos_version" "MVS 3.8j" "zos_version"
assert_json_field "$BODY" ".api_version" "1" "api_version"
assert_json_field "$BODY" ".zosmf_saf_realm" "SAFRealm" "zosmf_saf_realm"

if [ -n "$(echo "$BODY" | jq -r '.zosmf_version // empty' 2>/dev/null)" ]; then
	pass "zosmf_version is present"
else
	fail "zosmf_version is present" "missing or empty"
fi

# =========================================================================
# 6. Authentication is required (issue #324)
# =========================================================================
echo ""
echo "--- authentication ---"

# This endpoint was documented as the unauthenticated liveness probe until
# #324 and never was one. The reference z/OSMF gates its own /zosmf/info the
# same way -- measured: 401 with WWW-Authenticate: Basic realm="defaultRealm",
# on every endpoint, and not dropped even for a client sending
# X-CSRF-ZOSMF-HEADER. This test exists so the exemption does not get added
# back by someone who finds a stale doc line.
info_anon -H "Host: ${TEST_HOST}:${MVSMF_PORT}"
assert_http_status "401" "$CODE" "a credential-less request is refused"

# RFC 9110 11.6.1 wants a challenge on a 401, and the reference sends one on
# every endpoint -- including to a client identifying itself with
# X-CSRF-ZOSMF-HEADER, so there is no API-client exemption to copy.
info_anon_hdrs
assert_header "WWW-Authenticate: Basic" "the 401 carries the challenge"

# The one exception. A browser fetch/XHR receiving the challenge gets the
# browser's native credential dialog, which withholds the response until a
# human dismisses it -- measured at 6080 ms with tests/probe-401-dialog.py --
# so the Desktop's session-expired handling never runs. Both markers are
# tested: the Desktop's own header, and the one browsers set themselves.
info_anon_hdrs -H "X-MVSMF-Client: desktop"
assert_no_header "WWW-Authenticate" "the challenge is withheld from the Desktop"

info_anon_hdrs -H "Sec-Fetch-Mode: cors"
assert_no_header "WWW-Authenticate" "the challenge is withheld from a browser fetch"

# A top-level navigation is not a scripted request: somebody typed the URL, and
# there the browser's own prompt is the useful answer.
info_anon_hdrs -H "Sec-Fetch-Mode: navigate"
assert_header "WWW-Authenticate: Basic" "a navigation still gets the challenge"

# Zowe and the SDKs send X-CSRF-ZOSMF-HEADER and must keep seeing exactly what
# the reference sends -- it is deliberately NOT a suppression signal.
info_anon_hdrs -H "X-CSRF-ZOSMF-HEADER: true"
assert_header "WWW-Authenticate: Basic" "a z/OSMF API client still gets the challenge"

# =========================================================================
# Summary
# =========================================================================
echo ""
echo "========================================"
echo " Total: ${TOTAL}  Passed: ${PASSED}  Failed: ${FAILED}"
echo "========================================"
[ "$FAILED" -eq 0 ]
