# shellcheck shell=bash
# =========================================================================
# tests/lib/ispfstats.sh -- a PDS with ISPF statistics in its directory (#573)
#
# Sourced by the suites that test X-IBM-Attributes: base on the member list,
# after tests/lib/conn.sh. Needs SCRIPT_DIR, BASE_URL and MVSMF_CURLRC.
#
#   ispf_fixture DSN   creates DSN through tests/jcl/ispfstats.jcl and waits
#                      for the job. Returns 0 only when it ended CC 0000; the
#                      reason is in ISPF_FIXTURE_WHY otherwise.
#
# The members and what their directory entries hold are listed in that JCL.
# =========================================================================

ISPF_FIXTURE_WHY=""

ispf_fixture() {
	local dsn="$1" jcl job rc="" i

	curl -s -o /dev/null -X DELETE -K "$MVSMF_CURLRC" \
		"${BASE_URL}/zosmf/restfiles/ds/${dsn}" 2>/dev/null || true

	jcl=$(sed "s/@DSN@/${dsn}/" "${SCRIPT_DIR}/jcl/ispfstats.jcl")
	job=$(curl -s -X PUT -K "$MVSMF_CURLRC" -H "Content-Type: text/plain" \
		--data-binary "$jcl" "${BASE_URL}/zosmf/restjobs/jobs" |
		jq -r '.jobid // empty')
	if [ -z "$job" ]; then
		ISPF_FIXTURE_WHY="the job was not accepted"
		return 1
	fi

	for i in $(seq 1 60); do
		rc=$(curl -s -K "$MVSMF_CURLRC" \
			"${BASE_URL}/zosmf/restjobs/jobs/ISPFSTAT/${job}" |
			jq -r 'select(.status == "OUTPUT") | .retcode // empty')
		[ -n "$rc" ] && break
		sleep 1
	done

	if [ "$rc" != "CC 0000" ]; then
		ISPF_FIXTURE_WHY="job ${job} ended '${rc:-not at all}'"
		return 1
	fi
	return 0
}
