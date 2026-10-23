#!/bin/sh
# Sessions of guide/ug-console.typ ("Issuing Console Commands").
#
#   MVSMF_URL=http://localhost:8080 MVSMF_USER=... MVSMF_PASS=... sh capture/console.sh
#
# Needs, on the system under test:
#
#   - a user ID that mvsMF lets in. mvsMF makes no authorization check of its
#     own for the console services, so no RAKF profile is needed in the
#     default set-up. If the HTTPD configuration protects the console routes
#     (the coordinator's section of ug-security), this user ID must have the
#     access that section describes.
#   - FTPD installed as a started task named FTPD and RUNNING when the script
#     starts. The sessions c-late, c-start, c-arm and c-poll stop and start
#     it: P FTPD answers in two parts about two seconds apart (the reason
#     for the "late reply" task), and S FTPD ends with the message FTPD054I.
#     The script starts FTPD again at the end (and after c-poll).
#   - nothing else: no data sets, no UFS files, no side effects for other
#     chapters. The console name defcn is only a label in the returned URLs.
#
# The variables KEY and DKEY are set from the answers of c-async, c-late and
# c-arm and exported, so the commands of the following sessions show $KEY and
# $DKEY, the way they show $MVSMF_URL.  In the book the reader sets them by
# hand from the cmd-response-key / detection-key of the answer before.
#
# Output to expect in the answers: cmd-response-url / detection-url carry the
# Host header the client sent, that is the host and port of MVSMF_URL.  The
# coordinator decides how that is shown in the book.

. "$(dirname "$0")/lib.sh"

# jv FILE NAME  -> the first string value of "NAME" in a session file
jv() {
	sed -n 's/.*"'"$2"'" *: *"\([^"]*\)".*/\1/p' "$EXDIR/$1" | head -n 1
}

# ---- 1. issue a command and read its answer ------------------------------

ses ug-console/c-dt.txt "$(cat <<'EOF'
curl -si -X PUT -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'Content-Type: application/json' \
  -d '{"cmd":"D T"}' \
  "$MVSMF_URL/zosmf/restconsoles/consoles/defcn"
EOF
)"

# no Content-Type: curl -d sends application/x-www-form-urlencoded
ses ug-console/c-ct.txt "$(cat <<'EOF'
curl -si -X PUT -u "$MVSMF_USER:$MVSMF_PASS" \
  -d '{"cmd":"D T"}' \
  "$MVSMF_URL/zosmf/restconsoles/consoles/defcn"
EOF
)"

# ---- 2. async and collect --------------------------------------------------

ses ug-console/c-async.txt "$(cat <<'EOF'
curl -si -X PUT -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'Content-Type: application/json' \
  -d '{"cmd":"D T","async":"Y"}' \
  "$MVSMF_URL/zosmf/restconsoles/consoles/defcn"
EOF
)"
KEY=$(jv ug-console/c-async.txt cmd-response-key); export KEY

ses ug-console/c-collect.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restconsoles/consoles/defcn/solmsgs/$KEY"
EOF
)"

ses ug-console/c-collect2.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restconsoles/consoles/defcn/solmsgs/$KEY"
EOF
)"

# ---- 3. a reply that arrives late ----------------------------------------

ses ug-console/c-late.txt "$(cat <<'EOF'
curl -si -X PUT -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'Content-Type: application/json' \
  -d '{"cmd":"P FTPD"}' \
  "$MVSMF_URL/zosmf/restconsoles/consoles/defcn"
EOF
)"
KEY=$(jv ug-console/c-late.txt cmd-response-key); export KEY
sleep 4

ses ug-console/c-late-collect.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restconsoles/consoles/defcn/solmsgs/$KEY"
EOF
)"

# ---- 4. an unsolicited message: start FTPD and wait until it listens ------

ses ug-console/c-start.txt "$(cat <<'EOF'
curl -si -X PUT -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'Content-Type: application/json' \
  -d '{"cmd":"S FTPD","unsol-key":"FTPD054I","unsol-detect-sync":"Y"}' \
  "$MVSMF_URL/zosmf/restconsoles/consoles/defcn"
EOF
)"

# the asynchronous form: arm the detection with the stop of FTPD, ask later
ses ug-console/c-arm.txt "$(cat <<'EOF'
curl -si -X PUT -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'Content-Type: application/json' \
  -d '{"cmd":"P FTPD","unsol-key":"FTPD099I"}' \
  "$MVSMF_URL/zosmf/restconsoles/consoles/defcn"
EOF
)"
DKEY=$(jv ug-console/c-arm.txt detection-key); export DKEY
sleep 8

ses ug-console/c-poll.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restconsoles/consoles/defcn/detections/$DKEY"
EOF
)"

# put FTPD back (not part of the story)
hid 'curl -s -X PUT -u "$MVSMF_USER:$MVSMF_PASS" -H "Content-Type: application/json" -d "{\"cmd\":\"S FTPD\",\"unsol-key\":\"FTPD054I\",\"unsol-detect-sync\":\"Y\"}" "$MVSMF_URL/zosmf/restconsoles/consoles/defcn"'

# ---- 5. the log ----------------------------------------------------------

ses ug-console/c-log.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restconsoles/v1/log?timeRange=30s"
EOF
)"

ses ug-console/c-log-bad.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restconsoles/v1/log?timeRange=0m"
EOF
)"
