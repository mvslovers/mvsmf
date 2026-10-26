#!/bin/sh
# Session of the section "A Read That Fails Part-Way" in guide/ug-uss.typ.
#
#   MVSMF_URL=http://localhost:8080 MVSMF_USER=... MVSMF_PASS=... \
#       sh capture/uss-readfail.sh
#
# Needs, on the system under test (a throwaway system: the script stops and
# starts UFSD):
#
#   - mvsMF 1.4.0 or a build with mvsmf#423, and UFSD as the started task UFSD;
#   - the console service open to MVSMF_USER (the script issues P UFSD and
#     S UFSD through it);
#   - python3 on the machine that runs the script.
#
# The script writes a file of 880,000 bytes, starts a download that
# reads slowly (a receive buffer of 4 KB, 2 KB every half second), and stops
# UFSD five seconds in.  mvsMF has read ahead of the client by then, so it
# meets the stopped UFSD while it is still sending.  The script waits for the
# connection to close, starts UFSD again, records the message and deletes the
# file.  The time of the message differs from run to run.

. "$(dirname "$0")/lib.sh"

: "${MVSMF_URL:?}" "${MVSMF_USER:?}" "${MVSMF_PASS:?}"
export MVSMF_URL MVSMF_USER MVSMF_PASS

TMPF=$(mktemp)
trap 'rm -f "$TMPF"' EXIT

awk 'BEGIN { for (i = 1; i <= 11000; i++) printf "%-79s\n", sprintf("record %05d of the read failure file, filled with dots ", i) "......................." }' > "$TMPF"

hid "curl -s -X PUT -u \"\$MVSMF_USER:\$MVSMF_PASS\" -H 'X-CSRF-ZOSMF-HEADER: x' -H 'Content-Type: text/plain' --data-binary @$TMPF \"\$MVSMF_URL/zosmf/restfiles/fs/tmp/mvsmf-demo/readfail.txt\""

python3 - <<'PY'
import base64, os, socket, sys, time, urllib.parse, urllib.request

url = os.environ["MVSMF_URL"]
u = urllib.parse.urlparse(url)
auth = base64.b64encode(
    ("%s:%s" % (os.environ["MVSMF_USER"], os.environ["MVSMF_PASS"])).encode()
).decode()

def console(cmd):
    req = urllib.request.Request(
        url + "/zosmf/restconsoles/consoles/defcn",
        data=('{"cmd":"%s"}' % cmd).encode(), method="PUT",
        headers={"Authorization": "Basic " + auth,
                 "Content-Type": "application/json",
                 "X-CSRF-ZOSMF-HEADER": "x"})
    return urllib.request.urlopen(req).read().decode()

s = socket.create_connection((u.hostname, u.port or 80))
s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
s.sendall(("GET /zosmf/restfiles/fs/tmp/mvsmf-demo/readfail.txt HTTP/1.1\r\n"
           "Host: capture\r\nAuthorization: Basic %s\r\n\r\n" % auth).encode())
t0 = time.time()
stopped = False
tail = b""
while True:
    d = s.recv(2048)
    if not d:
        break
    tail = (tail + d)[-16:]
    time.sleep(0.5)
    if not stopped and time.time() - t0 > 5:
        console("P UFSD")
        stopped = True
if tail.endswith(b"0\r\n\r\n"):
    sys.exit("the response ended with its last chunk: nothing was cut off")
if not stopped:
    sys.exit("the download ended before UFSD was stopped")
PY
rc=$?

hid "curl -s -X PUT -u \"\$MVSMF_USER:\$MVSMF_PASS\" -H 'X-CSRF-ZOSMF-HEADER: x' -H 'Content-Type: application/json' -d '{\"cmd\":\"S UFSD\"}' \"\$MVSMF_URL/zosmf/restconsoles/consoles/defcn\""
n=0
until curl -s -u "$MVSMF_USER:$MVSMF_PASS" "$MVSMF_URL/zosmf/restconsoles/v1/log?timeRange=2m" | grep -q 'UFSD001I'; do
	n=$((n + 1))
	[ $n -gt 40 ] && { echo "UFSD did not come back" >&2; exit 1; }
	sleep 3
done
[ $rc -eq 0 ] || exit $rc

ses ug-uss/u-readfail-log.txt "$(cat <<'EOF'
curl -s -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restconsoles/v1/log?timeRange=10m" \
  | grep -o 'MVSMF301E[^"]*' | tail -1
EOF
)"

hid "curl -s -X DELETE -u \"\$MVSMF_USER:\$MVSMF_PASS\" -H 'X-CSRF-ZOSMF-HEADER: x' \"\$MVSMF_URL/zosmf/restfiles/fs/tmp/mvsmf-demo/readfail.txt\""
