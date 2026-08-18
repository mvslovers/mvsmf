#!/bin/bash
# =========================================================================
# mvsMF Jobs REST API - curl test suite
#
# Tests all 6 job endpoints:
#   1. PUT  /zosmf/restjobs/jobs              (submit inline JCL)
#   2. PUT  /zosmf/restjobs/jobs              (submit from dataset)
#   3. GET  /zosmf/restjobs/jobs              (list jobs)
#   4. GET  /zosmf/restjobs/jobs/{name}/{id}  (job status)
#   5. GET  /zosmf/restjobs/jobs/{name}/{id}/files          (spool files)
#   6. GET  /zosmf/restjobs/jobs/{name}/{id}/files/{ddid}/records (records)
#   7. DELETE /zosmf/restjobs/jobs/{name}/{id}  (purge)
#
# Prerequisites:
#   - Copy .env.example to .env at the repo root and fill in
#   - curl and jq must be installed
#
# Usage:
#   ./tests/curl-jobs.sh [--setup] [--cleanup]
#     --setup    Create test PDS and upload JCL member (for dataset submit)
#     --cleanup  Delete test PDS after tests
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
JCL_DIR="${SCRIPT_DIR}/jcl"
TEST_PDS="${MVSMF_USER}.MVSMF.TESTJCL"

# --- state ---
PASSED=0
FAILED=0
SKIPPED=0
TOTAL=0
SUBMIT_JOBNAME=""
SUBMIT_JOBID=""
DO_SETUP=0
DO_CLEANUP=0
SETUP_DONE=0

for arg in "$@"; do
	case "$arg" in
		--setup)   DO_SETUP=1 ;;
		--cleanup) DO_CLEANUP=1 ;;
	esac
done

# =========================================================================
# Helpers
# =========================================================================

pass() {
	PASSED=$((PASSED + 1))
	TOTAL=$((TOTAL + 1))
	echo "  PASS: $1"
}

fail() {
	FAILED=$((FAILED + 1))
	TOTAL=$((TOTAL + 1))
	echo "  FAIL: $1"
	if [ -n "${2:-}" ]; then
		echo "        $2"
	fi
}

skip() {
	SKIPPED=$((SKIPPED + 1))
	TOTAL=$((TOTAL + 1))
	echo "  SKIP: $1"
}

assert_http_status() {
	local expected="$1"
	local actual="$2"
	local label="$3"
	if [ "$actual" = "$expected" ]; then
		pass "$label (HTTP $actual)"
	else
		fail "$label" "expected HTTP $expected, got $actual"
	fi
}

assert_json_field() {
	local json="$1"
	local field="$2"
	local expected="$3"
	local label="$4"
	local actual
	actual=$(echo "$json" | jq -r "$field" 2>/dev/null) || actual=""
	if [ "$actual" = "$expected" ]; then
		pass "$label ($field=$actual)"
	else
		fail "$label" "$field: expected '$expected', got '$actual'"
	fi
}

assert_json_field_exists() {
	local json="$1"
	local field="$2"
	local label="$3"
	local val rc=0
	val=$(echo "$json" | jq -e "$field" 2>/dev/null) || rc=$?
	if [ $rc -eq 0 ] && [ "$val" != "null" ]; then
		pass "$label ($field present)"
	else
		fail "$label" "$field missing or null"
	fi
}

assert_json_array_nonempty() {
	local json="$1"
	local label="$2"
	local len
	len=$(echo "$json" | jq 'length' 2>/dev/null) || len=0
	if [ "$len" -gt 0 ] 2>/dev/null; then
		pass "$label (array length=$len)"
	else
		fail "$label" "expected non-empty array"
	fi
}

# curl wrapper: returns "HTTP_STATUS\nBODY"
do_curl() {
	local method="$1"
	shift
	curl -s -w '\n%{http_code}' -X "$method" -u "$AUTH" "$@"
}

# Split curl output into STATUS and BODY
split_response() {
	local response="$1"
	HTTP_STATUS=$(echo "$response" | tail -n1)
	BODY=$(echo "$response" | sed '$d')
}

wait_for_output() {
	local jobname="$1"
	local jobid="$2"
	local max_attempts=30
	local attempt=0
	local status=""

	while [ $attempt -lt $max_attempts ]; do
		local resp
		resp=$(do_curl GET "${BASE_URL}/zosmf/restjobs/jobs/${jobname}/${jobid}")
		split_response "$resp"
		status=$(echo "$BODY" | jq -r '.status' 2>/dev/null)
		if [ "$status" = "OUTPUT" ]; then
			return 0
		fi
		sleep 1
		attempt=$((attempt + 1))
	done
	echo "  WARN: job ${jobname}/${jobid} did not reach OUTPUT status"
	return 1
}

# =========================================================================
# Setup: create test PDS and upload JCL member
# =========================================================================

setup_test_pds() {
	echo ""
	echo "=== SETUP: Creating test PDS ==="

	# Allocate PDS by submitting allocation JCL
	local alloc_jcl
	alloc_jcl=$(sed "s/\${USER}/${MVSMF_USER}/g" "${JCL_DIR}/allocpds.jcl")

	local resp
	resp=$(do_curl PUT \
		-H "Content-Type: text/plain" \
		--data-binary "$alloc_jcl" \
		"${BASE_URL}/zosmf/restjobs/jobs")
	split_response "$resp"

	if [ "$HTTP_STATUS" != "200" ]; then
		echo "  WARN: PDS allocation submit failed (HTTP $HTTP_STATUS)"
		echo "  $BODY"
		return 1
	fi

	local alloc_jobname alloc_jobid
	alloc_jobname=$(echo "$BODY" | jq -r '.jobname')
	alloc_jobid=$(echo "$BODY" | jq -r '.jobid')
	echo "  Allocation job: ${alloc_jobname}/${alloc_jobid}"

	wait_for_output "$alloc_jobname" "$alloc_jobid" || true

	# Upload IEFBR14 JCL member
	resp=$(do_curl PUT \
		-H "Content-Type: text/plain" \
		-H "Content-Length: $(wc -c < "${JCL_DIR}/iefbr14.jcl")" \
		--data-binary @"${JCL_DIR}/iefbr14.jcl" \
		"${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(IEFBR14)")
	split_response "$resp"

	if [ "$HTTP_STATUS" = "204" ] || [ "$HTTP_STATUS" = "200" ]; then
		echo "  Uploaded IEFBR14 member to ${TEST_PDS}"
		SETUP_DONE=1
	else
		echo "  WARN: Failed to upload member (HTTP $HTTP_STATUS)"
		echo "  $BODY"
		return 1
	fi
}

