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

# When a skip is right, and when it is a failure wearing a disguise
# ---------------------------------------------------------------------------
# A skip is right when the precondition is something this suite did not create
# and cannot: other jobs on the system, a data set that only exists on one
# stand, an ACTIVE started task, a client capability (python3, a Zowe CLI flag),
# or a defect with a ticket behind it.
#
# A skip is wrong -- and reports a broken run as green -- when the precondition
# is something this suite created through the very API under test, or was
# explicitly asked to create with --setup. Its absence then means that API
# misbehaved, and that has to be red. This is #304: the dataset-submit path went
# unexercised for months behind exactly such a skip.
#
# Downstream skips ("no submitted job") are fine as they are: they only fire
# after an assertion has already failed, so the run is red regardless.

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
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
	echo "ERROR: ${ENV_FILE} not found."
	echo "Copy .env.example to .env and fill in your values."
	exit 1
fi

# shellcheck source=../.env
. "$ENV_FILE"

MVS_USER="${MVSMF_USER:-}"
if [ -z "$MVS_USER" ]; then
	echo "ERROR: MVSMF_USER is not set in ${ENV_FILE}."
	echo "  Without it every data set name is built from an empty prefix and the"
	echo "  suite silently works on the wrong HLQ. Refusing to run. See issue #204."
	exit 1
fi

# Every connection option goes on every invocation. A Zowe base profile is
# merged into each command and overrides host and credentials silently --
# passing --user/--password alone is not enough, the request still goes to
# the base profile's host and comes back 401. See issue #204.
ZOWE_CONN=(--host "$MVSMF_HOST" --port "$MVSMF_PORT"
	--protocol "${MVSMF_PROTOCOL:-http}"
	--user "$MVS_USER" --password "$MVSMF_PASS"
	--reject-unauthorized false)
TEST_PDS="${MVS_USER}.MVSMF.TESTJCL"
# mvsMF reads the userid from the ACEE, where RACF keeps it canonical (upper
# case). .env may hold it in any case, so fold a copy for value comparisons.
MVS_USER_UC=$(printf '%s' "${MVS_USER}" | tr '[:lower:]' '[:upper:]')

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
	output=$(zowe "$@" "${ZOWE_CONN[@]}" 2>&1 </dev/null) || rc=$?
	echo "$output"
	return $rc
}

# Does the test PDS exist? The dataset-submit tests gated on "--setup ran in
# this invocation", so they skipped whenever the PDS was already there from an
# earlier run -- which is most of the time.
have_test_pds() {
	# "zowe files list data-set" exits 0 on an empty list, so the exit code says
	# nothing -- count the rows.
	local out
	out=$(zowe files list data-set "${TEST_PDS}" --rfj "${ZOWE_CONN[@]}" 2>/dev/null) || return 1
	[ "$(echo "$out" | jq -r '.data.apiResponse.items | length' 2>/dev/null)" != "0" ]
}

# Run zowe command expecting JSON output
run_zowe_json() {
	local output
	local rc=0
	output=$(zowe "$@" --rfj "${ZOWE_CONN[@]}" 2>&1 </dev/null) || rc=$?
	echo "$output"
	return $rc
}

# A precondition that --setup was supposed to establish is a failure when
# --setup was requested, and only a skip when it was not. Reporting it as a skip
# either way is what let a broken setup look green (#304).
missing_precondition() {
	local label="$1" reason="$2"
	if [ "$DO_SETUP" -eq 1 ]; then
		fail "$label" "$reason (--setup was requested)"
	else
		skip "$label ($reason)"
	fi
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

	# Allocate through the files API rather than by submitting allocation JCL.
	# allocpds.jcl names a UNIT/VOLUME pair, so it JCL-errors on any stand that
	# does not have it -- setup then returned 1, SETUP_DONE stayed 0, and every
	# dataset-submit test skipped while the suite still reported green.
	local output rc=0

	if have_test_pds; then
		echo "  ${TEST_PDS} already exists, reusing it"
	else
		output=$(run_zowe files create data-set-partitioned "${TEST_PDS}" \
			--allocation-space-unit TRK --primary-space 1 --secondary-space 1 \
			--directory-blocks 5 --record-format FB --record-length 80 \
			--block-size 800) || rc=$?

		if [ $rc -ne 0 ]; then
			echo "  WARN: PDS allocation failed"
			echo "  $output"
			return 1
		fi
		echo "  Allocated ${TEST_PDS}"
	fi

	local member src
	for member in IEFBR14 NONOTFY; do
		case "$member" in
			IEFBR14) src="${JCL_DIR}/iefbr14.jcl" ;;
			NONOTFY) src="${JCL_DIR}/nonotify.jcl" ;;
		esac

		rc=0
		output=$(run_zowe files upload file-to-data-set \
			"$src" "${TEST_PDS}(${member})" 2>&1) || rc=$?

		if [ $rc -ne 0 ]; then
			echo "  WARN: Failed to upload ${member}"
			echo "  $output"
			return 1
		fi
		echo "  Uploaded ${member} to ${TEST_PDS}"
	done

	SETUP_DONE=1
}

