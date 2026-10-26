#!/bin/sh
# Sessions of guide/ug-security.typ ("Setting Up Security").
#
#   MVSMF_URL=http://localhost:8080 \
#   MVSMF_USER=...  MVSMF_PASS=...  \
#   MVSMF_USER2=... MVSMF_PASS2=... \
#   MVSMF_USER3=... MVSMF_PASS3=... \
#   sh capture/security.sh [base|audit]
#
# Three user IDs are needed. The brief fixes only MVSMF_USER and MVSMF_PASS;
# the other two are an addition of this script:
#
#   MVSMF_USER   the user of the other chapters. May use mvsMF. Owns the test
#                job of the JESSPOOL sessions. Needs no special authority.
#   MVSMF_USER2  an ordinary user ID that may use mvsMF. Has no JESSPOOL
#                profile for MVSMF_USER and is no RAKF administrator. In the
#                phase "audit" it is connected to the group AUDIT.
#   MVSMF_USER3  a user ID that has a valid password but NO READ access to
#                FACILITY MVSMF.ACCESS.
#
# The script runs in two phases, because the RAKF profiles change in between.
# Run "base" first (the default), then set up the audit profiles, then "audit".
#
# Phase base. Needs, on the system under test:
#
#   - HTTPD with the route line
#       MOD=MVSMF /zosmf/*  AUTH=TOKEN RES=FACILITY:MVSMF.ACCESS
#     (after the two AUTH=NONE lines, see guide/ug-install.typ), and a RAKF
#     profile FACILITY MVSMF.ACCESS with UACC(NONE) and READ for a group that
#     contains MVSMF_USER and MVSMF_USER2 but not MVSMF_USER3.
#   - the DATASET profiles that ship with RAKF 2.0.0 (SYS1.SECURE.* with
#     UACC(NONE), generic * with UACC(READ)), and no other profile that gives
#     MVSMF_USER2 access to SYS1.SECURE.CNTL or to MVSMF_USER's data sets.
#   - NO JESSPOOL profile (or only the lines "*" NONE and "SYSTEM.*" NONE).
#   - JES2 running with a job class A. The JCL of the test job needs nothing
#     else.
#
# Phase audit. Needs, in addition and after the phase base:
#
#   - the profiles of the task "Let Auditors Read All Jobs":
#       RDEF * CL(JESSPOOL) UACC(NONE)
#       PE * CL(JESSPOOL) ID(AUDIT) ACCESS(READ)
#       RDEF SYSTEM.* CL(JESSPOOL) UACC(NONE)
#     reloaded with S RAKFPROF, and MVSMF_USER2 connected to the group AUDIT
#     (CONNECT, S RAKFUSER). MVSMF_USER2 must log in again after that. The
#     script does not do the set-up.
#   - the file ex/ug-security/j-submit.txt written by the phase base: the
#     phase audit takes the job ID from it. The job SECDEMO must still be in
#     the output queue.
#
# Side effects: the job SECDEMO of MVSMF_USER (jobs of an earlier run are
# purged first and at the end of the phase audit). The data set
# MVSMF_USER.SECDEMO.DENIED is created only if the system lets MVSMF_USER2
# create it; the session shows the refusal, and the script deletes the data
# set at the end in case it exists.
#
# The variable JOBID is set from the answer of j-submit and exported, so the
# commands of the following sessions show $JOBID, the way they show
# $MVSMF_URL. In the book the reader sets it by hand from the "jobid" of the
# submit answer.

. "$(dirname "$0")/lib.sh"

# jv FILE NAME  -> the first string value of "NAME" in a session file
jv() {
	sed -n 's/.*"'"$2"'" *: *"\([^"]*\)".*/\1/p' "$EXDIR/$1" | head -n 1
}

PHASE=${1:-base}

for v in MVSMF_URL MVSMF_USER MVSMF_PASS MVSMF_USER2 MVSMF_PASS2 \
	MVSMF_USER3 MVSMF_PASS3; do
	eval "val=\${$v:-}"
	if [ -z "$val" ]; then
		echo "security.sh: $v is not set" >&2
		exit 1
	fi
done
export MVSMF_URL MVSMF_USER MVSMF_PASS MVSMF_USER2 MVSMF_PASS2 \
	MVSMF_USER3 MVSMF_PASS3

