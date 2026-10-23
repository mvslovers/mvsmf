#!/bin/sh
# RAKF batch jobs of guide/ug-security.typ ("Setting Up Security").
#
#   MVSMF_URL=http://localhost:8080 MVSMF_ADMIN=... MVSMF_ADMIN_PASS=... \
#       sh capture/rakf.sh STEP
#
# STEP is one of: access adduser connect protect audit ops admin pair clean
#
# Needs, on the system under test:
#
#   - MVSMF_ADMIN: a user ID in the group RAKFADM, with the SPECIAL attribute
#     and the right to change SYS1.SECURE.* (the IBMUSER of MVS/CE).
#   - the procedures RAKFPROF and RAKFUSER in the system procedure library.
#   - the group MVSMFUSR, the users SMITH and JONES (connected to MVSMFUSR)
#     and the user BROWN of the security phase, created before.
#
# Every step submits one batch job as MVSMF_ADMIN, waits until the job is on
# the output queue and records two sessions: the output of the TSO step
# (NAME-out.txt) and the job log (NAME-log.txt). The profile steps record in
# addition the lines of PROFILES the job wrote (NAME-prof.txt). The steps are
# meant to run in the order of the list above; "clean" removes the JESSPOOL
# profiles and the data set profile again.

. "$(dirname "$0")/lib.sh"

for v in MVSMF_URL MVSMF_ADMIN MVSMF_ADMIN_PASS; do
	eval "val=\${$v:-}"
	if [ -z "$val" ]; then
		echo "rakf.sh: $v is not set" >&2
		exit 1
	fi
done
export MVSMF_URL MVSMF_ADMIN MVSMF_ADMIN_PASS

# ddid JOBNAME JOBID DDNAME -> the id of the output file DDNAME
ddid() {
	curl -s -u "$MVSMF_ADMIN:$MVSMF_ADMIN_PASS" "$MVSMF_URL/zosmf/restjobs/jobs/$1/$2/files" |
		sed 's/},{/}\
{/g' | sed -n 's/.*"ddname":"'"$3"'","id":\([0-9]*\).*/\1/p' | head -n 1
}

# rakfjob NAME BASE  (JCL on standard input)
# Submits, waits, records BASE-out.txt and BASE-log.txt.
rakfjob() {
	_name=$1
	_base=$2
	cat > "${TMPDIR:-/tmp}/rakfjob.$$"
	_r=$(curl -s -u "$MVSMF_ADMIN:$MVSMF_ADMIN_PASS" -X PUT \
		-H 'Content-Type: text/plain' \
		--data-binary @"${TMPDIR:-/tmp}/rakfjob.$$" "$MVSMF_URL/zosmf/restjobs/jobs")
	rm -f "${TMPDIR:-/tmp}/rakfjob.$$"
	JOBID=$(echo "$_r" | sed -n 's/.*"jobid" *: *"\([^"]*\)".*/\1/p')
	if [ -z "$JOBID" ]; then
		echo "rakf.sh: no job id: $_r" >&2
		exit 1
	fi
	export JOBID
	_n=0
	while [ $_n -lt 60 ]; do
		_s=$(curl -s -u "$MVSMF_ADMIN:$MVSMF_ADMIN_PASS" "$MVSMF_URL/zosmf/restjobs/jobs/$_name/$JOBID" |
			sed -n 's/.*"status" *: *"\([^"]*\)".*/\1/p')
		[ "$_s" = OUTPUT ] && break
		_n=$((_n + 1))
		sleep 2
	done
	_id=$(ddid "$_name" "$JOBID" SYSTSPRT)
	ses ug-security/$_base-out.txt \
		"curl -s -u \"\$MVSMF_ADMIN:\$MVSMF_ADMIN_PASS\" \"\$MVSMF_URL/zosmf/restjobs/jobs/$_name/\$JOBID/files/$_id/records\""
	ses ug-security/$_base-log.txt \
		"curl -s -u \"\$MVSMF_ADMIN:\$MVSMF_ADMIN_PASS\" \"\$MVSMF_URL/zosmf/restjobs/jobs/$_name/\$JOBID/files/2/records\""
}

