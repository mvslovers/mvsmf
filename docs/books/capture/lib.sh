# Helpers for the capture scripts of the mvsMF books.  A capture script
# records the sessions of one chapter against a running mvsMF; the book shows
# the files it writes under ex/.  Source this file from capture/<chapter>.sh.
#
# Environment (set by the caller, never written into a file of the book):
#   MVSMF_URL   base URL of mvsMF, for example http://localhost:8080
#   MVSMF_USER  a user ID that may use mvsMF
#   MVSMF_PASS  its password
#   EXDIR       the ex/ directory to write into (default: ../ex beside capture/)

EXDIR=${EXDIR:-$(cd "$(dirname "$0")/.." && pwd)/ex}

# ses FILE 'COMMAND'
# Runs COMMAND with bash and writes ex/FILE: a line "$ COMMAND" as the reader
# types it (variables unexpanded), then what the command printed, CR removed.
ses() {
	_f=$EXDIR/$1
	mkdir -p "$(dirname "$_f")"
	{
		printf '$ %s\n' "$2"
		bash -c "$2" 2>&1 | tr -d '\r'
	} > "$_f"
	echo "wrote $1" >&2
}

# hid 'COMMAND'
# Runs COMMAND for its effect (setup, clean-up); nothing is recorded.
hid() {
	bash -c "$1" > /dev/null 2>&1 || true
}
