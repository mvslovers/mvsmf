#!/bin/bash
# =========================================================================
# mvsMF Integration Test Runner
#
# Entry point for all test suites. Runs setup, executes test suites,
# then tears down.
#
# Usage:
#   ./tests/test.sh                 # run all suites
#   ./tests/test.sh curl            # run only curl suite
#   ./tests/test.sh zowe            # run only zowe suite
#   ./tests/test.sh --setup         # include PDS setup/cleanup
# =========================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

CURL_JOBS="${SCRIPT_DIR}/curl-jobs.sh"
CURL_DS="${SCRIPT_DIR}/curl-datasets.sh"
ZOWE_JOBS="${SCRIPT_DIR}/zowe-jobs.sh"
ZOWE_DS="${SCRIPT_DIR}/zowe-datasets.sh"
ENV_FILE="${SCRIPT_DIR}/.config/.env"
ZOWE_CONFIG="${SCRIPT_DIR}/.config/zowe.config.json"

RUN_CURL=1
RUN_ZOWE=1
SETUP_FLAG=""
CURL_JOBS_RC=0
CURL_DS_RC=0
ZOWE_JOBS_RC=0
ZOWE_DS_RC=0

# =========================================================================
# Parse arguments
# =========================================================================

for arg in "$@"; do
	case "$arg" in
		curl)    RUN_CURL=1; RUN_ZOWE=0 ;;
		zowe)    RUN_CURL=0; RUN_ZOWE=1 ;;
		--setup) SETUP_FLAG="--setup --cleanup" ;;
	esac
done

# =========================================================================
# Preflight checks
# =========================================================================

preflight() {
	local ok=1

	if [ "$RUN_CURL" -eq 1 ]; then
		if [ ! -f "$ENV_FILE" ]; then
			echo "ERROR: ${ENV_FILE} not found."
			echo "  cp ${SCRIPT_DIR}/.config/.env.example ${ENV_FILE}"
			ok=0
		fi

		if ! command -v curl >/dev/null 2>&1; then
			echo "ERROR: curl not found in PATH."
			ok=0
		fi

		if ! command -v jq >/dev/null 2>&1; then
			echo "ERROR: jq not found in PATH."
			ok=0
		fi
	fi

	if [ "$RUN_ZOWE" -eq 1 ]; then
		if [ ! -f "$ZOWE_CONFIG" ]; then
			echo "ERROR: ${ZOWE_CONFIG} not found."
			echo "  cp ${SCRIPT_DIR}/.config/zowe.config.json.example ${ZOWE_CONFIG}"
			ok=0
		fi

		if ! command -v zowe >/dev/null 2>&1; then
			echo "ERROR: zowe not found in PATH."
			echo "  npm i -g @zowe/cli"
			ok=0
		fi
	fi

	if [ "$ok" -eq 0 ]; then
		exit 1
	fi
}

# =========================================================================
# Run suites
# =========================================================================

preflight

echo "=========================================="
echo " mvsMF Integration Tests"
echo "=========================================="

if [ "$RUN_CURL" -eq 1 ]; then
	echo ""
	echo ">>> Running curl jobs test suite..."
	echo ""
	# shellcheck disable=SC2086
	bash "$CURL_JOBS" $SETUP_FLAG || CURL_JOBS_RC=$?

	echo ""
	echo ">>> Running curl datasets test suite..."
	echo ""
	bash "$CURL_DS" || CURL_DS_RC=$?
fi

if [ "$RUN_ZOWE" -eq 1 ]; then
	echo ""
	echo ">>> Running Zowe CLI jobs test suite..."
	echo ""
	# shellcheck disable=SC2086
	bash "$ZOWE_JOBS" $SETUP_FLAG || ZOWE_JOBS_RC=$?

	echo ""
	echo ">>> Running Zowe CLI datasets test suite..."
	echo ""
	bash "$ZOWE_DS" || ZOWE_DS_RC=$?
fi

# =========================================================================
# Summary
# =========================================================================

echo ""
echo "=========================================="
echo " Overall Results"
echo "=========================================="

if [ "$RUN_CURL" -eq 1 ]; then
	if [ "$CURL_JOBS_RC" -eq 0 ]; then
		echo "  curl jobs:      PASSED"
	else
		echo "  curl jobs:      FAILED (exit code $CURL_JOBS_RC)"
	fi
	if [ "$CURL_DS_RC" -eq 0 ]; then
		echo "  curl datasets:  PASSED"
	else
		echo "  curl datasets:  FAILED (exit code $CURL_DS_RC)"
	fi
fi

if [ "$RUN_ZOWE" -eq 1 ]; then
	if [ "$ZOWE_JOBS_RC" -eq 0 ]; then
		echo "  zowe jobs:      PASSED"
	else
		echo "  zowe jobs:      FAILED (exit code $ZOWE_JOBS_RC)"
	fi
	if [ "$ZOWE_DS_RC" -eq 0 ]; then
		echo "  zowe datasets:  PASSED"
	else
		echo "  zowe datasets:  FAILED (exit code $ZOWE_DS_RC)"
	fi
fi

echo "=========================================="

if [ "$CURL_JOBS_RC" -ne 0 ] || [ "$CURL_DS_RC" -ne 0 ] || \
   [ "$ZOWE_JOBS_RC" -ne 0 ] || [ "$ZOWE_DS_RC" -ne 0 ]; then
	exit 1
fi
