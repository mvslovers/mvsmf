#!/bin/sh
# Sessions of guide/ug-jobs.typ ("Submitting Jobs and Reading Their Output").
#
#   MVSMF_URL=http://localhost:8080 MVSMF_USER=... MVSMF_PASS=... \
#       sh capture/jobs.sh
#
#   MVSMF_URL=... MVSMF_USER=... MVSMF_PASS=... \
#       MVSMF_USER2=... MVSMF_PASS2=... sh capture/jobs.sh none
#   (the same with "read" and with "update" in place of "none")
#
# Without an argument the script records the sessions of one user (the ones
# of the tasks "submit", "find", "check", "read" and "purge").  With the
# argument none, read or update it records the four sessions of the task "see
# the jobs of others", for one state of the JESSPOOL profiles; run it three
# times, after the profiles have been set as described below.
#
# The script does not change any RAKF profile and does not read any.  It
# writes no file outside ex/.
#
# Needs, on the system under test:
#
#   - JES2 running, with a held output class H: the jobs of the sessions say
#     MSGCLASS=H and SYSOUT=H and the sessions read their output after the
#     jobs have ended.  The class A must run batch jobs.
#   - MVSMF_USER: a user ID that mvsMF lets in and that owns its jobs.  The
#     user ID has a password: mvsMF puts it on the job card of every job it
#     submits.  A session logged on with a token alone has none (the sessions
#     use Basic authentication).
#   - the program IEBGENER and the program IEFBR14, as on any MVS 3.8j system.
#   - one data set, created by the script and deleted by it at the start of
#     the next run:  <MVSMF_USER>.MVSMF.DEMOJCL(JOB2)  (a PDS of one
#     track, RECFM FB LRECL 80).  The script creates it with the data set
#     services of mvsMF (ug-data); it needs the right to create data sets
#     under its own high-level qualifier.
#   - the jobs MVSMFDM1 to MVSMFDM5 of MVSMF_USER.  At the start, the script
#     purges every job of MVSMF_USER whose name starts with MVSMFDM, so a
#     second run starts clean.  The jobs the sessions leave behind in the
#     checkpoint are purged by the same step at the next run.
#   - no side effect on other chapters.  The job ids differ from run to run.
#
# The sessions use the variables JOBID (the job id of MVSMFDM1), DDID (the
# id of the output file SYSUT2) and, in the stage runs, VJOBID (the job id of
# MVSMFDM5).  They are set from the answers of earlier sessions and exported,
# so the commands of the following sessions show $JOBID and $DDID the way they
# show $MVSMF_URL.  In the book the reader sets them by hand from the answer
# before.
#
# The session j-read-all leaves out the file JESJCL on purpose: the JOB card
# mvsMF adds carries the password of MVSMF_USER, and the book must not show
# it.  Search every captured file for the password before it goes into the
# book.
#
# The stage runs (none, read, update) need a second user ID, MVSMF_USER2
# with MVSMF_PASS2, that is not MVSMF_USER and owns no job named MVSMFDM*.
# Before a stage run the profiles of the class JESSPOOL are set as follows
# (the entity of a job is <owner>.<jobname>.<jobid>, the entities below are
# written for MVSMF_USER as owner; "Setting Up Security" in the User's Guide
# describes how a profile is written in RAKF):
#
#   none    MVSMF_USER2 has no access to any profile that covers
#           <MVSMF_USER>.MVSMFDM5.<jobid>, <MVSMF_USER>.. and ..
#           (no profile at all is the same).
#   read    MVSMF_USER2 has READ on <MVSMF_USER>.MVSMFDM5.<jobid> and on the
#           probes <MVSMF_USER>.. and .. ; no UPDATE on any of them.
#   update  MVSMF_USER2 has UPDATE on <MVSMF_USER>.MVSMFDM5.<jobid> and READ
#           on the probes <MVSMF_USER>.. and .. .
#
# Every stage run submits a fresh job MVSMFDM5 as MVSMF_USER (hidden), waits
# until it is on the output queue, records the four sessions as MVSMF_USER2
# and purges the job again as MVSMF_USER.  In the update stage the purge
# session itself removes the job.
#
# Output to expect in the answers: the "url" and "files-url" fields carry the
# Host header the client sent, that is the host and port of MVSMF_URL.  The
# coordinator decides how that is shown in the book.

. "$(dirname "$0")/lib.sh"

STAGE=${1:-main}