# purge every SECDEMO job of MVSMF_USER (clean-up, not part of the story)
purge_demo() {
	hid 'for id in $(curl -s -u "$MVSMF_USER:$MVSMF_PASS" "$MVSMF_URL/zosmf/restjobs/jobs?owner=$MVSMF_USER&prefix=SECDEMO*" | grep -o "\"jobid\" *: *\"[A-Z0-9]*\"" | tr -d " " | cut -d\" -f4); do curl -s -X DELETE -u "$MVSMF_USER:$MVSMF_PASS" "$MVSMF_URL/zosmf/restjobs/jobs/SECDEMO/$id"; done'
}

case "$PHASE" in
base)

# ---- 1. a user without MVSMF.ACCESS ----------------------------------------

ses ug-security/s-refused-facility.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER3:$MVSMF_PASS3" \
  "$MVSMF_URL/zosmf/restjobs/jobs"
EOF
)"

# the two AUTH=NONE routes are not covered by the catch-all RES=
ses ug-security/s-info-open.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER3:$MVSMF_PASS3" \
  "$MVSMF_URL/zosmf/info"
EOF
)"

# ---- 2. data sets -----------------------------------------------------------

ses ug-security/d-refused-read.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER2:$MVSMF_PASS2" \
  "$MVSMF_URL/zosmf/restfiles/ds/SYS1.SECURE.CNTL(PROFILES)"
EOF
)"

hid 'curl -s -X DELETE -u "$MVSMF_USER:$MVSMF_PASS" "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.SECDEMO.DENIED"'

ses ug-security/d-refused-create.txt "$(cat <<'EOF'
curl -si -X POST -u "$MVSMF_USER2:$MVSMF_PASS2" \
  -H 'Content-Type: application/json' \
  -d '{"dsorg":"PS","recfm":"FB","lrecl":80,"blksize":3120,"primary":1,"alcunit":"TRK"}' \
  "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.SECDEMO.DENIED"
EOF
)"

# ---- 3. jobs: submit as MVSMF_USER, look as MVSMF_USER and MVSMF_USER2 -----

purge_demo

ses ug-security/j-submit.txt "$(cat <<'EOF'
curl -si -X PUT -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'Content-Type: text/plain' \
  --data-binary @- \
  "$MVSMF_URL/zosmf/restjobs/jobs" <<'JCL'
//SECDEMO  JOB (ACCT),'SECURITY',CLASS=A,MSGCLASS=H
//STEP1    EXEC PGM=IEFBR14
JCL
EOF
)"

JOBID=$(jv ug-security/j-submit.txt jobid)
export JOBID
if [ -z "$JOBID" ]; then
	echo "security.sh: no jobid in j-submit.txt" >&2
	exit 1
fi

# JES2 writes the owner during conversion; until then the job is nobody's and
# every status answers 404.  Wait for the first 200.
hid 'n=0; while [ $n -lt 30 ]; do c=$(curl -s -o /dev/null -w "%{http_code}" -u "$MVSMF_USER:$MVSMF_PASS" "$MVSMF_URL/zosmf/restjobs/jobs/SECDEMO/$JOBID"); [ "$c" = 200 ] && break; n=$((n+1)); sleep 2; done'

ses ug-security/j-list-own.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restjobs/jobs?owner=*&prefix=SECDEMO*"
EOF
)"

ses ug-security/j-list-user2.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER2:$MVSMF_PASS2" \
  "$MVSMF_URL/zosmf/restjobs/jobs?owner=*&prefix=SECDEMO*"
EOF
)"

ses ug-security/j-status-user2.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER2:$MVSMF_PASS2" \
  "$MVSMF_URL/zosmf/restjobs/jobs/SECDEMO/$JOBID"
EOF
)"
;;

audit)

JOBID=$(jv ug-security/j-submit.txt jobid)
export JOBID
if [ -z "$JOBID" ]; then
	echo "security.sh: no jobid in j-submit.txt; run the phase base first" >&2
	exit 1
fi

# MVSMF_USER2 is a member of AUDIT: the job of MVSMF_USER is listed (READ)
ses ug-security/j-list-audit.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER2:$MVSMF_PASS2" \
  "$MVSMF_URL/zosmf/restjobs/jobs?owner=*&prefix=SECDEMO*"
EOF
)"

# READ is not enough for a purge
ses ug-security/j-purge-read.txt "$(cat <<'EOF'
curl -si -X DELETE -u "$MVSMF_USER2:$MVSMF_PASS2" \
  "$MVSMF_URL/zosmf/restjobs/jobs/SECDEMO/$JOBID"
EOF
)"

purge_demo
hid 'curl -s -X DELETE -u "$MVSMF_USER:$MVSMF_PASS" "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.SECDEMO.DENIED"'
;;

*)
	echo "usage: security.sh [base|audit]" >&2
	exit 1
	;;
esac
