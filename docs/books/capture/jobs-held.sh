#!/bin/sh
# Sessions of the section "A Purge That Is Only Requested" in
# guide/ug-jobs.typ.
#
#   MVSMF_URL=http://localhost:8080 MVSMF_USER=... MVSMF_PASS=... \
#       sh capture/jobs-held.sh
#
# Needs, on the system under test (a throwaway system: the script starts and
# cancels a punch device):
#
#   - mvsMF 1.4.0 or a build with mvsmf#426, and the console service open to
#     MVSMF_USER (the sessions issue $DU and $C through it);
#   - the punch PUNCH1 (unit 00D) with the class B, as in a stock MVS/CE, and
#     the forms STD1 on it.  The job asks for the forms ZMF1, so PUNCH1 selects
#     the output and halts for setup: it holds the output until the script
#     cancels the device;
#   - the class H held on the spool, as for capture/jobs.sh.
#
# The sessions use the variable HJOB, the job ID of MVSMFDM6.  The job is
# purged at the end if a session left it behind.  The job ID and the date
# differ from run to run.

. "$(dirname "$0")/lib.sh"

: "${MVSMF_URL:?}" "${MVSMF_USER:?}" "${MVSMF_PASS:?}"
export MVSMF_URL MVSMF_USER MVSMF_PASS

# cons 'COMMAND' -> the text the console answers, for the script's own use
cons() {
	curl -s -X PUT -u "$MVSMF_USER:$MVSMF_PASS" \
		-H 'Content-Type: application/json' \
		-d "{\"cmd\":\"$1\"}" \
		"$MVSMF_URL/zosmf/restconsoles/consoles/defcn"
}

# the device must be idle and started before the job comes
if cons '$DU,PUN1' | grep -q DRAINED; then
	hid "curl -s -X PUT -u \"\$MVSMF_USER:\$MVSMF_PASS\" -H 'Content-Type: application/json' -d '{\"cmd\":\"\$S PUNCH1\"}' \"\$MVSMF_URL/zosmf/restconsoles/consoles/defcn\""
	sleep 2
fi
if ! cons '$DU,PUN1' | grep -q 'INACTIVE'; then
	echo "PUNCH1 is not inactive; stop" >&2
	exit 1
fi

ses ug-jobs/j-held-submit.txt "$(cat <<'EOF'
curl -si -X PUT -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'Content-Type: text/plain' \
  --data-binary @- "$MVSMF_URL/zosmf/restjobs/jobs" <<'JCL'
//MVSMFDM6 JOB (ACCT),'MVSMF DEMO',CLASS=A,MSGCLASS=H
//STEP1    EXEC PGM=IEBGENER
//SYSPRINT DD SYSOUT=H
//SYSIN    DD DUMMY
//SYSUT1   DD *
A CARD FOR THE PUNCH
/*
//SYSUT2   DD SYSOUT=(B,,ZMF1)
JCL
EOF
)"

HJOB=$(sed -n 's/.*"jobid":"\([^"]*\)".*/\1/p' "$EXDIR/ug-jobs/j-held-submit.txt")
export HJOB
[ -n "$HJOB" ] || { echo "no job id" >&2; exit 1; }

# wait until the device holds the job
_i=0
while [ $_i -lt 30 ]; do
	cons '$DU,PUN1' | grep -q 'HALTED' && break
	sleep 2
	_i=$((_i + 1))
done

ses ug-jobs/j-held-device.txt "$(cat <<'EOF'
curl -s -X PUT -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'Content-Type: application/json' \
  -d '{"cmd":"$DU,PUN1"}' \
  "$MVSMF_URL/zosmf/restconsoles/consoles/defcn"
EOF
)"

ses ug-jobs/j-held-purge.txt "$(cat <<'EOF'
curl -si -X DELETE -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restjobs/jobs/MVSMFDM6/$HJOB"
EOF
)"

ses ug-jobs/j-held-status.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restjobs/jobs/MVSMFDM6/$HJOB"
EOF
)"

ses ug-jobs/j-held-release.txt "$(cat <<'EOF'
curl -s -X PUT -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'Content-Type: application/json' \
  -d '{"cmd":"$C PUNCH1"}' \
  "$MVSMF_URL/zosmf/restconsoles/consoles/defcn"
EOF
)"
sleep 4

ses ug-jobs/j-held-gone.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restjobs/jobs/MVSMFDM6/$HJOB"
EOF
)"

hid "curl -s -X DELETE -u \"\$MVSMF_USER:\$MVSMF_PASS\" \"\$MVSMF_URL/zosmf/restjobs/jobs/MVSMFDM6/$HJOB\""
