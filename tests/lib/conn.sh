# shellcheck shell=bash
# =========================================================================
# tests/lib/conn.sh -- the connection every REST suite uses (#400)
#
# Sourced, never run. The suites take their connection from the mbt target
# (~/.mbt/targets.toml), which `mbt run rest-tests` hands over in the
# environment (mbt/init.lua):
#
#   MVSMF_URL     http://host[:port] of mvsMF, the target's [mvsmf] url
#   MVSMF_USER    the target's user; also the HLQ of every test data set
#   MVSMF_TOKEN   the LtpaToken2 of mbt's session for this run
#   MVSMF_USER2   optional: the target's further user "test2", an ordinary
#   MVSMF_TOKEN2  (non-admin) userid, and a session of its own for it
#
# No password reaches a suite: mbt never hands one to another program. A test
# that needs one -- a Basic logon, a wrong password -- is in mbt/lua/ instead.
#
# The token belongs to mbt's session and is shared by every suite of the run.
# NEVER log it off (DELETE /zosmf/services/authenticate): that ends the run for
# every suite after this one. A logout test opens a session of its own, in Lua.
#
# What this file provides:
#   BASE_URL, MVSMF_HOST, MVSMF_PORT, MVSMF_PROTOCOL
#   MVSMF_CURLRC    a curl config carrying the session cookie: `curl -K
#                   "$MVSMF_CURLRC" ...` where a suite used `-u user:pass`.
#                   A file, not an argument, so the token stays off the process
#                   list; not `-K -`, because some calls send their body on
#                   stdin.
#   MVSMF_CURLRC2   the same for MVSMF_USER2, when the target has that user
#   zowe            a function in front of the Zowe CLI, see below
#   ZOWE_CONN       the connection options for every zowe call
#   mvsmf_dev_build "${BASE_URL}/zosmf/info"
#                   succeeds when the server is a development build, the only
#                   kind that registers /zosmf/test (#508): the version GET
#                   /zosmf/info reports ends in "-dev". A suite whose
#                   assertions need an fn= probe asks first and skips. If the
#                   version cannot be read at all, it stops the suite.
#   mvsmf_on_exit   adds a command to the EXIT trap. Use it instead of `trap
#                   ... EXIT`, which would replace the cleanup of this file.
# =========================================================================

mvsmf_conn_die() {
	echo "ERROR: $1" >&2
	echo "  Run it through mbt, which takes the connection from the target:" >&2
	echo "  mbt run rest-tests [-- SUITE ...], or mbt run deploy-desktop" >&2
	exit 1
}

[ -n "${MVSMF_URL:-}" ]   || mvsmf_conn_die "MVSMF_URL is not set."
[ -n "${MVSMF_USER:-}" ]  || mvsmf_conn_die "MVSMF_USER is not set."
[ -n "${MVSMF_TOKEN:-}" ] || mvsmf_conn_die "MVSMF_TOKEN is not set: no mvsMF session."

# A userid is upper case on MVS, and every data set name is built from it.
MVSMF_USER=$(printf '%s' "$MVSMF_USER" | tr '[:lower:]' '[:upper:]')
if [ -n "${MVSMF_USER2:-}" ]; then
	MVSMF_USER2=$(printf '%s' "$MVSMF_USER2" | tr '[:lower:]' '[:upper:]')
fi

# http://host[:port][/] -- mbt supports http only, and the port defaults to 80.
_u="${MVSMF_URL%/}"
case "$_u" in
	http://*) ;;
	*) mvsmf_conn_die "MVSMF_URL '${MVSMF_URL}' is not an http:// URL." ;;
esac
MVSMF_PROTOCOL=http
_u="${_u#http://}"
_u="${_u%%/*}"
case "$_u" in
	*:*) MVSMF_HOST="${_u%:*}"; MVSMF_PORT="${_u##*:}" ;;
	*)   MVSMF_HOST="$_u";      MVSMF_PORT=80 ;;
esac
unset _u
BASE_URL="${MVSMF_PROTOCOL}://${MVSMF_HOST}:${MVSMF_PORT}"

# --- cleanup ------------------------------------------------------------
# One EXIT trap for the whole suite. A suite's own commands run before this
# file's, so a cleanup that still talks to mvsMF finds its curl config.
MVSMF_EXIT_CMDS=""
mvsmf_on_exit() {
	MVSMF_EXIT_CMDS="$1; ${MVSMF_EXIT_CMDS}"
	# shellcheck disable=SC2064
	trap "${MVSMF_EXIT_CMDS}" EXIT
}