cleanup_test_pds() {
	echo ""
	echo "=== CLEANUP: Deleting test PDS ==="

	# Delete the member first, then the PDS
	local resp
	resp=$(do_curl DELETE "${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}(IEFBR14)")
	split_response "$resp"
	echo "  Delete member IEFBR14: HTTP $HTTP_STATUS"

	resp=$(do_curl DELETE "${BASE_URL}/zosmf/restfiles/ds/${TEST_PDS}")
	split_response "$resp"
	echo "  Delete PDS ${TEST_PDS}: HTTP $HTTP_STATUS"
}

# =========================================================================
# Tests
# =========================================================================

test_submit_inline_jcl() {
	echo ""
	echo "--- Submit Job: inline JCL ---"

	local jcl
	jcl=$(cat "${JCL_DIR}/iefbr14.jcl")

	local resp
	resp=$(do_curl PUT \
		-H "Content-Type: text/plain" \
		--data-binary "$jcl" \
		"${BASE_URL}/zosmf/restjobs/jobs")
	split_response "$resp"

	assert_http_status "200" "$HTTP_STATUS" "submit inline JCL"
	assert_json_field_exists "$BODY" '.jobname' "submit response has jobname"
	assert_json_field_exists "$BODY" '.jobid' "submit response has jobid"
	assert_json_field "$BODY" '.subsystem' "JES2" "submit response subsystem"
	assert_json_field "$BODY" '.type' "JOB" "submit response type"
	assert_json_field_exists "$BODY" '.owner' "submit response has owner"
	assert_json_field_exists "$BODY" '.class' "submit response has class"
	assert_json_field_exists "$BODY" '.url' "submit response has url"
	assert_json_field_exists "$BODY" '.["files-url"]' "submit response has files-url"
	assert_json_field_exists "$BODY" '.status' "submit response has status"

	SUBMIT_JOBNAME=$(echo "$BODY" | jq -r '.jobname')
	SUBMIT_JOBID=$(echo "$BODY" | jq -r '.jobid')
	echo "  Submitted: ${SUBMIT_JOBNAME}/${SUBMIT_JOBID}"
}

test_submit_inline_jcl_with_intrdr_headers() {
	echo ""
	echo "--- Submit Job: inline JCL with X-IBM-Intrdr headers ---"

	local jcl
	jcl=$(cat "${JCL_DIR}/iefbr14.jcl")

	local resp
	resp=$(do_curl PUT \
		-H "Content-Type: text/plain" \
		-H "X-IBM-Intrdr-Mode: TEXT" \
		-H "X-IBM-Intrdr-Lrecl: 80" \
		-H "X-IBM-Intrdr-Recfm: F" \
		--data-binary "$jcl" \
		"${BASE_URL}/zosmf/restjobs/jobs")
	split_response "$resp"

	assert_http_status "200" "$HTTP_STATUS" "submit with intrdr headers"

	# Purge this job to avoid clutter
	local jn ji
	jn=$(echo "$BODY" | jq -r '.jobname')
	ji=$(echo "$BODY" | jq -r '.jobid')
	if [ "$jn" != "null" ] && [ "$ji" != "null" ]; then
		wait_for_output "$jn" "$ji" || true
		do_curl DELETE "${BASE_URL}/zosmf/restjobs/jobs/${jn}/${ji}" >/dev/null 2>&1 || true
	fi
}

test_submit_notify_sysuid_trailing_param() {
	echo ""
	echo "--- Submit Job: NOTIFY=&SYSUID followed by another parameter (issue #130) ---"

	# Regression for #130: VS Code submits fixed RECFM=F LRECL=80 records, so each
	# line is padded with trailing blanks to column 80. When NOTIFY=&SYSUID was NOT
	# the last parameter on the job card, the &SYSUID->userid rebuild carried those
	# trailing blanks into the 72-byte job card buffer and overflowed
	# ("MVSMF22E Buffer overflow in snprintf" -> "Failed to analyze job card" -> 400).
	# Build 80-column-padded lines with printf to reproduce the exact condition.
	local jcl
	jcl=$(printf '%-80s\n%-80s\n%-80s\n' \
		'//RGNJOB   JOB CLASS=A,MSGCLASS=H,NOTIFY=&SYSUID,REGION=8M' \
		'//STEP1    EXEC PGM=IEFBR14' \
		'//')

	local resp
	resp=$(do_curl PUT \
		-H "Content-Type: text/plain" \
		-H "X-IBM-Intrdr-Mode: TEXT" \
		-H "X-IBM-Intrdr-Lrecl: 80" \
		-H "X-IBM-Intrdr-Recfm: F" \
		--data-binary "$jcl" \
		"${BASE_URL}/zosmf/restjobs/jobs")
	split_response "$resp"

	assert_http_status "200" "$HTTP_STATUS" "submit NOTIFY=&SYSUID with trailing REGION param"

	# Purge this job to avoid clutter
	local jn ji
	jn=$(echo "$BODY" | jq -r '.jobname')
	ji=$(echo "$BODY" | jq -r '.jobid')
	if [ "$jn" != "null" ] && [ "$ji" != "null" ]; then
		wait_for_output "$jn" "$ji" || true
		do_curl DELETE "${BASE_URL}/zosmf/restjobs/jobs/${jn}/${ji}" >/dev/null 2>&1 || true
	fi
}

test_submit_without_notify_gets_retcode() {
	echo ""
	echo "--- Submit Job: card without NOTIFY still reports a retcode (issue #307) ---"

	# HASPSSSM gates every write to JCTCNVRC/JCTJTFLG/JCTJTCC on "CLI JCTTSUAF,0",
	# so a job whose card carries no NOTIFY used to record no completion code at
	# all and answered "retcode": null however it ended. mvsMF now injects
	# NOTIFY=<caller> onto the continuation card it already generates for
	# USER=/PASSWORD=. The fixture ends CC 0012, so a plain non-null assertion
	# would not be enough -- the value itself has to arrive.
	local jcl
	jcl=$(cat "${JCL_DIR}/nonotify.jcl")

	local resp
	resp=$(do_curl PUT \
		-H "Content-Type: text/plain" \
		--data-binary "$jcl" \
		"${BASE_URL}/zosmf/restjobs/jobs")
	split_response "$resp"

	assert_http_status "200" "$HTTP_STATUS" "submit JCL without NOTIFY"

	local jn ji
	jn=$(echo "$BODY" | jq -r '.jobname')
	ji=$(echo "$BODY" | jq -r '.jobid')
	if [ "$jn" = "null" ] || [ "$ji" = "null" ]; then
		skip "retcode for job submitted without NOTIFY (no jobid)"
		return
	fi

	if wait_for_output "$jn" "$ji"; then
		resp=$(do_curl GET "${BASE_URL}/zosmf/restjobs/jobs/${jn}/${ji}")
		split_response "$resp"
		assert_json_field "$BODY" '.retcode' "CC 0012" \
			"retcode for job submitted without NOTIFY"
	else
		skip "retcode for job submitted without NOTIFY (job never reached OUTPUT)"
	fi

	do_curl DELETE "${BASE_URL}/zosmf/restjobs/jobs/${jn}/${ji}" >/dev/null 2>&1 || true
}

