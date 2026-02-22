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
#   - Copy tests/.config/.env.example to tests/.config/.env and fill in
#   - curl and jq must be installed
#
# Usage:
#   ./tests/curl-jobs.sh [--setup] [--cleanup]
#     --setup    Create test PDS and upload JCL member (for dataset submit)
#     --cleanup  Delete test PDS after tests
# =========================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.config/.env"

if [ ! -f "$ENV_FILE" ]; then
	echo "ERROR: ${ENV_FILE} not found."
	echo "Copy .env.example to .env and fill in your values."
	exit 1
fi

# shellcheck source=.config/.env
. "$ENV_FILE"

BASE_URL="http://${MVS_HOST}:${MVS_PORT}"
AUTH="${MVS_USER}:${MVS_PASS}"
JCL_DIR="${SCRIPT_DIR}/jcl"
TEST_PDS="${MVS_USER}.MVSMF.TESTJCL"

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
	alloc_jcl=$(sed "s/\${USER}/${MVS_USER}/g" "${JCL_DIR}/allocpds.jcl")

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

test_list_jobs_with_status() {
	echo ""
	echo "--- List Jobs: with status filter ---"

	local resp
	resp=$(do_curl GET "${BASE_URL}/zosmf/restjobs/jobs?status=OUTPUT&owner=*")
	split_response "$resp"

	assert_http_status "200" "$HTTP_STATUS" "list jobs status=OUTPUT"
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

	local resp
	resp=$(do_curl DELETE "${BASE_URL}/zosmf/restjobs/jobs/NOSUCHJB/JOB99999")
	split_response "$resp"

	assert_http_status "404" "$HTTP_STATUS" "purge job not found"
}

# =========================================================================
# Main
# =========================================================================

echo "========================================"
echo " mvsMF Jobs API - curl test suite"
echo " Host: ${MVS_HOST}:${MVS_PORT}"
echo " User: ${MVS_USER}"
echo "========================================"

# Optional setup
if [ "$DO_SETUP" -eq 1 ]; then
	setup_test_pds || true
fi

# Submit tests
test_submit_inline_jcl
test_submit_inline_jcl_with_intrdr_headers
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

# Status tests
test_job_status
test_job_status_not_found

# Spool file tests
test_spool_files
test_spool_files_not_found

# Spool records tests
test_spool_records
test_spool_records_invalid_ddid

# Purge tests (last, since it removes the test job)
test_purge_job
test_purge_not_found

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