# Removes the directory mktemp made below, and nothing else: a path that does
# not have its shape -- empty, or a variable a suite happened to reuse -- is
# left alone. The trap gets the path itself, fixed when it is set.
mvsmf_conn_rmdir() {
	case "${1:-}" in
		/*/mvsmf-conn.??????) rm -rf -- "$1" ;;
	esac
}

MVSMF_CONN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/mvsmf-conn.XXXXXX") ||
	mvsmf_conn_die "cannot create a temporary directory."
chmod 700 "$MVSMF_CONN_DIR"
case "$MVSMF_CONN_DIR" in
	"${HOME:-/nonexistent}"/*)
		mvsmf_conn_rmdir "$MVSMF_CONN_DIR"
		mvsmf_conn_die "TMPDIR is inside the home directory, where Zowe would find a ~/zowe.config.json (see below)." ;;
esac
mvsmf_on_exit "mvsmf_conn_rmdir $(printf '%q' "$MVSMF_CONN_DIR")"

# --- curl -----------------------------------------------------------------
# printf is a shell builtin, so the token is never an argument of a process.
MVSMF_CURLRC="${MVSMF_CONN_DIR}/curlrc"
(umask 077; printf 'cookie = "LtpaToken2=%s"\n' "$MVSMF_TOKEN" > "$MVSMF_CURLRC")

MVSMF_CURLRC2=""
if [ -n "${MVSMF_USER2:-}" ] && [ -n "${MVSMF_TOKEN2:-}" ]; then
	MVSMF_CURLRC2="${MVSMF_CONN_DIR}/curlrc2"
	(umask 077; printf 'cookie = "LtpaToken2=%s"\n' "$MVSMF_TOKEN2" > "$MVSMF_CURLRC2")
fi

# --- Zowe CLI ---------------------------------------------------------------
# Zowe merges every zowe.config.json it finds: the one in ZOWE_CLI_HOME, and a
# project one in the working directory or ANY directory above it -- a
# ~/zowe.config.json is found from every checkout under the home directory. A
# layer that carries a user and password wins over the token, silently: the
# request goes out with Basic auth and asserts nothing about the token
# (measured 2026-10-11 against a local listener, the token both as an argument
# and as ZOWE_OPT_TOKEN_VALUE). So Zowe gets a home of its own and runs from it,
# outside the home directory, and sees no layer but this one.
#
# The token goes in the environment, never on the command line.
export ZOWE_CLI_HOME="${MVSMF_CONN_DIR}/zowe"
mkdir -p "$ZOWE_CLI_HOME"
printf '{"profiles":{"mvsmf":{"type":"zosmf","properties":{"host":"%s","port":%s,"protocol":"%s"}}},"defaults":{"zosmf":"mvsmf"},"autoStore":false}\n' \
	"$MVSMF_HOST" "$MVSMF_PORT" "$MVSMF_PROTOCOL" > "${ZOWE_CLI_HOME}/zowe.config.json"
export ZOWE_OPT_TOKEN_TYPE=LtpaToken2
export ZOWE_OPT_TOKEN_VALUE="$MVSMF_TOKEN"
unset ZOWE_OPT_USER ZOWE_OPT_PASSWORD ZOWE_OPT_BASE_PROFILE

# Every path a suite hands to zowe must be absolute: the call runs in
# ZOWE_CLI_HOME, not in the suite's working directory.
zowe() {
	(cd "$ZOWE_CLI_HOME" && command zowe "$@")
}

# Every connection option on every invocation (#204), credentials excepted.
# shellcheck disable=SC2034
ZOWE_CONN=(--host "$MVSMF_HOST" --port "$MVSMF_PORT"
	--protocol "$MVSMF_PROTOCOL" --reject-unauthorized false)

# 0 = development build, 1 = release. A request that returns no version at all
# is neither: the suite stops (exit 1) instead of reading a failure as "release".
mvsmf_dev_build() {   # INFO_URL, the /zosmf/info URL of the server under test
	local v
	v=$(curl -s -f -K "$MVSMF_CURLRC" -H 'X-CSRF-ZOSMF-HEADER: 1' \
		"$1" | jq -r '.zosmf_full_version // empty')
	if [[ -z "$v" ]]; then
		echo "ERROR: GET /zosmf/info returned no zosmf_full_version; cannot tell a development build from a release." >&2
		exit 1
	fi
	[[ "$v" == *-dev ]]
}