export MVSMF_URL MVSMF_USER MVSMF_PASS MVSMF_USER2 MVSMF_PASS2

# jv FILE NAME  -> the first string value of "NAME" in a session file
jv() {
	sed -n 's/.*"'"$2"'" *: *"\([^"]*\)".*/\1/p' "$EXDIR/$1" | head -n 1
}

# dsid FILE DDNAME  -> the id of the output file DDNAME in a file list
dsid() {
	sed 's/},{/}\
{/g' "$EXDIR/$1" |
		sed -n 's/.*"ddname":"'"$2"'","id":\([0-9]*\).*/\1/p' | head -n 1
}

# waitout JOBNAME JOBID USER PASS -> wait until the job is on the output queue
waitout() {
	_i=0
	while [ "$_i" -lt 45 ]; do
		_s=$(curl -s -u "$3:$4" \
			"$MVSMF_URL/zosmf/restjobs/jobs/$1/$2" |
			sed -n 's/.*"status":"\([^"]*\)".*/\1/p')
		[ "$_s" = OUTPUT ] && return 0
		sleep 2
		_i=$((_i + 1))
	done
	echo "job $1 $2 did not reach the output queue" >&2
	return 1
}

# submit_hid JCLFILE -> submit the file as MVSMF_USER, print the job id
submit_hid() {
	curl -s -X PUT -u "$MVSMF_USER:$MVSMF_PASS" \
		-H 'Content-Type: text/plain' --data-binary @"$1" \
		"$MVSMF_URL/zosmf/restjobs/jobs" |
		sed -n 's/.*"jobid":"\([^"]*\)".*/\1/p'
}

# purge_demo -> purge every job of MVSMF_USER named MVSMFDM*
purge_demo() {
	curl -s -u "$MVSMF_USER:$MVSMF_PASS" \
		"$MVSMF_URL/zosmf/restjobs/jobs?prefix=MVSMFDM*" |
		sed 's/},{/}\
{/g' |
		sed -n 's/.*"jobname":"\([^"]*\)","jobid":"\([^"]*\)".*/\1 \2/p' |
		while read _n _j; do
			curl -s -X DELETE -u "$MVSMF_USER:$MVSMF_PASS" \
				"$MVSMF_URL/zosmf/restjobs/jobs/$_n/$_j" > /dev/null
		done
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/jobs.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# The stage runs: "see the jobs of others"
# ---------------------------------------------------------------------------
case "$STAGE" in
main) ;;
none | read | update)
	if [ -z "$MVSMF_USER2" ] || [ -z "$MVSMF_PASS2" ]; then
		echo "the stage runs need MVSMF_USER2 and MVSMF_PASS2" >&2
		exit 1
	fi

	purge_demo
	cat > "$TMP/dm5.jcl" <<'EOF'
//MVSMFDM5 JOB (ACCT),'MVSMF DEMO 5',CLASS=A,MSGCLASS=H
//STEP1    EXEC PGM=IEFBR14
//SYSPRINT DD SYSOUT=H
EOF
	VJOBID=$(submit_hid "$TMP/dm5.jcl")
	export VJOBID
	waitout MVSMFDM5 "$VJOBID" "$MVSMF_USER" "$MVSMF_PASS" || exit 1

	# the jobs of another user, by owner
	ses "ug-jobs/j-oth-$STAGE-list.txt" "$(cat <<'EOF'
curl -s -u "$MVSMF_USER2:$MVSMF_PASS2" \
  "$MVSMF_URL/zosmf/restjobs/jobs?owner=$MVSMF_USER&prefix=MVSMFDM*"
EOF
	)"

	# owner=*
	ses "ug-jobs/j-oth-$STAGE-star.txt" "$(cat <<'EOF'
curl -s -u "$MVSMF_USER2:$MVSMF_PASS2" \
  "$MVSMF_URL/zosmf/restjobs/jobs?owner=*&prefix=MVSMFDM*"
EOF
	)"

	# the spool files of a job of another user
	ses "ug-jobs/j-oth-$STAGE-files.txt" "$(cat <<'EOF'
curl -si -u "$MVSMF_USER2:$MVSMF_PASS2" \
  "$MVSMF_URL/zosmf/restjobs/jobs/MVSMFDM5/$VJOBID/files"
EOF
	)"

	# the purge
	ses "ug-jobs/j-oth-$STAGE-purge.txt" "$(cat <<'EOF'
