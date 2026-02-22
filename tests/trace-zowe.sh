#!/bin/bash
# =========================================================================
# mvsMF HTTP Trace Proxy
#
# Bidirectional TCP proxy that captures all HTTP requests and responses
# between a client (Zowe CLI, curl, etc.) and the mvsMF server.
#
# Modes:
#   --proxy              Start proxy in interactive mode (Ctrl+C to stop)
#   --proxy "command"    Start proxy, run command, show trace, stop
#
# The proxy rewrites the Zowe CLI config to route through localhost,
# so Zowe commands work transparently. For curl or other tools, point
# them at localhost:<proxy-port> manually.
#
# Usage:
#   ./tests/trace-zowe.sh --proxy
#   ./tests/trace-zowe.sh --proxy "zowe files upload ftds file.txt 'DS(MBR)'"
#   ./tests/trace-zowe.sh --proxy "curl -s -u USER:PASS http://localhost:1081/zosmf/restfiles/ds/MY.DS"
#
# Environment:
#   PROXY_PORT    Override proxy listen port (default: MVS_PORT + 1)
#
# All traces are written to a temp directory and displayed on exit.
# =========================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/.config"
CONFIG_FILE="${CONFIG_DIR}/zowe.config.json"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# =========================================================================
# Preflight checks
# =========================================================================

if [ ! -f "$CONFIG_FILE" ]; then
	echo "ERROR: ${CONFIG_FILE} not found."
	echo "Copy zowe.config.json.example to zowe.config.json and fill in your values."
	exit 1
fi

if ! command -v jq &>/dev/null; then
	echo "ERROR: jq not found. Install with: brew install jq"
	exit 1
fi

if ! command -v python3 &>/dev/null; then
	echo "ERROR: python3 not found."
	exit 1
fi

# Load connection details
MVS_HOST=$(jq -r '.profiles.mvsmf.properties.host' "$CONFIG_FILE")
MVS_PORT=$(jq -r '.profiles.mvsmf.properties.port' "$CONFIG_FILE")

# =========================================================================
# Helpers
# =========================================================================

header() {
	echo ""
	echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
	echo -e "${BOLD} $1${NC}"
	echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}"
}

subheader() {
	echo ""
	echo -e "${CYAN}--- $1 ---${NC}"
}

# =========================================================================
# Embedded Python TCP proxy
#
# Handles keep-alive connections and multiple sequential requests.
# Logs both directions: client→server (REQUEST), server→client (RESPONSE).
# =========================================================================