test_submit_literal_notify_not_duplicated() {
	echo ""
	echo "--- Submit Job: card with a literal NOTIFY keeps exactly one (issue #307) ---"

	# The failure mode of the injection: a card that already names a userid must
	# not get a second NOTIFY, or JES2 rejects the statement with a duplicate
	# keyword and the job never runs. The existing fixtures all write
	# NOTIFY=&SYSUID, which takes the rewrite branch instead of the presence
	# test, so this is the only case that exercises the flag.
	local jcl
	jcl=$(printf '%s\n%s\n' \
		"//DUPNOTF  JOB (ACCT),'DUP NOTIFY',CLASS=A,NOTIFY=${MVSMF_USER}" \
		'//STEP1    EXEC PGM=IEFBR14')

	local resp
	resp=$(do_curl PUT \
		-H "Content-Type: text/plain" \
		--data-binary "$jcl" \
		"${BASE_URL}/zosmf/restjobs/jobs")
	split_response "$resp"

	assert_http_status "200" "$HTTP_STATUS" "submit card with a literal NOTIFY"

	local jn ji
	jn=$(echo "$BODY" | jq -r '.jobname')
	ji=$(echo "$BODY" | jq -r '.jobid')
	if [ "$jn" = "null" ] || [ "$ji" = "null" ]; then
		skip "literal NOTIFY not duplicated (no jobid)"
		return
	fi

	if wait_for_output "$jn" "$ji"; then
		resp=$(do_curl GET "${BASE_URL}/zosmf/restjobs/jobs/${jn}/${ji}")
		split_response "$resp"
		# A second NOTIFY would show up here as "JCL ERROR", not "CC 0000".
		assert_json_field "$BODY" '.retcode' "CC 0000" \
			"literal NOTIFY not duplicated"
	else
		skip "literal NOTIFY not duplicated (job never reached OUTPUT)"
	fi

	do_curl DELETE "${BASE_URL}/zosmf/restjobs/jobs/${jn}/${ji}" >/dev/null 2>&1 || true
}