cleanup_test_pds() {
	echo ""
	echo "=== CLEANUP: Deleting test PDS ==="
	# --for-sure is not optional: without it the delete is refused and the old
	# "2>/dev/null || true; echo Deleted" reported success either way, so the
	# test PDS survived every run.
	local member rc=0
	for member in IEFBR14 NONOTFY; do
		rc=0
		run_zowe files delete data-set "${TEST_PDS}(${member})" --for-sure \
			>/dev/null 2>&1 || rc=$?
		echo "  Delete member ${member}: rc=${rc}"
	done

	rc=0
	run_zowe files delete data-set "${TEST_PDS}" --for-sure >/dev/null 2>&1 || rc=$?
	if [ $rc -eq 0 ]; then
		echo "  Deleted ${TEST_PDS}"
	else
		echo "  WARN: failed to delete ${TEST_PDS} (rc=${rc})"
	fi
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
		# The value, not just the key (#210). JES2 has not written JCTUSEID
		# this early, so mvsMF answers from the USER= it injected -- and a
		# present-but-empty key passes an exists check.
		assert_json_field "$output" '.data.owner' "$MVS_USER_UC" "submit owner"
		assert_json_field_exists "$output" '.data.status' "submit has status"

		SUBMIT_JOBNAME=$(echo "$output" | jq -r '.data.jobname')
		SUBMIT_JOBID=$(echo "$output" | jq -r '.data.jobid')
		echo "  Submitted: ${SUBMIT_JOBNAME}/${SUBMIT_JOBID}"
	fi
}

test_submit_notify_sysuid_trailing_param() {
	echo ""
	echo "--- Submit Job: NOTIFY=&SYSUID followed by another parameter (issue #130) ---"

	# Regression for #130: clients that submit fixed RECFM=F LRECL=80 records pad
	# each line with trailing blanks to column 80. When NOTIFY=&SYSUID was NOT the
	# last parameter on the job card, the &SYSUID->userid rebuild carried those
	# trailing blanks into the 72-byte job card buffer and overflowed -> HTTP 400.
	# Build an 80-column-padded local file to reproduce the exact condition.
	local tmpfile
	tmpfile=$(mktemp /tmp/mvsmf-notify-XXXXXX.jcl)
	printf '%-80s\n%-80s\n%-80s\n' \
		'//RGNJOB   JOB CLASS=A,MSGCLASS=H,NOTIFY=&SYSUID,REGION=8M' \
		'//STEP1    EXEC PGM=IEFBR14' \
		'//' > "$tmpfile"

	local output rc=0
	output=$(run_zowe_json jobs submit local-file "$tmpfile") || rc=$?
	rm -f "$tmpfile"

	assert_rc 0 "$rc" "submit NOTIFY=&SYSUID with trailing REGION param"

	if [ $rc -eq 0 ]; then
		assert_json_field_exists "$output" '.data.jobid' "trailing-param submit has jobid"

		local jn ji
		jn=$(echo "$output" | jq -r '.data.jobname')
		ji=$(echo "$output" | jq -r '.data.jobid')
		echo "  Submitted: ${jn}/${ji}"
		wait_for_output "$ji" || true
		run_zowe jobs delete job "$ji" >/dev/null 2>&1 || true
	fi
}