create_proxy_script() {
	local script_path="$1"
	cat > "$script_path" << 'PYEOF'
import socket
import sys
import os
import threading
import signal

listen_port = int(sys.argv[1])
remote_host = sys.argv[2]
remote_port = int(sys.argv[3])
log_dir = sys.argv[4]
# Timeout: 0 = wait forever (interactive), >0 = exit after N seconds idle
idle_timeout = int(sys.argv[5]) if len(sys.argv) > 5 else 0

req_log = os.path.join(log_dir, "requests.log")
resp_log = os.path.join(log_dir, "responses.log")
full_log = os.path.join(log_dir, "full_trace.log")

request_num = 0
lock = threading.Lock()
running = True

def shutdown(signum=None, frame=None):
    global running
    running = False

signal.signal(signal.SIGTERM, shutdown)
signal.signal(signal.SIGINT, shutdown)

def log_full(direction, data):
    with lock:
        with open(full_log, "a") as f:
            f.write("\n" + "=" * 70 + "\n")
            f.write("[%s] %d bytes\n" % (direction, len(data)))
            f.write("=" * 70 + "\n")
            try:
                text = data.decode("utf-8", errors="replace")
                f.write(text)
            except:
                f.write(data.hex())
            f.write("\n")

def log_request(data):
    global request_num
    with lock:
        request_num += 1
        num = request_num
    with open(req_log, "a") as f:
        f.write("\n" + "=" * 70 + "\n")
        f.write("REQUEST #%d (%d bytes)\n" % (num, len(data)))
        f.write("=" * 70 + "\n")
        try:
            text = data.decode("utf-8", errors="replace")
            f.write(text)
        except:
            f.write(data.hex())
        f.write("\n")
    # Print to stdout for immediate visibility
    try:
        text = data.decode("utf-8", errors="replace")
        lines = text.split("\r\n")
        sys.stdout.write("\033[1;33m>>> REQUEST #%d\033[0m\n" % num)
        for line in lines:
            if line == "":
                sys.stdout.write("\n")
                break
            sys.stdout.write("  %s\n" % line)
        sys.stdout.flush()
    except:
        pass

def log_response(data):
    with open(resp_log, "a") as f:
        f.write("\n" + "=" * 70 + "\n")
        f.write("RESPONSE (%d bytes)\n" % len(data))
        f.write("=" * 70 + "\n")
        try:
            text = data.decode("utf-8", errors="replace")
            f.write(text)
        except:
            f.write(data.hex())
        f.write("\n")
    try:
        text = data.decode("utf-8", errors="replace")
        first_line = text.split("\r\n")[0]
        sys.stdout.write("\033[1;36m<<< %s\033[0m\n" % first_line)
        sys.stdout.flush()
    except:
        pass

def forward(src, dst, direction):
    try:
        while running:
            data = src.recv(65536)
            if not data:
                break
            if direction == "REQUEST":
                log_request(data)
                log_full("CLIENT >>> SERVER", data)
            else:
                log_response(data)
                log_full("SERVER >>> CLIENT", data)
            dst.sendall(data)
    except (ConnectionResetError, BrokenPipeError, OSError):
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except:
            pass

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.settimeout(idle_timeout if idle_timeout > 0 else None)
server.bind(("127.0.0.1", listen_port))
server.listen(5)

sys.stdout.write("Proxy listening on 127.0.0.1:%d -> %s:%d\n" % (listen_port, remote_host, remote_port))
sys.stdout.flush()

# Signal readiness
ready_file = os.path.join(log_dir, "proxy.ready")
with open(ready_file, "w") as f:
    f.write(str(os.getpid()))

try:
    while running:
        try:
            client, addr = server.accept()
        except socket.timeout:
            break
        except OSError:
            break

        try:
            remote = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            remote.connect((remote_host, remote_port))
        except Exception as e:
            sys.stderr.write("Cannot connect to %s:%d: %s\n" % (remote_host, remote_port, e))
            client.close()
            continue

        t1 = threading.Thread(target=forward, args=(client, remote, "REQUEST"), daemon=True)
        t2 = threading.Thread(target=forward, args=(remote, client, "RESPONSE"), daemon=True)
        t1.start()
        t2.start()
        t1.join()
        t2.join()
        client.close()
        remote.close()
except KeyboardInterrupt:
    pass
finally:
    server.close()
PYEOF
}

# =========================================================================
# Show trace results from log directory
# =========================================================================

show_trace() {
	local log_dir="$1"

	header "Full Request/Response Trace"

	if [ -s "${log_dir}/requests.log" ]; then
		echo -e "${YELLOW}=== REQUESTS ===${NC}"
		cat "${log_dir}/requests.log"
	else
		echo -e "${RED}No requests captured.${NC}"
	fi

	echo ""

	if [ -s "${log_dir}/responses.log" ]; then
		echo -e "${CYAN}=== RESPONSES ===${NC}"
		cat "${log_dir}/responses.log"
	else
		echo -e "${RED}No responses captured.${NC}"
	fi

	header "Log Files"
	echo "Requests:   ${log_dir}/requests.log"
	echo "Responses:  ${log_dir}/responses.log"
	echo "Full trace: ${log_dir}/full_trace.log"
}

# =========================================================================
# Start proxy, optionally run a command, show trace
# =========================================================================