test_submit_jobcard_too_long() {
	echo ""
	echo "--- Submit Job: JOB card with no room for the injected operands (issue #130) ---"

	# process_jobcard() has to append a comma to the last job card line to
	# continue onto the USER=/PASSWORD= card it generates, and cannot once the
	# line reaches column 70. That used to be reported as "No valid JOB card
	# found in submitted JCL", which sends people looking for a missing card.
	# It now has its own message and reason code 12.
	local head="//OVRFLOW  JOB (ACCT),'"
	local tail="',CLASS=A"
	local pad=$((70 - ${#head} - ${#tail}))
	local name
	name=$(printf '%*s' "$pad" '' | tr ' ' 'X')

	local card="${head}${name}${tail}"
	if [ "${#card}" -ne 70 ]; then
		fail "JOB card too long fixture" "built a ${#card}-column card, expected 70"
		return
	fi

	local jcl
	jcl=$(printf '%s\n%s\n' "$card" '//STEP1    EXEC PGM=IEFBR14')

	local resp
	resp=$(do_curl PUT \
		-H "Content-Type: text/plain" \
		--data-binary "$jcl" \
		"${BASE_URL}/zosmf/restjobs/jobs")
	split_response "$resp"

	assert_http_status "400" "$HTTP_STATUS" "submit JOB card with no room for injection"
	assert_json_field "$BODY" '.reason' "12" "JOB card too long reason code"

	local msg
	msg=$(echo "$BODY" | jq -r '.message' 2>/dev/null) || msg=""
	case "$msg" in
		*"too long"*) pass "JOB card too long message (\"$msg\")" ;;
		*)            fail "JOB card too long message" "got '$msg'" ;;
	esac
}

test_submit_invalid_intrdr_header() {
	echo ""
	echo "--- Submit Job: invalid X-IBM-Intrdr-Mode header ---"

	local jcl
	jcl=$(cat "${JCL_DIR}/iefbr14.jcl")

	local resp
	resp=$(do_curl PUT \
		-H "Content-Type: text/plain" \
		-H "X-IBM-Intrdr-Mode: BINARY" \
		--data-binary "$jcl" \
		"${BASE_URL}/zosmf/restjobs/jobs")
	split_response "$resp"

	assert_http_status "400" "$HTTP_STATUS" "submit with invalid intrdr mode"
}

test_submit_invalid_content_type() {
	echo ""
	echo "--- Submit Job: invalid Content-Type ---"

	local resp
	resp=$(do_curl PUT \
		-H "Content-Type: application/xml" \
		-d "<jcl/>" \
		"${BASE_URL}/zosmf/restjobs/jobs")
	split_response "$resp"

	assert_http_status "400" "$HTTP_STATUS" "submit with invalid content-type"
}

test_submit_from_dataset() {
	echo ""
	echo "--- Submit Job: from dataset ---"

	if [ "$SETUP_DONE" -eq 0 ]; then
		skip "submit from dataset (no test PDS - run with --setup)"
		return
	fi

	local resp
	resp=$(do_curl PUT \
		-H "Content-Type: application/json" \
		-d "{\"file\":\"'//${TEST_PDS}(IEFBR14)'\"}" \
		"${BASE_URL}/zosmf/restjobs/jobs")
	split_response "$resp"

	assert_http_status "200" "$HTTP_STATUS" "submit from dataset"
	assert_json_field_exists "$BODY" '.jobid' "dataset submit has jobid"

	# Purge this job
	local jn ji
	jn=$(echo "$BODY" | jq -r '.jobname')
	ji=$(echo "$BODY" | jq -r '.jobid')
	if [ "$jn" != "null" ] && [ "$ji" != "null" ]; then
		wait_for_output "$jn" "$ji" || true
		do_curl DELETE "${BASE_URL}/zosmf/restjobs/jobs/${jn}/${ji}" >/dev/null 2>&1 || true
	fi
}

test_submit_large_jcl() {
	echo ""
	echo "--- Submit Job: large JCL (>2500 lines, issue #39) ---"

	local resp
	resp=$(do_curl PUT \
		-H "Content-Type: text/plain" \
		--data-binary @"${JCL_DIR}/largejcl.jcl" \
		"${BASE_URL}/zosmf/restjobs/jobs")
	split_response "$resp"

	assert_http_status "200" "$HTTP_STATUS" "submit large JCL"
	assert_json_field_exists "$BODY" '.jobid' "large JCL submit has jobid"

	# Purge this job
	local jn ji
	jn=$(echo "$BODY" | jq -r '.jobname')
	ji=$(echo "$BODY" | jq -r '.jobid')
	if [ "$jn" != "null" ] && [ "$ji" != "null" ]; then
		echo "  Submitted: ${jn}/${ji} (2609 lines)"
		wait_for_output "$jn" "$ji" || true
		do_curl DELETE "${BASE_URL}/zosmf/restjobs/jobs/${jn}/${ji}" >/dev/null 2>&1 || true
	fi
}

test_submit_dataset_missing_file_field() {
	echo ""
	echo "--- Submit Job: dataset submit missing 'file' field ---"

	local resp
	resp=$(do_curl PUT \
		-H "Content-Type: application/json" \
		-d '{"bad":"field"}' \
		"${BASE_URL}/zosmf/restjobs/jobs")
	split_response "$resp"

	assert_http_status "400" "$HTTP_STATUS" "submit dataset missing file field"
}

test_submit_dataset_not_found() {
	echo ""
	echo "--- Submit Job: dataset not found ---"

	local resp
	resp=$(do_curl PUT \
		-H "Content-Type: application/json" \
		-d "{\"file\":\"'NONEXIST.DATASET(MEMBER)'\"}" \
		"${BASE_URL}/zosmf/restjobs/jobs")
	split_response "$resp"

	# Should be 404 or 400
	if [ "$HTTP_STATUS" = "404" ] || [ "$HTTP_STATUS" = "400" ]; then
		pass "submit dataset not found (HTTP $HTTP_STATUS)"
	else
		fail "submit dataset not found" "expected HTTP 404 or 400, got $HTTP_STATUS"
	fi
}

test_list_jobs() {
	echo ""
	echo "--- List Jobs ---"

	# List own jobs (default)
	local resp
	resp=$(do_curl GET "${BASE_URL}/zosmf/restjobs/jobs")
	split_response "$resp"

	assert_http_status "200" "$HTTP_STATUS" "list own jobs"
	assert_json_array_nonempty "$BODY" "list own jobs returns results"
}

test_list_jobs_with_owner() {
	echo ""
	echo "--- List Jobs: with owner=* ---"

	local resp
	resp=$(do_curl GET "${BASE_URL}/zosmf/restjobs/jobs?owner=*")
	split_response "$resp"

	assert_http_status "200" "$HTTP_STATUS" "list jobs owner=*"
	assert_json_array_nonempty "$BODY" "list all owners returns results"
}

test_list_jobs_with_prefix() {
	echo ""
	echo "--- List Jobs: with prefix filter ---"

	local resp
	resp=$(do_curl GET "${BASE_URL}/zosmf/restjobs/jobs?prefix=TESTJOB*&owner=*")
	split_response "$resp"

	assert_http_status "200" "$HTTP_STATUS" "list jobs with prefix"
}

test_list_jobs_with_jobid() {
	echo ""
	echo "--- List Jobs: with jobid filter ---"

	if [ -z "$SUBMIT_JOBID" ]; then
		skip "list jobs by jobid (no submitted job)"
		return
	fi

	local resp
	resp=$(do_curl GET "${BASE_URL}/zosmf/restjobs/jobs?jobid=${SUBMIT_JOBID}&owner=*")
	split_response "$resp"

	assert_http_status "200" "$HTTP_STATUS" "list jobs by jobid"
	assert_json_array_nonempty "$BODY" "list by jobid returns results"
}

# every element of the array must carry the requested status.  An empty array
# is a pass: status=ACTIVE legitimately matches nothing on a quiet system.
assert_all_status() {
	local json="$1"
	local want="$2"
	local label="$3"
	local len others
	len=$(echo "$json" | jq 'length' 2>/dev/null) || len=0
	others=$(echo "$json" | jq --arg s "$want" '[.[] | select(.status != $s)] | length' 2>/dev/null) || others="?"
	if [ "$others" = "0" ]; then
		pass "$label ($len jobs, all $want)"
	else
		fail "$label" "$others of $len jobs have a status other than $want"
	fi
}

test_list_jobs_with_status() {
	echo ""
	echo "--- List Jobs: with status filter ---"

	local resp all_len out_len

	# '*' means no filter, so it can only ever return a superset. Listed first
	# on purpose: the two counts come from separate requests, and a job purged
	# in between can only shrink the later one, never break the comparison.
	resp=$(do_curl GET "${BASE_URL}/zosmf/restjobs/jobs?status=*&owner=*")
	split_response "$resp"
	assert_http_status "200" "$HTTP_STATUS" "list jobs status=*"
	all_len=$(echo "$BODY" | jq 'length' 2>/dev/null) || all_len=0

	resp=$(do_curl GET "${BASE_URL}/zosmf/restjobs/jobs?status=OUTPUT&owner=*")
	split_response "$resp"
	assert_http_status "200" "$HTTP_STATUS" "list jobs status=OUTPUT"
	assert_all_status "$BODY" "OUTPUT" "status=OUTPUT excludes other statuses"
	out_len=$(echo "$BODY" | jq 'length' 2>/dev/null) || out_len=0

	if [ "$all_len" -ge "$out_len" ] 2>/dev/null; then
		pass "status=* is a superset of status=OUTPUT ($all_len >= $out_len)"
	else
		fail "status=* returned fewer jobs than status=OUTPUT" "$all_len < $out_len"
	fi

	resp=$(do_curl GET "${BASE_URL}/zosmf/restjobs/jobs?status=ACTIVE&owner=*")
	split_response "$resp"
	assert_http_status "200" "$HTTP_STATUS" "list jobs status=ACTIVE"
	assert_all_status "$BODY" "ACTIVE" "status=ACTIVE excludes OUTPUT jobs"

	# the filter is case insensitive
	resp=$(do_curl GET "${BASE_URL}/zosmf/restjobs/jobs?status=output&owner=*")
	split_response "$resp"
	assert_http_status "200" "$HTTP_STATUS" "list jobs status=output (lower case)"
	assert_all_status "$BODY" "OUTPUT" "lower case status filters the same way"

	# an unknown status matches nothing - 200 with an empty array, not an error
	resp=$(do_curl GET "${BASE_URL}/zosmf/restjobs/jobs?status=NOSUCH&owner=*")
	split_response "$resp"
	assert_http_status "200" "$HTTP_STATUS" "list jobs status=NOSUCH"
	local len
	len=$(echo "$BODY" | jq 'length' 2>/dev/null) || len="?"
	if [ "$len" = "0" ]; then
		pass "unknown status returns an empty array"
	else
		fail "unknown status returned jobs" "got $len results"
	fi
}

test_list_jobs_with_max() {
	echo ""
	echo "--- List Jobs: with max-jobs ---"

	local resp
	resp=$(do_curl GET "${BASE_URL}/zosmf/restjobs/jobs?owner=*&max-jobs=2")
	split_response "$resp"

	assert_http_status "200" "$HTTP_STATUS" "list jobs max-jobs=2"

	local len
	len=$(echo "$BODY" | jq 'length' 2>/dev/null)
	if [ "$len" -le 2 ] 2>/dev/null; then
		pass "max-jobs=2 respected (got $len)"
	else
		fail "max-jobs=2 not respected" "got $len results"
	fi

	# max-jobs caps the jobs returned, not the queue entries scanned: combined
	# with a filter it must still fill up to the limit
	local out_total out_capped
	resp=$(do_curl GET "${BASE_URL}/zosmf/restjobs/jobs?owner=*&status=OUTPUT")
	split_response "$resp"
	out_total=$(echo "$BODY" | jq 'length' 2>/dev/null) || out_total=0

	resp=$(do_curl GET "${BASE_URL}/zosmf/restjobs/jobs?owner=*&status=OUTPUT&max-jobs=1")
	split_response "$resp"
	assert_http_status "200" "$HTTP_STATUS" "list jobs status=OUTPUT&max-jobs=1"
	out_capped=$(echo "$BODY" | jq 'length' 2>/dev/null) || out_capped=0

	if [ "$out_total" -eq 0 ] 2>/dev/null; then
		skip "max-jobs with status filter (no OUTPUT jobs on the system)"
	elif [ "$out_capped" -eq 1 ] 2>/dev/null; then
		pass "max-jobs=1 with status=OUTPUT returned 1 job (of $out_total)"
	else
		fail "max-jobs limits the scan, not the result" "got $out_capped of $out_total"
	fi
}

# An ISO 8601 instant in UTC with a millisecond fraction, the shape z/OSMF uses:
# 2026-08-07T18:57:10.000Z.  JES2 has second resolution, so .000 is expected.
assert_iso8601_utc() {
	local value="$1"
	local label="$2"

	if [[ "$value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$ ]]; then
		pass "$label ($value)"
	else
		fail "$label" "not an ISO 8601 UTC instant: '$value'"
	fi
}

test_list_jobs_exec_data() {
	echo ""
	echo "--- List Jobs: exec-data ---"

	local resp
	resp=$(do_curl GET "${BASE_URL}/zosmf/restjobs/jobs?owner=*&exec-data=Y")
	split_response "$resp"

	assert_http_status "200" "$HTTP_STATUS" "list jobs exec-data=Y"

	# jq's `all` is true for an empty array, so every has()-assertion below would
	# pass vacuously on an empty spool.  Anchor them on a non-empty result first.
	assert_json_array_nonempty "$BODY" "exec-data=Y returned jobs"

	# has_key, not a value test: a job that has not started carries null, which
	# is a correct answer and must not be confused with the field being absent.
	assert_json_field "$BODY" '[.[] | has("exec-started")] | all' "true" \
		"exec-data=Y: every job has exec-started"
	assert_json_field "$BODY" '[.[] | has("exec-ended")] | all' "true" \
		"exec-data=Y: every job has exec-ended"

	# any non-null exec-started must be a well-formed UTC instant
	local started
	started=$(echo "$BODY" | jq -r '[.[] | .["exec-started"] | select(. != null)] | first // ""' 2>/dev/null)
	if [ -n "$started" ]; then
		assert_iso8601_utc "$started" "exec-started format"
	else
		skip "exec-started format (no job has started)"
	fi

	# an ACTIVE job has started but not ended -- exec-ended must be null, not a
	# placeholder date.
	#
	# Count first, and never funnel the value through jq's `//`: that operator
	# fires on null as well as on absence, so `[null] | first // "none"` yields
	# "none" and the check would skip itself in exactly the case it exists to
	# verify.
	local active_count
	active_count=$(echo "$BODY" | jq '[.[] | select(.status == "ACTIVE")] | length' 2>/dev/null) || active_count=0

	if [ "$active_count" -eq 0 ] 2>/dev/null; then
		skip "exec-ended null while active (no ACTIVE job on the system)"
	else
		local all_null
		all_null=$(echo "$BODY" | jq -r \
			'[.[] | select(.status == "ACTIVE") | .["exec-ended"] == null] | all' 2>/dev/null)
		if [ "$all_null" = "true" ]; then
			pass "exec-ended is null for all $active_count ACTIVE job(s)"
		else
			fail "exec-ended null while active" \
				"an ACTIVE job carries a non-null exec-ended"
		fi

		# the counterpart: an ACTIVE job has started, so exec-started must be set
		local started_set
		started_set=$(echo "$BODY" | jq -r \
			'[.[] | select(.status == "ACTIVE") | .["exec-started"] != null] | all' 2>/dev/null)
		if [ "$started_set" = "true" ]; then
			pass "exec-started is set for all $active_count ACTIVE job(s)"
		else
			fail "exec-started set while active" \
				"an ACTIVE job carries a null exec-started"
		fi
	fi
}

test_list_jobs_without_exec_data() {
	echo ""
	echo "--- List Jobs: exec-data absent ---"

	local resp
	resp=$(do_curl GET "${BASE_URL}/zosmf/restjobs/jobs?owner=*")
	split_response "$resp"

	assert_http_status "200" "$HTTP_STATUS" "list jobs without exec-data"

	# without the parameter the object keeps its previous shape
	assert_json_field "$BODY" '[.[] | has("exec-started")] | any' "false" \
		"no exec-started without exec-data"
	assert_json_field "$BODY" '[.[] | has("exec-ended")] | any' "false" \
		"no exec-ended without exec-data"
}

test_job_status() {
	echo ""
	echo "--- Job Status ---"

	if [ -z "$SUBMIT_JOBNAME" ] || [ -z "$SUBMIT_JOBID" ]; then
		skip "job status (no submitted job)"
		return
	fi

	wait_for_output "$SUBMIT_JOBNAME" "$SUBMIT_JOBID" || true

	local resp
	resp=$(do_curl GET "${BASE_URL}/zosmf/restjobs/jobs/${SUBMIT_JOBNAME}/${SUBMIT_JOBID}")
	split_response "$resp"

	assert_http_status "200" "$HTTP_STATUS" "get job status"
	assert_json_field "$BODY" '.jobname' "$SUBMIT_JOBNAME" "status jobname matches"
	assert_json_field "$BODY" '.jobid' "$SUBMIT_JOBID" "status jobid matches"
	assert_json_field "$BODY" '.subsystem' "JES2" "status subsystem"
	assert_json_field_exists "$BODY" '.owner' "status has owner"
	assert_json_field_exists "$BODY" '.type' "status has type"
	assert_json_field_exists "$BODY" '.class' "status has class"
	assert_json_field_exists "$BODY" '.url' "status has url"
	assert_json_field_exists "$BODY" '.["files-url"]' "status has files-url"
	assert_json_field_exists "$BODY" '.status' "status has status"
}

test_job_status_exec_data() {
	echo ""
	echo "--- Job Status: exec-data ---"

	if [ -z "$SUBMIT_JOBNAME" ] || [ -z "$SUBMIT_JOBID" ]; then
		skip "job status exec-data (no submitted job)"
		return
	fi

	wait_for_output "$SUBMIT_JOBNAME" "$SUBMIT_JOBID" || true

	local resp
	resp=$(do_curl GET \
		"${BASE_URL}/zosmf/restjobs/jobs/${SUBMIT_JOBNAME}/${SUBMIT_JOBID}?exec-data=Y")
	split_response "$resp"

	assert_http_status "200" "$HTTP_STATUS" "job status exec-data=Y"
	assert_json_field "$BODY" 'has("exec-started")' "true" "status has exec-started"
	assert_json_field "$BODY" 'has("exec-ended")' "true" "status has exec-ended"

	# the job ran to completion, so both instants must be present and well-formed
	local started ended
	started=$(echo "$BODY" | jq -r '.["exec-started"] // ""' 2>/dev/null)
	ended=$(echo "$BODY" | jq -r '.["exec-ended"] // ""' 2>/dev/null)

	if [ -n "$started" ]; then
		assert_iso8601_utc "$started" "status exec-started format"
	else
		fail "status exec-started" "null for a completed job"
	fi

	if [ -n "$ended" ]; then
		assert_iso8601_utc "$ended" "status exec-ended format"
	else
		fail "status exec-ended" "null for a completed job"
	fi

	# exec-submitted is deliberately not implemented (libc370#79) -- assert it
	# stays absent so the gap is visible if someone adds a placeholder
	assert_json_field "$BODY" 'has("exec-submitted")' "false" \
		"exec-submitted absent (libc370#79)"
}

test_job_status_not_found() {
	echo ""
	echo "--- Job Status: not found ---"

	local resp
	resp=$(do_curl GET "${BASE_URL}/zosmf/restjobs/jobs/NOSUCHJB/JOB99999")
	split_response "$resp"

	assert_http_status "404" "$HTTP_STATUS" "job status not found"
}

test_spool_files() {
	echo ""
	echo "--- Spool Files ---"

	if [ -z "$SUBMIT_JOBNAME" ] || [ -z "$SUBMIT_JOBID" ]; then
		skip "spool files (no submitted job)"
		return
	fi

	local resp
	resp=$(do_curl GET \
		"${BASE_URL}/zosmf/restjobs/jobs/${SUBMIT_JOBNAME}/${SUBMIT_JOBID}/files")
	split_response "$resp"

	assert_http_status "200" "$HTTP_STATUS" "list spool files"
	assert_json_array_nonempty "$BODY" "spool files list not empty"

	# Verify spool file object structure
	local first
	first=$(echo "$BODY" | jq '.[0]')
	assert_json_field_exists "$first" '.jobname' "spool file has jobname"
	assert_json_field_exists "$first" '.jobid' "spool file has jobid"
	assert_json_field_exists "$first" '.ddname' "spool file has ddname"
	assert_json_field_exists "$first" '.id' "spool file has id"
	assert_json_field_exists "$first" '.stepname' "spool file has stepname"
	assert_json_field_exists "$first" '.recfm' "spool file has recfm"
	assert_json_field_exists "$first" '.lrecl' "spool file has lrecl"
	assert_json_field_exists "$first" '.class' "spool file has class"
	assert_json_field_exists "$first" '.["records-url"]' "spool file has records-url"
}

test_spool_files_not_found() {
	echo ""
	echo "--- Spool Files: job not found ---"

	local resp
	resp=$(do_curl GET "${BASE_URL}/zosmf/restjobs/jobs/NOSUCHJB/JOB99999/files")
	split_response "$resp"

	assert_http_status "404" "$HTTP_STATUS" "spool files job not found"
}

test_spool_records() {
	echo ""
	echo "--- Spool File Records ---"

	if [ -z "$SUBMIT_JOBNAME" ] || [ -z "$SUBMIT_JOBID" ]; then
		skip "spool records (no submitted job)"
		return
	fi

	# Get first spool file ID
	local files_resp
	files_resp=$(do_curl GET \
		"${BASE_URL}/zosmf/restjobs/jobs/${SUBMIT_JOBNAME}/${SUBMIT_JOBID}/files")
	split_response "$files_resp"

	local ddid
	ddid=$(echo "$BODY" | jq '.[0].id' 2>/dev/null)

	if [ -z "$ddid" ] || [ "$ddid" = "null" ]; then
		skip "spool records (no spool files found)"
		return
	fi

	local resp
	resp=$(do_curl GET \
		"${BASE_URL}/zosmf/restjobs/jobs/${SUBMIT_JOBNAME}/${SUBMIT_JOBID}/files/${ddid}/records")
	split_response "$resp"

	assert_http_status "200" "$HTTP_STATUS" "read spool records"

	if [ -n "$BODY" ]; then
		pass "spool records body not empty"
	else
		fail "spool records body empty"
	fi
}

test_spool_records_exact_count() {
	echo ""
	echo "--- Spool File Records: exact record count (issue #158) ---"

	if [ -z "$SUBMIT_JOBNAME" ] || [ -z "$SUBMIT_JOBID" ]; then
		skip "spool records exact count (no submitted job)"
		return
	fi

	# JESJCLIN is a SYSIN dataset: its PDDB record count is final, and the
	# JES2 pre-built deletion line sits in the chain right behind it.
	local files_resp
	files_resp=$(do_curl GET \
		"${BASE_URL}/zosmf/restjobs/jobs/${SUBMIT_JOBNAME}/${SUBMIT_JOBID}/files")
	split_response "$files_resp"

	local ddid reccount
	ddid=$(echo "$BODY" | jq '[.[] | select(.ddname | startswith("JESJCLIN"))][0].id' 2>/dev/null)
	reccount=$(echo "$BODY" | jq '[.[] | select(.ddname | startswith("JESJCLIN"))][0]["record-count"]' 2>/dev/null)

	if [ -z "$ddid" ] || [ "$ddid" = "null" ]; then
		skip "spool records exact count (no JESJCLIN)"
		return
	fi

	local resp
	resp=$(do_curl GET \
		"${BASE_URL}/zosmf/restjobs/jobs/${SUBMIT_JOBNAME}/${SUBMIT_JOBID}/files/${ddid}/records")
	split_response "$resp"

	assert_http_status "200" "$HTTP_STATUS" "read JESJCLIN records"

	local lines
	lines=$(printf '%s' "$BODY" | grep -c '' 2>/dev/null)
	if [ "$lines" = "$reccount" ]; then
		pass "JESJCLIN line count equals record-count ($reccount)"
	else
		fail "JESJCLIN line count equals record-count" "expected $reccount, got $lines"
	fi

	if printf '%s' "$BODY" | grep -q 'JOB DELETED BY JES2'; then
		fail "no JES2 deletion tombstone in output" "tombstone line present"
	else
		pass "no JES2 deletion tombstone in output"
	fi

	if printf '%s' "$BODY" | grep -q '^- - - - '; then
		fail "no trailing dashed separator" "separator line present"
	else
		pass "no trailing dashed separator"
	fi
}

test_spool_records_stale_checkpoint() {
	echo ""
	echo "--- Spool File Records: stale checkpoint entry (issue #187) ---"

	# A spool data set JES2 has printed and purged stays in the checkpointed
	# PDDB, record count and all, while its tracks are reallocated. Reading it
	# lands on a foreign block and yields nothing. Before #187 that came back
	# as an empty 200, indistinguishable from an empty data set; it must now be
	# a 404 carrying reason 10 (REASON_SPOOL_GONE). It was 410 Gone between
	# #187 and #250, where the status was aligned to the z/OSMF list and the
	# distinction moved into the error report.
	#
	# A purge cannot be provoked from the API (purging the job removes it from
	# the checkpoint entirely, which is a 404), so this walks whatever the
	# system currently holds. Stale entries collect on long-lived started
	# tasks: SYSLOG spins its log to a SYSOUT class, a printer drains and
	# purges it, and the checkpointed PDDB keeps advertising it. The invariant
	# asserted for every spool file that advertises records is: never an empty
	# 200 - either the records come back, or the loss is reported as a 404 with
	# reason 10.
	#
	# The job list does not return STCs, so SYSLOG is located through the
	# internal /zosmf/test?fn=syslog probe (jobid + dsid/record-count per DD)
	# and read through the records endpoint directly by name and id. Falls
	# back to the job this suite submitted when the probe is unavailable.

	local jobname jobid ids probe
	jobname="SYSLOG"
	# the probe writes HTTP text lines: strip CR or the $ anchors never match
	probe=$(curl -s -u "$AUTH" "${BASE_URL}/zosmf/test?fn=syslog&step=4" 2>/dev/null | tr -d '\r')
	jobid=$(printf '%s\n' "$probe" | sed -n 's/.*jobid=\([A-Z0-9]*\).*/\1/p' | head -1)

	if [ -n "$jobid" ]; then
		# dsids the probe reports with a non-zero record count
		ids=$(printf '%s\n' "$probe" \
			| sed -n 's/^step4 .*dsid=\([0-9]*\) .*records=\([1-9][0-9]*\)$/\1/p')
	fi

	if [ -z "$jobid" ] || [ -z "$ids" ]; then
		# fall back to the job this suite submitted
		jobname="$SUBMIT_JOBNAME"
		jobid="$SUBMIT_JOBID"

		if [ -z "$jobname" ] || [ -z "$jobid" ]; then
			skip "stale checkpoint (no job to inspect)"
			return
		fi

		local files_resp
		files_resp=$(do_curl GET "${BASE_URL}/zosmf/restjobs/jobs/${jobname}/${jobid}/files")
		split_response "$files_resp"

		if [ "$HTTP_STATUS" != "200" ]; then
			skip "stale checkpoint (spool files returned HTTP $HTTP_STATUS)"
			return
		fi

		ids=$(echo "$BODY" | jq -r '.[] | select(.["record-count"] > 0) | .id' 2>/dev/null)
	fi

	if [ -z "$ids" ]; then
		skip "stale checkpoint (${jobname}(${jobid}) has no spool file with records)"
		return
	fi

	local checked=0 gone=0 bad=0 detail=""
	local id resp
	for id in $ids; do
		resp=$(do_curl GET \
			"${BASE_URL}/zosmf/restjobs/jobs/${jobname}/${jobid}/files/${id}/records")
		split_response "$resp"
		checked=$((checked + 1))

		case "$HTTP_STATUS" in
			200)
				if [ -z "$BODY" ]; then
					bad=$((bad + 1))
					detail="${detail} id=${id}:empty-200"
				fi
				;;
			404)
				# 404, not the 410 this used to be (#250). The status no
				# longer says "this was a loss", so the reason code has to:
				# REASON_SPOOL_GONE is 10, and without it a 404 here would
				# be indistinguishable from an ordinary wrong-DD miss --
				# which is exactly the information the status used to carry.
				gone=$((gone + 1))
				local cat rsn
				cat=$(echo "$BODY" | jq -r '.category // empty' 2>/dev/null)
				rsn=$(echo "$BODY" | jq -r '.reason // empty' 2>/dev/null)
				if [ -z "$cat" ]; then
					bad=$((bad + 1))
					detail="${detail} id=${id}:404-without-error-body"
				elif [ "$rsn" != "10" ]; then
					bad=$((bad + 1))
					detail="${detail} id=${id}:404-reason-${rsn}-not-SPOOL_GONE"
				fi
				;;
			*)
				bad=$((bad + 1))
				detail="${detail} id=${id}:HTTP-${HTTP_STATUS}"
				;;
		esac
	done

	if [ "$bad" -eq 0 ]; then
		pass "${jobname}(${jobid}): ${checked} spool file(s) with records, none empty-200 (${gone} reported purged)"
	else
		fail "${jobname}(${jobid}): spool files with records must never be an empty 200" \
			"${detail# }"
	fi
}

