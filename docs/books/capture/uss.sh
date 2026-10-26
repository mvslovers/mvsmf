#!/bin/sh
# Sessions of guide/ug-uss.typ ("Working with Files in UFS").
#
#   MVSMF_URL=http://HOST:PORT MVSMF_USER=... MVSMF_PASS=... sh capture/uss.sh
#
# Needs, on the system under test:
#
#   - UFSD running, and HTTPD started with UFS enabled (the default). Without
#     it every request of this chapter answers 503.
#   - a UFSD file system, mounted read-write, that the user ID MVSMF_USER may
#     write to, at /tmp. That is the scratch mount of the UFSD sample
#     configuration: MODE(RW) and no OWNER(). With an OWNER() on /tmp the
#     writes of a user other than the owner fail, and so do the sessions.
#     To use another mount, replace /tmp in this file (and in the chapter)
#     by its path.
#   - nothing under /tmp/mvsmf-demo: the script deletes that directory
#     (recursively) first and creates it again. Nothing else is touched.
#   - a block size of 4096 bytes on that file system, and at least 5 MB of
#     free space on it. The session u-toolarge writes the largest file the
#     file system holds (4,259,840 bytes at 4096) and u-big-size reads its
#     size; with another block size the number differs (the chapter and the
#     reference give the formula).
#   - nothing from other chapters: no data sets, no jobs, no RAKF profile.
#     The sessions use Basic authentication and no session token.
#
# The variable ETAG is set from the answer of u-etag-get and exported, so the
# commands of u-etag-put and u-etag-stale show $ETAG, the way they show
# $MVSMF_URL. In the book the reader sets it by hand from the ETag header of
# the answer before.
#
# The sessions run in this order and depend on each other: the file hello.txt
# is written, listed, read, replaced under If-Match and deleted. Run the
# script as a whole.
#
# The output of u-trap-as037 and u-stored-037 is hexadecimal (od), because
# the bytes of a wrong translation are not valid UTF-8 and must not reach a
# file of the book.

. "$(dirname "$0")/lib.sh"

# etagof FILE -> the value of the ETag header in a session file
etagof() {
	sed -n 's/^ETag: *\([0-9A-Fa-f]*\).*/\1/p' "$EXDIR/$1" | head -n 1
}

# ---- 0. clean up what an earlier run left ---------------------------------

hid 'curl -s -X DELETE -u "$MVSMF_USER:$MVSMF_PASS" -H "X-IBM-Option: recursive" "$MVSMF_URL/zosmf/restfiles/fs/tmp/mvsmf-demo"'

# ---- 1. make a directory and a file ---------------------------------------

ses ug-uss/u-mkdir.txt "$(cat <<'EOF'
curl -si -X POST -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'Content-Type: application/json' \
  -d '{"type":"directory","mode":"rwxr-xr-x"}' \
  "$MVSMF_URL/zosmf/restfiles/fs/tmp/mvsmf-demo"
EOF
)"

ses ug-uss/u-mksub.txt "$(cat <<'EOF'
curl -si -X POST -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'Content-Type: application/json' \
  -d '{"type":"directory","mode":"rwxr-x---"}' \
  "$MVSMF_URL/zosmf/restfiles/fs/tmp/mvsmf-demo/notes"
EOF
)"

ses ug-uss/u-mkfile.txt "$(cat <<'EOF'
curl -si -X POST -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'Content-Type: application/json' \
  -d '{"type":"file"}' \
  "$MVSMF_URL/zosmf/restfiles/fs/tmp/mvsmf-demo/empty.txt"
EOF
)"

# ---- 2. write a file ------------------------------------------------------

ses ug-uss/u-write.txt "$(cat <<'EOF'
printf 'Hello from mvsMF\nSecond line\n' | curl -si -X PUT \
  -u "$MVSMF_USER:$MVSMF_PASS" --data-binary @- \
  "$MVSMF_URL/zosmf/restfiles/fs/tmp/mvsmf-demo/hello.txt"
EOF
)"

# ---- 3. list a directory --------------------------------------------------

ses ug-uss/u-list.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restfiles/fs?path=/tmp/mvsmf-demo"
EOF
)"

ses ug-uss/u-list-file.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restfiles/fs?path=/tmp/mvsmf-demo/hello.txt"
EOF
)"

ses ug-uss/u-list-max.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'X-IBM-Max-Items: 1' \
  "$MVSMF_URL/zosmf/restfiles/fs?path=/tmp/mvsmf-demo"
EOF
)"

# ---- 4. read a file -------------------------------------------------------

ses ug-uss/u-read.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restfiles/fs/tmp/mvsmf-demo/hello.txt"
EOF
)"

# ---- 5. IBM-1047 and IBM-037 ----------------------------------------------