curl -si -X DELETE -u "$MVSMF_USER2:$MVSMF_PASS2" \
  "$MVSMF_URL/zosmf/restjobs/jobs/MVSMFDM5/$VJOBID"
EOF
	)"

	purge_demo
	exit 0
	;;
*)
	echo "usage: sh capture/jobs.sh [none|read|update]" >&2
	exit 1
	;;
esac

# ---------------------------------------------------------------------------
# Set-up (not recorded): a clean start
# ---------------------------------------------------------------------------
purge_demo

hid 'curl -s -X DELETE -u "$MVSMF_USER:$MVSMF_PASS" "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.MVSMF.DEMOJCL"'
hid 'curl -s -X POST -u "$MVSMF_USER:$MVSMF_PASS" -H "Content-Type: application/json" -d "{\"dsorg\":\"PO\",\"alcunit\":\"TRK\",\"primary\":1,\"secondary\":1,\"dirblk\":5,\"recfm\":\"FB\",\"blksize\":800,\"lrecl\":80}" "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.MVSMF.DEMOJCL"'

cat > "$TMP/job2.jcl" <<'EOF'
//MVSMFDM2 JOB (ACCT),'MVSMF DEMO 2',CLASS=A,MSGCLASS=H,
//         NOTIFY=&SYSUID
//STEP1    EXEC PGM=IEFBR14
//SYSPRINT DD SYSOUT=H
EOF
hid "curl -s -X PUT -u \"\$MVSMF_USER:\$MVSMF_PASS\" -H 'Content-Type: text/plain' --data-binary @$TMP/job2.jcl \"\$MVSMF_URL/zosmf/restfiles/ds/\$MVSMF_USER.MVSMF.DEMOJCL(JOB2)\""

cat > "$TMP/job3.jcl" <<'EOF'
//MVSMFDM3 JOB (ACCT),'MVSMF DEMO 3',CLASS=A,MSGCLASS=H
//STEP1    EXEC PGM=NOSUCHPG
EOF
cat > "$TMP/job4.jcl" <<'EOF'
//MVSMFDM4 JOB (ACCT),'MVSMF DEMO 4',CLASS=A,MSGCLASS=H
//STEP1    EXECC PGM=IEFBR14
EOF

# ---------------------------------------------------------------------------
# 1. submit a job
# ---------------------------------------------------------------------------

# inline JCL, the body is the JCL
ses ug-jobs/j-submit.txt "$(cat <<'EOF'
curl -si -X PUT -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'Content-Type: text/plain' \
  --data-binary @- "$MVSMF_URL/zosmf/restjobs/jobs" <<'JCL'