test_submit_without_notify_wait_for_output() {
	echo ""
	echo "--- Submit Job: --wait-for-output on a card without NOTIFY (issue #307) ---"

	# The motivating case. HASPSSSM records a job's completion code only behind
	# "CLI JCTTSUAF,0", so a card without NOTIFY used to answer "retcode": null
	# for the whole life of the job -- and --wait-for-output polls until retcode
	# is non-null, so this command never returned. mvsMF now injects
	# NOTIFY=<caller> onto the card it already generates for USER=/PASSWORD=.
	# Nothing here adds NOTIFY: that is the point.
	local tmpfile
	tmpfile=$(mktemp /tmp/mvsmf-nonotify-XXXXXX.jcl)
	printf '%s\n%s\n' \
		"//NONOTFY  JOB (ACCT),'NO NOTIFY TEST',CLASS=A,MSGCLASS=H" \
		'//STEP1    EXEC PGM=IEFBR14' > "$tmpfile"

	local output rc=0
	output=$(run_zowe_json jobs submit local-file "$tmpfile" --wait-for-output) || rc=$?
	rm -f "$tmpfile"

	# Do not assert on the exit code: what this test is about is that the
	# command *returned* and carries a retcode. Whether Zowe exits non-zero for
	# a particular completion code is Zowe's business, not mvsMF's, and asserting
	# it here would report a client convention as a server fault.
	if [ $rc -ne 0 ]; then
		echo "  NOTE: zowe exited rc=${rc}; judging the result from the JSON"
	fi

	assert_json_field "$output" '.data.retcode' "CC 0000" \
		"retcode after --wait-for-output without NOTIFY"

	local ji
	ji=$(echo "$output" | jq -r '.data.jobid' 2>/dev/null) || ji="null"
	if [ "$ji" != "null" ] && [ -n "$ji" ]; then
		run_zowe jobs delete job "$ji" >/dev/null 2>&1 || true
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

	if ! have_test_pds; then
		missing_precondition "submit from dataset" "no ${TEST_PDS}"
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

test_submit_from_dataset_without_notify() {
	echo ""
	echo "--- Submit Job: from dataset, card without NOTIFY (issue #307) ---"

	# submit_file() is a separate caller of process_jobcard() from the inline
	# path, so the NOTIFY injection has to be shown on this one too.
	if ! have_test_pds; then
		missing_precondition "dataset submit without NOTIFY" "no ${TEST_PDS}"
		return
	fi

	local output rc=0
	output=$(run_zowe_json jobs submit data-set "'${TEST_PDS}(NONOTFY)'" \
		--wait-for-output) || rc=$?

	if [ $rc -ne 0 ]; then
		echo "  NOTE: zowe exited rc=${rc}; judging the result from the JSON"
	fi

	assert_json_field "$output" '.data.retcode' "CC 0012" \
		"retcode for dataset submit without NOTIFY"

	local ji
	ji=$(echo "$output" | jq -r '.data.jobid' 2>/dev/null) || ji="null"
	if [ "$ji" != "null" ] && [ -n "$ji" ]; then
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

test_list_jobs_exec_data() {
	echo ""
	echo "--- List Jobs: --exec-data ---"

	local output rc=0
	output=$(run_zowe_json jobs list jobs --owner "*" --exec-data) || rc=$?

	assert_rc 0 "$rc" "list jobs --exec-data"

	if [ $rc -ne 0 ]; then
		return
	fi

	# the CLI turns --exec-data into exec-data=Y on the wire; every job object
	# must carry the keys, though the values may be null for a job that has not
	# reached that stage
	assert_json_field "$output" '[.data[] | has("exec-started")] | all' "true" \
		"--exec-data: every job has exec-started"
	assert_json_field "$output" '[.data[] | has("exec-ended")] | all' "true" \
		"--exec-data: every job has exec-ended"

	# what the user actually sees: the exec-started column must not be blank for
	# a job that has run.  This is the regression #208 reported.
	local started
	started=$(echo "$output" | jq -r \
		'[.data[] | .["exec-started"] | select(. != null)] | first // ""' 2>/dev/null)
	if [ -z "$started" ]; then
		skip "--exec-data: exec-started populated (no job has started)"
	elif [[ "$started" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$ ]]; then
		pass "--exec-data: exec-started is an ISO 8601 UTC instant ($started)"
	else
		fail "--exec-data: exec-started format" "got '$started'"
	fi
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
	# A setup that was explicitly asked for and then failed is a failure. It used
	# to be swallowed here, after which every test depending on it took its skip
	# branch and the run still reported green -- which is how the dataset-submit
	# path went unexercised for months (#304).
	if ! setup_test_pds; then
		fail "setup: create the test PDS" "--setup was requested and setup failed"
	fi
fi

# Submit tests
test_submit_local_file
test_submit_notify_sysuid_trailing_param
test_submit_without_notify_wait_for_output
test_submit_large_jcl
test_submit_from_dataset
test_submit_from_dataset_without_notify

# List tests
test_list_jobs_default
test_list_jobs_all_owners
test_list_jobs_with_prefix
test_list_jobs_exec_data

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