test_spool_records_invalid_ddid() {
	echo ""
	echo "--- Spool File Records: invalid DDID ---"

	if [ -z "$SUBMIT_JOBNAME" ] || [ -z "$SUBMIT_JOBID" ]; then
		skip "spool records invalid ddid (no submitted job)"
		return
	fi

	local resp
	resp=$(do_curl GET \
		"${BASE_URL}/zosmf/restjobs/jobs/${SUBMIT_JOBNAME}/${SUBMIT_JOBID}/files/999/records")
	split_response "$resp"

	assert_http_status "400" "$HTTP_STATUS" "spool records invalid ddid"
}

test_purge_job() {
	echo ""
	echo "--- Purge Job ---"

	if [ -z "$SUBMIT_JOBNAME" ] || [ -z "$SUBMIT_JOBID" ]; then
		skip "purge job (no submitted job)"
		return
	fi

	local resp
	resp=$(do_curl DELETE \
		"${BASE_URL}/zosmf/restjobs/jobs/${SUBMIT_JOBNAME}/${SUBMIT_JOBID}")
	split_response "$resp"

	assert_http_status "200" "$HTTP_STATUS" "purge job"
	assert_json_field "$BODY" '.jobname' "$SUBMIT_JOBNAME" "purge jobname matches"
	assert_json_field "$BODY" '.jobid' "$SUBMIT_JOBID" "purge jobid matches"
	assert_json_field_exists "$BODY" '.owner' "purge has owner"
	assert_json_field "$BODY" '.status' "0" "purge status is 0"
	assert_json_field_exists "$BODY" '.message' "purge has message"

	# Clear so subsequent tests don't try to use this job
	SUBMIT_JOBNAME=""
	SUBMIT_JOBID=""
}