//MVSMFDM1 JOB (ACCT),'MVSMF DEMO',CLASS=A,MSGCLASS=H
//STEP1    EXEC PGM=IEBGENER
//SYSPRINT DD SYSOUT=H
//SYSUT1   DD *
HELLO FROM A JOB THAT MVSMF SUBMITTED
SECOND LINE OF THE INPUT
THIRD LINE OF THE INPUT
/*
//SYSUT2   DD SYSOUT=H
//SYSIN    DD DUMMY
JCL
EOF
)"
JOBID=$(jv ug-jobs/j-submit.txt jobid)
export JOBID

# a data set as the source of the JCL
ses ug-jobs/j-submit-ds.txt "$(cat <<'EOF'
curl -si -X PUT -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'Content-Type: application/json' \
  -d @- "$MVSMF_URL/zosmf/restjobs/jobs" <<JSON
{"file":"//'$MVSMF_USER.MVSMF.DEMOJCL(JOB2)'"}
JSON
EOF
)"

# a request that is no job: no JOB card
ses ug-jobs/j-submit-nocard.txt "$(cat <<'EOF'
curl -si -X PUT -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'Content-Type: text/plain' \
  --data-binary '//STEP1    EXEC PGM=IEFBR14' \
  "$MVSMF_URL/zosmf/restjobs/jobs"
EOF
)"

waitout MVSMFDM1 "$JOBID" "$MVSMF_USER" "$MVSMF_PASS"

# ---------------------------------------------------------------------------
# 2. find a job
# ---------------------------------------------------------------------------

ses ug-jobs/j-list.txt "$(cat <<'EOF'
curl -s -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restjobs/jobs?prefix=MVSMFDM*"
EOF
)"

ses ug-jobs/j-list-filter.txt "$(cat <<'EOF'
curl -s -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restjobs/jobs?prefix=MVSMFDM*&status=OUTPUT&max-jobs=1"
EOF
)"

ses ug-jobs/j-list-id.txt "$(cat <<'EOF'
curl -s -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restjobs/jobs?jobid=$JOBID"
EOF
)"

# ---------------------------------------------------------------------------
# 3. status and return code
# ---------------------------------------------------------------------------

ses ug-jobs/j-status.txt "$(cat <<'EOF'
curl -s -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restjobs/jobs/MVSMFDM1/$JOBID"
EOF
)"

ses ug-jobs/j-status-exec.txt "$(cat <<'EOF'
curl -s -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restjobs/jobs/MVSMFDM1/$JOBID?exec-data=Y"
EOF
)"

# an abend and a JCL error (submitted out of sight, then asked for)
AJOBID=$(submit_hid "$TMP/job3.jcl")
JEJOBID=$(submit_hid "$TMP/job4.jcl")
export AJOBID JEJOBID
waitout MVSMFDM3 "$AJOBID" "$MVSMF_USER" "$MVSMF_PASS"
waitout MVSMFDM4 "$JEJOBID" "$MVSMF_USER" "$MVSMF_PASS"

ses ug-jobs/j-rc-abend.txt "$(cat <<'EOF'
curl -s -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restjobs/jobs/MVSMFDM3/$AJOBID"
EOF
)"

ses ug-jobs/j-rc-jclerr.txt "$(cat <<'EOF'
curl -s -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restjobs/jobs/MVSMFDM4/$JEJOBID"
EOF
)"

ses ug-jobs/j-status-none.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restjobs/jobs/MVSMFDM1/JOB00000"
EOF
)"

# ---------------------------------------------------------------------------
# 4. read the output
# ---------------------------------------------------------------------------

ses ug-jobs/j-files.txt "$(cat <<'EOF'
curl -s -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restjobs/jobs/MVSMFDM1/$JOBID/files"
EOF
)"
DDID=$(dsid ug-jobs/j-files.txt SYSUT2)
export DDID

ses ug-jobs/j-read.txt "$(cat <<'EOF'
curl -s -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restjobs/jobs/MVSMFDM1/$JOBID/files/$DDID/records"
EOF
)"

ses ug-jobs/j-read-all.txt "$(cat <<'EOF'
curl -s -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restjobs/jobs/MVSMFDM1/$JOBID/files" |
  grep -o '"ddname":"[A-Z0-9$#@]*","id":[0-9]*' |
  grep -v JESJCL | sed 's/.*"id"://' |
  while read id; do
    echo "=== file $id"
    curl -s -u "$MVSMF_USER:$MVSMF_PASS" \
      "$MVSMF_URL/zosmf/restjobs/jobs/MVSMFDM1/$JOBID/files/$id/records"
  done
EOF
)"

# a header for a record range is not evaluated: the whole file comes back
ses ug-jobs/j-range-header.txt "$(cat <<'EOF'
curl -s -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'X-IBM-Record-Range: 1-1' \
  "$MVSMF_URL/zosmf/restjobs/jobs/MVSMFDM1/$JOBID/files/$DDID/records"
EOF
)"

# the records 2 and 3, cut on the client
ses ug-jobs/j-range.txt "$(cat <<'EOF'
curl -s -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restjobs/jobs/MVSMFDM1/$JOBID/files/$DDID/records" |
  sed -n '2,3p'
EOF
)"

ses ug-jobs/j-read-bad.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restjobs/jobs/MVSMFDM1/$JOBID/files/999/records"
EOF
)"

# ---------------------------------------------------------------------------
# 5. cancel (not offered) and purge
# ---------------------------------------------------------------------------

ses ug-jobs/j-cancel.txt "$(cat <<'EOF'
curl -si -X PUT -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'Content-Type: application/json' \
  -d '{"request":"cancel","version":"2.0"}' \
  "$MVSMF_URL/zosmf/restjobs/jobs/MVSMFDM1/$JOBID"
EOF
)"

ses ug-jobs/j-purge.txt "$(cat <<'EOF'
curl -si -X DELETE -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restjobs/jobs/MVSMFDM1/$JOBID"
EOF
)"

ses ug-jobs/j-purge-again.txt "$(cat <<'EOF'
curl -si -X DELETE -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restjobs/jobs/MVSMFDM1/$JOBID"
EOF
)"

# clean up what the sessions left
purge_demo
hid 'curl -s -X DELETE -u "$MVSMF_USER:$MVSMF_PASS" "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.MVSMF.DEMOJCL"'
