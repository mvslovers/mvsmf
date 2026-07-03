#!/bin/bash
# =========================================================================
# deploy-desktop.sh — upload the mvsMF Desktop (static/) to the HTTPD UFS
#
# Dogfoods our own USS REST API: creates the target directory tree with
# POST /zosmf/restfiles/fs{dir} {"type":"directory"} and uploads every
# file with PUT /zosmf/restfiles/fs{path} in text mode (normal IBM-1047
# USS conversion). No binary assets exist yet.
#
# Target directory defaults to /www/mvsmf (the HTTPD's default DOCROOT
# is /www, so this is served as /mvsmf/). Override with DESKTOP_UFS_DIR
# if your HTTPD DOCROOT differs, e.g. /wwwroot/mvsmf.
#
# Connection is read from .env at the repo root. It uses the same
# MVSMF_* variables as the curl test suites, falling back to the mbt
# MBT_MVS_* variables when those are not set.
#
# Usage:
#   tools/deploy-desktop.sh              deploy static/ to the UFS
#   tools/deploy-desktop.sh --dry-run    print what would happen, no upload
#   DESKTOP_UFS_DIR=/wwwroot/mvsmf tools/deploy-desktop.sh
# =========================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] || [ "${1:-}" = "-n" ] && DRY_RUN=1

ENV_FILE="${ROOT_DIR}/.env"
if [ ! -f "$ENV_FILE" ]; then
	echo "ERROR: ${ENV_FILE} not found. Copy .env.example to .env and fill it in." >&2
	exit 1
fi
# shellcheck source=/dev/null
. "$ENV_FILE"

# Prefer the test-suite variables; fall back to the mbt deploy variables.
MVS_HOST="${MVSMF_HOST:-${MBT_MVS_HOST:-}}"
MVS_PORT="${MVSMF_PORT:-${MBT_MVS_PORT:-1080}}"
MVS_USER="${MVSMF_USER:-${MBT_MVS_USER:-}}"
MVS_PASS="${MVSMF_PASS:-${MBT_MVS_PASS:-}}"
DESKTOP_UFS_DIR="${DESKTOP_UFS_DIR:-/www/mvsmf}"

if [ "$DRY_RUN" != "1" ] && { [ -z "$MVS_HOST" ] || [ -z "$MVS_USER" ]; }; then
	echo "ERROR: set MVSMF_HOST/MVSMF_USER/MVSMF_PASS (or MBT_MVS_*) in .env" >&2
	exit 1
fi

BASE_URL="http://${MVS_HOST}:${MVS_PORT}"
AUTH="${MVS_USER}:${MVS_PASS}"
API="${BASE_URL}/zosmf/restfiles/fs"

echo "Deploying static/ -> ${BASE_URL}${DESKTOP_UFS_DIR}  (as ${MVS_USER})"
[ "$DRY_RUN" = "1" ] && echo "(dry run — no requests sent)"

FAILED=0

# --- create a directory (idempotent: UFSD_RC_EXIST maps to HTTP 400) ---
create_dir() {
	local d="$1" code
	if [ "$DRY_RUN" = "1" ]; then echo "  mkdir  ${d}"; return 0; fi
	code=$(curl -s -o /dev/null -w '%{http_code}' \
		-X POST -u "$AUTH" \
		-H "Content-Type: application/json" \
		-d '{"type":"directory"}' \
		"${API}${d}")
	case "$code" in
		200|201|204)  echo "  mkdir  ${d}  (${code})";;
		400|409)      echo "  mkdir  ${d}  (exists)";;
		*)            echo "  mkdir  ${d}  FAILED (${code})"; FAILED=$((FAILED+1));;
	esac
}

# --- upload a file in text mode (EBCDIC conversion on the server) ---
put_file() {
	local src="$1" dst="$2" code
	if [ "$DRY_RUN" = "1" ]; then echo "  put    ${dst}"; return 0; fi
	code=$(curl -s -o /dev/null -w '%{http_code}' \
		-X PUT -u "$AUTH" \
		-H "X-IBM-Data-Type: text" \
		-H "Content-Type: text/plain" \
		--data-binary @"${src}" \
		"${API}${dst}")
	case "$code" in
		200|201|204)  echo "  put    ${dst}  (${code})";;
		*)            echo "  put    ${dst}  FAILED (${code})"; FAILED=$((FAILED+1));;
	esac
}

# --- 1. create the directory tree (ancestors first, then subdirs) ---
echo "Creating directories…"
acc=""
IFS='/' read -ra parts <<< "${DESKTOP_UFS_DIR#/}"
for p in "${parts[@]}"; do
	acc="${acc}/${p}"
	create_dir "$acc"
done
while IFS= read -r d; do
	rel="${d#static}"            # /css, /js, /js/programs  (empty for static itself)
	[ -z "$rel" ] && continue
	create_dir "${DESKTOP_UFS_DIR}${rel}"
done < <(find static -type d | sort)

# --- 2. upload every file ---
echo "Uploading files…"
while IFS= read -r f; do
	rel="${f#static/}"          # index.html, css/desktop.css, js/…
	put_file "$f" "${DESKTOP_UFS_DIR}/${rel}"
done < <(find static -type f -not -name '.DS_Store' | sort)

echo "---"
if [ "$FAILED" -gt 0 ]; then
	echo "Done with ${FAILED} failure(s)."
	exit 1
fi
echo "Done. Open ${BASE_URL}/$(basename "$DESKTOP_UFS_DIR")/ in a browser."
