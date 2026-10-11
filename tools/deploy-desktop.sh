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
# The connection comes from the mbt target, the same way the REST test
# suites get it (tests/lib/conn.sh): the target's mvsMF URL and user and
# the token of mbt's session -- no password.
#
# Usage:
#   mbt run deploy-desktop                   deploy static/ to the UFS
#   mbt run deploy-desktop -- --dry-run      print what would happen, no upload
#   DESKTOP_UFS_DIR=/wwwroot/mvsmf mbt run deploy-desktop
# =========================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] || [ "${1:-}" = "-n" ] && DRY_RUN=1

# shellcheck source=../tests/lib/conn.sh
. "${ROOT_DIR}/tests/lib/conn.sh"

DESKTOP_UFS_DIR="${DESKTOP_UFS_DIR:-/www/mvsmf}"
API="${BASE_URL}/zosmf/restfiles/fs"

echo "Deploying static/ -> ${BASE_URL}${DESKTOP_UFS_DIR}  (as ${MVSMF_USER})"
[ "$DRY_RUN" = "1" ] && echo "(dry run — no requests sent)"

FAILED=0

# --- create a directory (idempotent: UFSD_RC_EXIST maps to HTTP 400) ---
create_dir() {
	local d="$1" code
	if [ "$DRY_RUN" = "1" ]; then echo "  mkdir  ${d}"; return 0; fi
	code=$(curl -s -o /dev/null -w '%{http_code}' \
		-X POST -K "$MVSMF_CURLRC" \
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
		-X PUT -K "$MVSMF_CURLRC" \
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