# profiles BASE PATTERN -> the lines of PROFILES that match PATTERN
profiles() {
	ses ug-security/$1-prof.txt \
		"curl -s -u \"\$MVSMF_ADMIN:\$MVSMF_ADMIN_PASS\" \"\$MVSMF_URL/zosmf/restfiles/ds/SYS1.SECURE.CNTL(PROFILES)\" | grep '$2'"
}

STEP=${1:-}

case "$STEP" in
access)
	rakfjob MVSMFACC r-access <<'JCL'
//MVSMFACC JOB (ACCT),'MVSMF ACCESS',CLASS=A,MSGCLASS=H,GROUP=RAKFADM
//TSO      EXEC PGM=IKJEFT01,REGION=4096K
//SYSPRINT DD SYSOUT=*
//SYSTSPRT DD SYSOUT=*
//SYSTSIN  DD *
RDEF MVSMF.ACCESS CL(FACILITY) UACC(NONE)
PE MVSMF.ACCESS CL(FACILITY) ID(MVSMFUSR) ACCESS(READ)
/*
//RAKFPROF EXEC RAKFPROF
JCL
	profiles r-access '^FACILITYMVSMF'
	;;

adduser)
	rakfjob ADDUSER r-adduser <<'JCL'
//ADDUSER  JOB (ACCT),'ADDUSER',CLASS=A,MSGCLASS=H,GROUP=RAKFADM
//TSO      EXEC PGM=IKJEFT01,REGION=4096K
//SYSPRINT DD SYSOUT=*
//SYSTERM  DD SYSOUT=*
//SYSIN    DD DUMMY
//SYSTSPRT DD SYSOUT=*
//SYSTSIN  DD *
 ADDUSER ADAMS PASSWORD(START123) DFLTGRP(USER) GROUP(MVSMFUSR)
/*
//RAKFUSER EXEC RAKFUSER
JCL
	ses ug-security/r-adduser-users.txt \
		"curl -s -u \"\$MVSMF_ADMIN:\$MVSMF_ADMIN_PASS\" \"\$MVSMF_URL/zosmf/restfiles/ds/SYS1.SECURE.CNTL(USERS)\" | grep '^ADAMS'"
	;;

connect)
	rakfjob CONNECT r-connect <<'JCL'
//CONNECT  JOB (ACCT),'CONNECT',CLASS=A,MSGCLASS=H,GROUP=RAKFADM
//TSO      EXEC PGM=IKJEFT01,REGION=4096K
//SYSPRINT DD SYSOUT=*
//SYSTERM  DD SYSOUT=*
//SYSIN    DD DUMMY
//SYSTSPRT DD SYSOUT=*
//SYSTSIN  DD *
CONNECT JONES GROUP(AUDIT)
/*
//RAKFUSER EXEC RAKFUSER
JCL
	ses ug-security/r-connect-users.txt \
		"curl -s -u \"\$MVSMF_ADMIN:\$MVSMF_ADMIN_PASS\" \"\$MVSMF_URL/zosmf/restfiles/ds/SYS1.SECURE.CNTL(USERS)\" | grep '^JONES'"
	;;

protect)
	rakfjob PROTECT r-protect <<'JCL'
//PROTECT  JOB (ACCT),'PROTECT',CLASS=A,MSGCLASS=H,GROUP=RAKFADM
//TSO      EXEC PGM=IKJEFT01,REGION=4096K
//SYSPRINT DD SYSOUT=*
//SYSTSPRT DD SYSOUT=*
//SYSTSIN  DD *
ADDSD PAYROLL.* UACC(READ)
PE PAYROLL.* CLASS(DATASET) ID(PAYGRP) ACCESS(UPDATE)
/*
//RAKFPROF EXEC RAKFPROF
JCL
	profiles r-protect '^DATASET PAYROLL'
	;;

audit)
	rakfjob JPAUDIT r-audit <<'JCL'
//JPAUDIT  JOB (ACCT),'JESSPOOL AUDIT',CLASS=A,MSGCLASS=H,GROUP=RAKFADM
//TSO      EXEC PGM=IKJEFT01,REGION=4096K
//SYSPRINT DD SYSOUT=*
//SYSTSPRT DD SYSOUT=*
//SYSTSIN  DD *
RDEF * CL(JESSPOOL) UACC(NONE)
PE * CL(JESSPOOL) ID(AUDIT) ACCESS(READ)
RDEF SYSTEM.* CL(JESSPOOL) UACC(NONE)
/*
//RAKFPROF EXEC RAKFPROF
JCL
	profiles r-audit '^JESSPOOL'
	;;

ops)
	rakfjob JPOPS r-ops <<'JCL'
//JPOPS    JOB (ACCT),'JESSPOOL OPS',CLASS=A,MSGCLASS=H,GROUP=RAKFADM
//TSO      EXEC PGM=IKJEFT01,REGION=4096K
//SYSPRINT DD SYSOUT=*
//SYSTSPRT DD SYSOUT=*
//SYSTSIN  DD *
RDEF * CL(JESSPOOL) UACC(READ)
PE * CL(JESSPOOL) ID(OPS) ACCESS(UPDATE)
RDEF SYSTEM.* CL(JESSPOOL) UACC(NONE)
/*
//RAKFPROF EXEC RAKFPROF
JCL
	profiles r-ops '^JESSPOOL'
	;;

admin)
	rakfjob JPADMIN r-admin <<'JCL'
//JPADMIN  JOB (ACCT),'JESSPOOL ADMIN',CLASS=A,MSGCLASS=H,GROUP=RAKFADM
//TSO      EXEC PGM=IKJEFT01,REGION=4096K
//SYSPRINT DD SYSOUT=*
//SYSTSPRT DD SYSOUT=*
//SYSTSIN  DD *
RDEF * CL(JESSPOOL) UACC(NONE)
PE * CL(JESSPOOL) ID(ADMIN) ACCESS(UPDATE)
/*
//RAKFPROF EXEC RAKFPROF
JCL
	profiles r-admin '^JESSPOOL'
	;;

pair)
	rakfjob JPPAIR r-pair <<'JCL'
//JPPAIR   JOB (ACCT),'JESSPOOL PAIR',CLASS=A,MSGCLASS=H,GROUP=RAKFADM
//TSO      EXEC PGM=IKJEFT01,REGION=4096K
//SYSPRINT DD SYSOUT=*
//SYSTSPRT DD SYSOUT=*
//SYSTSIN  DD *
RDEF * CL(JESSPOOL) UACC(NONE)
PE * CL(JESSPOOL) ID(ADMIN) ACCESS(UPDATE)
RDEF MIKE1.* CL(JESSPOOL) UACC(NONE)
PE MIKE1.* CL(JESSPOOL) ID(ADMIN) ACCESS(UPDATE)
PE MIKE1.* CL(JESSPOOL) ID(MIKE2) ACCESS(UPDATE)
RDEF MIKE2.* CL(JESSPOOL) UACC(NONE)
PE MIKE2.* CL(JESSPOOL) ID(ADMIN) ACCESS(UPDATE)
PE MIKE2.* CL(JESSPOOL) ID(MIKE1) ACCESS(UPDATE)
/*
//RAKFPROF EXEC RAKFPROF
JCL
	profiles r-pair '^JESSPOOL'
	;;

clean)
	hid_clean=$(cat <<'JCL'
//RAKFCLN  JOB (ACCT),'CLEAN',CLASS=A,MSGCLASS=H,GROUP=RAKFADM
//TSO      EXEC PGM=IKJEFT01,REGION=4096K
//SYSPRINT DD SYSOUT=*
//SYSTSPRT DD SYSOUT=*
//SYSTSIN  DD *
RDELETE * CLASS(JESSPOOL)
RDELETE SYSTEM.* CLASS(JESSPOOL)
RDELETE MIKE1.* CLASS(JESSPOOL)
RDELETE MIKE2.* CLASS(JESSPOOL)
/*
//RAKFPROF EXEC RAKFPROF
JCL
)
	curl -s -u "$MVSMF_ADMIN:$MVSMF_ADMIN_PASS" -X PUT -H 'Content-Type: text/plain' \
		--data-binary "$hid_clean" "$MVSMF_URL/zosmf/restjobs/jobs" > /dev/null
	;;

*)
	echo "usage: rakf.sh access|adduser|connect|protect|audit|ops|admin|pair|clean" >&2
	exit 1
	;;
esac