test_purge_not_found() {
	echo ""
	echo "--- Purge Job: not found ---"

	# Three shapes an unknown job can take, all of which must answer 404 the
	# way GET /jobs/{name}/{id} does (issue #190). Only the first is a plain
	# "no such job": JES2 on 3.8j accepts JOB00001-JOB09999, so JOB99999 and
	# a non-conforming string come back from jescanj() as CANJ_SYNTX, which
	# used to fall through to a 500.
	local jid resp
	for jid in JOB09999 JOB99999 NOTAJOBID; do
		resp=$(do_curl DELETE "${BASE_URL}/zosmf/restjobs/jobs/NOSUCHJB/${jid}")
		split_response "$resp"

		assert_http_status "404" "$HTTP_STATUS" "purge job not found (${jid})"
		assert_json_field "$BODY" '.reason' "2" "purge not found: reason 2 (${jid})"
	done
}

test_purge_started_task() {
	echo ""
	echo "--- Purge Job: a started task is refused (issue #250) ---"

	# Asking to purge a running STC must answer 400 with REASON_STC_PURGE (5).
	# It was 403 until #250; 403 is not a z/OSMF status, and the refusal is
	# about what was asked for rather than about who asked.
	#
	# Aiming this at the live server looks reckless and is not: the refusal
	# does not come from mvsMF. jescanj() reports CANJ_ICAN because JES2 itself
	# holds the STC non-cancelable -- measured directly, "$C S<id>" answers
	# "$HASP000 HTTPD NON-CANCELABLE". mvsMF only maps that rc to a status, so
	# a regression in the mapping cannot turn this request into a real purge.
	local resp jobid
	jobid=$(do_curl GET "${BASE_URL}/zosmf/restjobs/jobs?owner=*&prefix=HTTPD*" \
		| sed '$d' \
		| jq -r 'map(select(.status == "ACTIVE")) | .[0].jobid // empty' 2>/dev/null)

	if [ -z "$jobid" ]; then
		skip "purge a started task (no ACTIVE HTTPD STC to aim at)"
		return
	fi

	resp=$(do_curl DELETE "${BASE_URL}/zosmf/restjobs/jobs/HTTPD/${jobid}")
	split_response "$resp"

	assert_http_status "400" "$HTTP_STATUS" "purge a started task is refused (${jobid})"
	assert_json_field "$BODY" '.reason' "5" "purge STC: reason 5 (REASON_STC_PURGE)"
}

