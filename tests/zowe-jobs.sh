#!/bin/bash
# =========================================================================
# mvsMF Jobs REST API - Zowe CLI test suite
#
# Tests all job endpoints through Zowe CLI commands:
#   1. zowe jobs submit local-file     (submit inline JCL)
#   2. zowe jobs submit data-set       (submit from dataset)
#   3. zowe jobs list jobs              (list jobs)
#   4. zowe jobs view job-status-by-jobid  (job status)
#   5. zowe jobs list spool-files-by-jobid (spool files)
#   6. zowe jobs view spool-file-by-id     (spool records)
#   7. zowe jobs delete job              (purge)
#
# Prerequisites:
#   - Copy tests/.config/zowe.config.json.example to
#     tests/.config/zowe.config.json and fill in credentials
#   - Zowe CLI must be installed (npm i -g @zowe/cli)
#
# Usage:
#   ./tests/zowe-jobs.sh [--setup] [--cleanup]
#     --setup    Create test PDS and upload JCL member (for dataset submit)
#     --cleanup  Delete test PDS after tests
# =========================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/.config"
CONFIG_FILE="${CONFIG_DIR}/zowe.config.json"
JCL_DIR="${SCRIPT_DIR}/jcl"

if [ ! -f "$CONFIG_FILE" ]; then
	echo "ERROR: ${CONFIG_FILE} not found."
	echo "Copy zowe.config.json.example to zowe.config.json and fill in your values."
	exit 1
fi

# Tell Zowe to use our local config
export ZOWE_CLI_HOME="$CONFIG_DIR"

# Extract user from config for dataset naming
MVS_USER=$(jq -r '.profiles.mvsmf.properties.user' "$CONFIG_FILE")
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

# Run zowe command, capture stdout+stderr and exit code
run_zowe() {
	local output
	local rc=0
	output=$(zowe "$@" 2>&1) || rc=$?
	echo "$output"
	return $rc
}

# Run zowe command expecting JSON output
run_zowe_json() {
	local output
	local rc=0
	output=$(zowe "$@" --rfj 2>&1) || rc=$?
	echo "$output"
	return $rc
}

