#!/bin/sh
# Sessions of guide/ug-install.typ ("Installing mvsMF").
#
#   MVSMF_URL=http://localhost:8080 MVSMF_USER=... MVSMF_PASS=... sh capture/install.sh
#
# Only the checks that a running mvsMF can answer are recorded. The SMP jobs
# of the chapter (allocation, install, LIST, TSO LISTDS) need a system that
# takes the released package; they are not captured here and stand in the
# chapter as prose, marked "COORDINATOR: capture needed".
#
# Needs, on the system under test:
#
#   - mvsMF running behind HTTPD with the three route lines of the chapter
#     (member MVSMFPRM of MVSMF.SAMPLIB).
#   - a user ID MVSMF_USER that may use mvsMF (the sessions use Basic
#     authentication and no session token).
#   - nothing from other chapters, and nothing is written.
#
# The output of i-version carries the version and the build of the module on
# the system under test; the chapter shows the shape, not the value.

. "$(dirname "$0")/lib.sh"

# ---- 1. what a request without a credential gets ---------------------------

ses ug-install/i-noauth.txt 'curl -si "$MVSMF_URL/zosmf/info"'

# ---- 2. the check of the installation ---------------------------------------

ses ug-install/i-info.txt 'curl -si -u "$MVSMF_USER:$MVSMF_PASS" "$MVSMF_URL/zosmf/info"'

# ---- 3. the build that runs -------------------------------------------------

ses ug-install/i-version.txt 'curl -s -u "$MVSMF_USER:$MVSMF_PASS" "$MVSMF_URL/zosmf/test?fn=version"'