ses ug-uss/u-trap-put.txt "$(cat <<'EOF'
printf 'a[1] = b[2] ^ c\n' | curl -si -X PUT \
  -u "$MVSMF_USER:$MVSMF_PASS" --data-binary @- \
  "$MVSMF_URL/zosmf/restfiles/fs/tmp/mvsmf-demo/code.txt"
EOF
)"

ses ug-uss/u-trap-stored.txt "$(cat <<'EOF'
curl -s -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'X-IBM-Data-Type: binary' \
  "$MVSMF_URL/zosmf/restfiles/fs/tmp/mvsmf-demo/code.txt" | od -An -tx1
EOF
)"

ses ug-uss/u-trap-as037.txt "$(cat <<'EOF'
curl -s -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'X-IBM-Data-Type: text;fileEncoding=IBM-037' \
  "$MVSMF_URL/zosmf/restfiles/fs/tmp/mvsmf-demo/code.txt" | od -An -tx1
EOF
)"

ses ug-uss/u-put-037.txt "$(cat <<'EOF'
printf 'a[1] = b[2] ^ c\n' | curl -si -X PUT \
  -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'X-IBM-Data-Type: text;fileEncoding=IBM-037' --data-binary @- \
  "$MVSMF_URL/zosmf/restfiles/fs/tmp/mvsmf-demo/code037.txt"
EOF
)"

ses ug-uss/u-read-037.txt "$(cat <<'EOF'
curl -s -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'X-IBM-Data-Type: text;fileEncoding=IBM-037' \
  "$MVSMF_URL/zosmf/restfiles/fs/tmp/mvsmf-demo/code037.txt"
EOF
)"

ses ug-uss/u-stored-037.txt "$(cat <<'EOF'
curl -s -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'X-IBM-Data-Type: binary' \
  "$MVSMF_URL/zosmf/restfiles/fs/tmp/mvsmf-demo/code037.txt" | od -An -tx1
EOF
)"

# ---- 6. replace a file only if it is unchanged ----------------------------

ses ug-uss/u-etag-get.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'X-IBM-Return-Etag: true' \
  "$MVSMF_URL/zosmf/restfiles/fs/tmp/mvsmf-demo/hello.txt"
EOF
)"
ETAG=$(etagof ug-uss/u-etag-get.txt); export ETAG

ses ug-uss/u-etag-put.txt "$(cat <<'EOF'
printf 'Changed text\n' | curl -si -X PUT \
  -u "$MVSMF_USER:$MVSMF_PASS" \
  -H "If-Match: $ETAG" --data-binary @- \
  "$MVSMF_URL/zosmf/restfiles/fs/tmp/mvsmf-demo/hello.txt"
EOF
)"

# the file has changed now: the same command, the old ETAG
ses ug-uss/u-etag-stale.txt "$(cat <<'EOF'
printf 'Changed text\n' | curl -si -X PUT \
  -u "$MVSMF_USER:$MVSMF_PASS" \
  -H "If-Match: $ETAG" --data-binary @- \
  "$MVSMF_URL/zosmf/restfiles/fs/tmp/mvsmf-demo/hello.txt"
EOF
)"

# ---- 7. errors ------------------------------------------------------------

ses ug-uss/u-notfound.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restfiles/fs/tmp/mvsmf-demo/nofile.txt"
EOF
)"

ses ug-uss/u-exists.txt "$(cat <<'EOF'
curl -si -X POST -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'Content-Type: application/json' \
  -d '{"type":"directory"}' \
  "$MVSMF_URL/zosmf/restfiles/fs/tmp/mvsmf-demo"
EOF
)"

ses ug-uss/u-toolarge.txt "$(cat <<'EOF'
head -c 5000000 /dev/zero | tr '\0' 'x' | curl -si -X PUT \
  -u "$MVSMF_USER:$MVSMF_PASS" -H 'Expect:' --data-binary @- \
  "$MVSMF_URL/zosmf/restfiles/fs/tmp/mvsmf-demo/big.txt"
EOF
)"

ses ug-uss/u-big-size.txt "$(cat <<'EOF'
curl -s -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restfiles/fs?path=/tmp/mvsmf-demo/big.txt"
EOF
)"

# ---- 8. delete ------------------------------------------------------------

ses ug-uss/u-delete.txt "$(cat <<'EOF'
curl -si -X DELETE -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restfiles/fs/tmp/mvsmf-demo/hello.txt"
EOF
)"

ses ug-uss/u-delete-busy.txt "$(cat <<'EOF'
curl -si -X DELETE -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restfiles/fs/tmp/mvsmf-demo"
EOF
)"

ses ug-uss/u-delete-dir.txt "$(cat <<'EOF'
curl -si -X DELETE -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'X-IBM-Option: recursive' \
  "$MVSMF_URL/zosmf/restfiles/fs/tmp/mvsmf-demo"
EOF
)"