assert_rc() {
	local expected="$1"
	local actual="$2"
	local label="$3"
	if [ "$actual" -eq "$expected" ]; then
		pass "$label (rc=$actual)"
	else
		fail "$label" "expected rc=$expected, got rc=$actual"
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

wait_for_output() {
	local jobid="$1"
	local max_attempts=30
	local attempt=0

	while [ $attempt -lt $max_attempts ]; do
		local output
		output=$(run_zowe_json jobs view job-status-by-jobid "$jobid" 2>/dev/null) || true
		local status
		status=$(echo "$output" | jq -r '.data.status' 2>/dev/null)
		if [ "$status" = "OUTPUT" ]; then
			return 0
		fi
		sleep 1
		attempt=$((attempt + 1))
	done
	echo "  WARN: job ${jobid} did not reach OUTPUT status"
	return 1
}

# =========================================================================
# Setup
# =========================================================================

setup_test_pds() {
	echo ""
	echo "=== SETUP: Creating test PDS ==="

	# Submit allocation JCL
	local alloc_jcl
	alloc_jcl=$(sed "s/\${USER}/${MVS_USER}/g" "${JCL_DIR}/allocpds.jcl")

	local tmpfile
	tmpfile=$(mktemp /tmp/mvsmf-alloc-XXXXXX.jcl)
	echo "$alloc_jcl" > "$tmpfile"

	local output rc=0
	output=$(run_zowe_json jobs submit local-file "$tmpfile") || rc=$?
	rm -f "$tmpfile"

	if [ $rc -ne 0 ]; then
		echo "  WARN: PDS allocation submit failed"
		echo "  $output"
		return 1
	fi

	local alloc_jobid
	alloc_jobid=$(echo "$output" | jq -r '.data.jobid')
	echo "  Allocation job: ${alloc_jobid}"

	wait_for_output "$alloc_jobid" || true

	# Upload IEFBR14 member
	local upload_rc=0
	output=$(run_zowe files upload file-to-data-set \
		"${JCL_DIR}/iefbr14.jcl" "${TEST_PDS}(IEFBR14)" 2>&1) || upload_rc=$?

	if [ $upload_rc -eq 0 ]; then
		echo "  Uploaded IEFBR14 member to ${TEST_PDS}"
		SETUP_DONE=1
	else
		echo "  WARN: Failed to upload member"
		echo "  $output"
		return 1
	fi
}

cleanup_test_pds() {
	echo ""
	echo "=== CLEANUP: Deleting test PDS ==="
	run_zowe files delete data-set "${TEST_PDS}" 2>/dev/null || true
	echo "  Deleted ${TEST_PDS}"
}

# =========================================================================
# Tests
# =========================================================================

test_submit_local_file() {
	echo ""
	echo "--- Submit Job: local file ---"

	local output rc=0
	output=$(run_zowe_json jobs submit local-file "${JCL_DIR}/iefbr14.jcl") || rc=$?

	assert_rc 0 "$rc" "submit local file"

	if [ $rc -eq 0 ]; then
		assert_json_field_exists "$output" '.data.jobname' "submit has jobname"
		assert_json_field_exists "$output" '.data.jobid' "submit has jobid"
		assert_json_field "$output" '.data.subsystem' "JES2" "submit subsystem"
		assert_json_field "$output" '.data.type' "JOB" "submit type"
		assert_json_field_exists "$output" '.data.owner' "submit has owner"
		assert_json_field_exists "$output" '.data.status' "submit has status"

		SUBMIT_JOBNAME=$(echo "$output" | jq -r '.data.jobname')
		SUBMIT_JOBID=$(echo "$output" | jq -r '.data.jobid')
		echo "  Submitted: ${SUBMIT_JOBNAME}/${SUBMIT_JOBID}"
	fi
}

test_submit_large_jcl() {
	echo ""
	echo "--- Submit Job: large JCL (>2500 lines, issue #39) ---"

	local output rc=0
	output=$(run_zowe_json jobs submit local-file "${JCL_DIR}/largejcl.jcl") || rc=$?

	assert_rc 0 "$rc" "submit large JCL"

	if [ $rc -eq 0 ]; then
		assert_json_field_exists "$output" '.data.jobid' "large JCL submit has jobid"

		local jn ji
		jn=$(echo "$output" | jq -r '.data.jobname')
		ji=$(echo "$output" | jq -r '.data.jobid')
		echo "  Submitted: ${jn}/${ji} (2609 lines)"
		wait_for_output "$ji" || true
		run_zowe jobs delete job "$ji" >/dev/null 2>&1 || true
	fi
}

test_submit_from_dataset() {
	echo ""
	echo "--- Submit Job: from dataset ---"

	if [ "$SETUP_DONE" -eq 0 ]; then
		skip "submit from dataset (no test PDS - run with --setup)"
		return
	fi

	local output rc=0
	output=$(run_zowe_json jobs submit data-set "'${TEST_PDS}(IEFBR14)'") || rc=$?

	assert_rc 0 "$rc" "submit from dataset"

	if [ $rc -eq 0 ]; then
		assert_json_field_exists "$output" '.data.jobid' "dataset submit has jobid"

		# Purge this job
		local ji
		ji=$(echo "$output" | jq -r '.data.jobid')
		wait_for_output "$ji" || true
		run_zowe jobs delete job "$ji" >/dev/null 2>&1 || true
	fi
}

test_list_jobs_default() {
	echo ""
	echo "--- List Jobs: default (own jobs) ---"

	local output rc=0
	output=$(run_zowe_json jobs list jobs) || rc=$?

	assert_rc 0 "$rc" "list own jobs"

	if [ $rc -eq 0 ]; then
		local len
		len=$(echo "$output" | jq '.data | length' 2>/dev/null)
		if [ "$len" -gt 0 ] 2>/dev/null; then
			pass "list jobs returned results ($len)"
		else
			fail "list jobs returned no results"
		fi
	fi
}

test_list_jobs_all_owners() {
	echo ""
	echo "--- List Jobs: all owners ---"

	local output rc=0
	output=$(run_zowe_json jobs list jobs --owner "*") || rc=$?

	assert_rc 0 "$rc" "list jobs owner=*"
}

test_list_jobs_with_prefix() {
	echo ""
	echo "--- List Jobs: with prefix ---"

	local output rc=0
	output=$(run_zowe_json jobs list jobs --prefix "TESTJOB*" --owner "*") || rc=$?

	assert_rc 0 "$rc" "list jobs with prefix"
}

test_job_status() {
	echo ""
	echo "--- Job Status ---"

	if [ -z "$SUBMIT_JOBID" ]; then
		skip "job status (no submitted job)"
		return
	fi

	wait_for_output "$SUBMIT_JOBID" || true

	local output rc=0
	output=$(run_zowe_json jobs view job-status-by-jobid "$SUBMIT_JOBID") || rc=$?

	assert_rc 0 "$rc" "get job status"

	if [ $rc -eq 0 ]; then
		assert_json_field "$output" '.data.jobname' "$SUBMIT_JOBNAME" "status jobname"
		assert_json_field "$output" '.data.jobid' "$SUBMIT_JOBID" "status jobid"
		assert_json_field "$output" '.data.subsystem' "JES2" "status subsystem"
		assert_json_field_exists "$output" '.data.owner' "status has owner"
		assert_json_field_exists "$output" '.data.type' "status has type"
		assert_json_field_exists "$output" '.data.status' "status has status"
	fi
}

test_spool_files() {
	echo ""
	echo "--- Spool Files ---"

	if [ -z "$SUBMIT_JOBID" ]; then
		skip "spool files (no submitted job)"
		return
	fi

	local output rc=0
	output=$(run_zowe_json jobs list spool-files-by-jobid "$SUBMIT_JOBID") || rc=$?

	assert_rc 0 "$rc" "list spool files"

	if [ $rc -eq 0 ]; then
		local len
		len=$(echo "$output" | jq '.data | length' 2>/dev/null)
		if [ "$len" -gt 0 ] 2>/dev/null; then
			pass "spool files returned results ($len)"
		else
			fail "spool files returned no results"
		fi

		# Check structure of first spool file
		local first
		first=$(echo "$output" | jq '.data[0]')
		assert_json_field_exists "$first" '.ddname' "spool file has ddname"
		assert_json_field_exists "$first" '.id' "spool file has id"
		assert_json_field_exists "$first" '.stepname' "spool file has stepname"
	fi
}

test_spool_records() {
	echo ""
	echo "--- Spool File Records ---"

	if [ -z "$SUBMIT_JOBID" ]; then
		skip "spool records (no submitted job)"
		return
	fi

	# Get first spool file ID
	local files_output
	files_output=$(run_zowe_json jobs list spool-files-by-jobid "$SUBMIT_JOBID" 2>/dev/null) || true
	local ddid
	ddid=$(echo "$files_output" | jq '.data[0].id' 2>/dev/null)

	if [ -z "$ddid" ] || [ "$ddid" = "null" ]; then
		skip "spool records (no spool files)"
		return
	fi

	local output rc=0
	output=$(run_zowe jobs view spool-file-by-id "$SUBMIT_JOBID" "$ddid" 2>&1) || rc=$?

	assert_rc 0 "$rc" "read spool records"

	if [ $rc -eq 0 ] && [ -n "$output" ]; then
		pass "spool records content not empty"
	else
		fail "spool records content empty"
	fi
}

test_purge_job() {
	echo ""
	echo "--- Purge Job ---"

	if [ -z "$SUBMIT_JOBID" ]; then
		skip "purge job (no submitted job)"
		return
	fi

	local output rc=0
	output=$(run_zowe_json jobs delete job "$SUBMIT_JOBID") || rc=$?

	assert_rc 0 "$rc" "purge job"

	if [ $rc -eq 0 ]; then
		assert_json_field "$output" '.data.jobname' "$SUBMIT_JOBNAME" "purge jobname"
		assert_json_field "$output" '.data.jobid' "$SUBMIT_JOBID" "purge jobid"
		assert_json_field_exists "$output" '.data.owner' "purge has owner"
		assert_json_field "$output" '.success' "true" "purge success"
	fi

	SUBMIT_JOBNAME=""
	SUBMIT_JOBID=""
}

# =========================================================================
# Main
# =========================================================================

echo "========================================"
echo " mvsMF Jobs API - Zowe CLI test suite"
echo " Config: ${CONFIG_FILE}"
echo " User: ${MVS_USER}"
echo "========================================"

# Optional setup
if [ "$DO_SETUP" -eq 1 ]; then
	setup_test_pds || true
fi

# Submit tests
test_submit_local_file
test_submit_large_jcl
test_submit_from_dataset

# List tests
test_list_jobs_default
test_list_jobs_all_owners
test_list_jobs_with_prefix

# Status test
test_job_status

# Spool tests
test_spool_files
test_spool_records

# Purge test (last)
test_purge_job

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