# =========================================================================
# Main
# =========================================================================

echo "========================================"
echo " mvsMF Jobs API - curl test suite"
echo " Host: ${MVSMF_HOST}:${MVSMF_PORT}"
echo " User: ${MVSMF_USER}"
echo "========================================"

# Optional setup
if [ "$DO_SETUP" -eq 1 ]; then
	setup_test_pds || true
fi

# Submit tests
test_submit_inline_jcl
test_submit_inline_jcl_with_intrdr_headers
test_submit_notify_sysuid_trailing_param
test_submit_without_notify_gets_retcode
test_submit_literal_notify_not_duplicated
test_submit_jobcard_too_long
test_submit_invalid_intrdr_header
test_submit_invalid_content_type
test_submit_large_jcl
test_submit_from_dataset
test_submit_dataset_missing_file_field
test_submit_dataset_not_found

# List tests
test_list_jobs
test_list_jobs_with_owner
test_list_jobs_with_prefix
test_list_jobs_with_jobid
test_list_jobs_with_status
test_list_jobs_with_max
test_list_jobs_exec_data
test_list_jobs_without_exec_data

# Status tests
test_job_status
test_job_status_exec_data
test_job_status_not_found

# Spool file tests
test_spool_files
test_spool_files_not_found

# Spool records tests
test_spool_records
test_spool_records_exact_count
test_spool_records_stale_checkpoint
test_spool_records_invalid_ddid

# Purge tests (last, since it removes the test job)
test_purge_job
test_purge_not_found
test_purge_started_task

# Optional cleanup
if [ "$DO_CLEANUP" -eq 1 ] && [ "$SETUP_DONE" -eq 1 ]; then
	cleanup_test_pds
fi

# Summary
echo ""
echo "========================================"
echo " Results: ${PASSED} passed, ${FAILED} failed, ${SKIPPED} skipped (${TOTAL} total)"
echo "========================================"

if [ "$FAILED" -gt 0 ]; then
	exit 1
fi