mode_proxy() {
	local user_cmd="${1:-}"
	local PROXY_PORT="${PROXY_PORT:-$((MVS_PORT + 1))}"

	if [ -n "$user_cmd" ]; then
		header "Trace Proxy — Command Mode"
	else
		header "Trace Proxy — Interactive Mode"
	fi

	TMPDIR=$(mktemp -d)
	PROXY_SCRIPT="${TMPDIR}/proxy.py"
	LOG_DIR="${TMPDIR}/trace"
	mkdir -p "$LOG_DIR"

	echo "MVS target:  ${MVS_HOST}:${MVS_PORT}"
	echo "Proxy:       localhost:${PROXY_PORT}"
	echo "Log dir:     ${LOG_DIR}"

	# Create proxy script
	create_proxy_script "$PROXY_SCRIPT"

	# Create a Zowe config pointing to our proxy
	PROXY_CONFIG_DIR="${TMPDIR}/config"
	mkdir -p "${PROXY_CONFIG_DIR}"
	jq ".profiles.mvsmf.properties.host = \"localhost\" | .profiles.mvsmf.properties.port = ${PROXY_PORT}" \
		"$CONFIG_FILE" > "${PROXY_CONFIG_DIR}/zowe.config.json"
	cp "${CONFIG_DIR}/zowe.schema.json" "${PROXY_CONFIG_DIR}/" 2>/dev/null || true

	# Start proxy
	# In command mode: 60s idle timeout. In interactive mode: wait forever.
	local timeout_arg=0
	if [ -n "$user_cmd" ]; then
		timeout_arg=60
	fi

	subheader "Starting TCP proxy"
	python3 "$PROXY_SCRIPT" "$PROXY_PORT" "$MVS_HOST" "$MVS_PORT" "$LOG_DIR" "$timeout_arg" &
	PROXY_PID=$!

	# Wait for ready
	for i in $(seq 1 20); do
		if [ -f "${LOG_DIR}/proxy.ready" ]; then
			break
		fi
		sleep 0.25
	done

	if ! kill -0 "$PROXY_PID" 2>/dev/null; then
		echo -e "${RED}Proxy failed to start. Port ${PROXY_PORT} may be in use.${NC}"
		exit 1
	fi

	# Export ZOWE_CLI_HOME so Zowe commands route through the proxy
	export ZOWE_CLI_HOME="$PROXY_CONFIG_DIR"

	if [ -n "$user_cmd" ]; then
		# --- Command mode: run the command, show trace, exit ---
		subheader "Running command"
		echo -e "${YELLOW}$ ${user_cmd}${NC}"
		echo ""

		eval "$user_cmd" 2>&1 || true

		# Let proxy finish logging
		sleep 2
		kill "$PROXY_PID" 2>/dev/null
		wait "$PROXY_PID" 2>/dev/null

		show_trace "$LOG_DIR"
	else
		# --- Interactive mode: show instructions, wait for Ctrl+C ---
		echo ""
		echo -e "${GREEN}Proxy is running. Zowe CLI is configured to use it.${NC}"
		echo ""
		echo "  For Zowe commands, use this shell (ZOWE_CLI_HOME is set)."
		echo "  For curl, point to:  http://localhost:${PROXY_PORT}"
		echo ""
		echo "  Requests and responses are traced in real time."
		echo "  Press Ctrl+C to stop and show the full trace."
		echo ""

		# Wait for proxy to exit (via Ctrl+C → SIGTERM)
		trap "kill $PROXY_PID 2>/dev/null; wait $PROXY_PID 2>/dev/null" INT TERM
		wait "$PROXY_PID" 2>/dev/null

		show_trace "$LOG_DIR"
	fi
}

# =========================================================================
# Main
# =========================================================================

usage() {
	echo "Usage: $0 --proxy [COMMAND]"
	echo ""
	echo "Start a tracing HTTP proxy between the client and mvsMF."
	echo ""
	echo "Modes:"
	echo "  --proxy              Interactive — proxy runs until Ctrl+C"
	echo "  --proxy \"COMMAND\"    Run COMMAND through proxy, show trace, exit"
	echo ""
	echo "Environment:"
	echo "  PROXY_PORT           Override proxy listen port (default: MVS_PORT + 1)"
	echo ""
	echo "Examples:"
	echo "  $0 --proxy"
	echo "  $0 --proxy \"zowe files list ds 'HLQ.DSN'\""
	echo "  $0 --proxy \"zowe files upload ftds file.txt 'HLQ.PDS(MBR)'\""
	echo "  $0 --proxy \"curl -s -u U:P http://localhost:1081/zosmf/restfiles/ds/MY.DS\""
}

case "${1:---help}" in
	--proxy)
		mode_proxy "${2:-}"
		;;
	--help|-h)
		usage
		;;
	*)
		echo "Unknown option: $1"
		usage
		exit 1
		;;
esac
