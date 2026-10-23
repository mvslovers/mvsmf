#!/bin/sh
# Sessions of guide/ug-data.typ ("Working with Data Sets").
#
#   MVSMF_URL=http://localhost:8080 MVSMF_USER=... MVSMF_PASS=... sh capture/data.sh
#
# Needs, on the system under test:
#
#   - a user ID that mvsMF lets in and that may allocate, read, write and
#     delete data sets whose high-level qualifier is its own user ID. The
#     sessions create these three data sets, and delete them again at the
#     start and at the end, so the script can run twice:
#         $MVSMF_USER.DEMO.SEQ   sequential, FB, LRECL 80, BLKSIZE 3120
#         $MVSMF_USER.DEMO.PDS   partitioned, FB, LRECL 80, BLKSIZE 3120,
#                                5 directory blocks
#         $MVSMF_USER.DEMO.BIN   sequential, FB, LRECL 80, BLKSIZE 3120
#     Nothing else under $MVSMF_USER.DEMO is expected. d-list-ds and
#     d-list-ds-page list the level $MVSMF_USER.DEMO and show these three, in
#     the order BIN, PDS, SEQ. If the user ID owns other data sets with the
#     qualifier DEMO, the listings show them too.
#   - a volume with room for a few tracks. No special device is needed. The
#     change in the estimate for a 3380 (#439) is explained in the text and
#     has no session of its own.
#   - for d-denied-put and d-denied-del: an ordinary user ID WITHOUT UPDATE
#     and ALTER access to the name SYS1.MVSMF.NOSUCH. Set LOW_USER and
#     LOW_PASS for it. Without them the two sessions run as MVSMF_USER; a
#     privileged user then gets the 404 answers that the text describes as the
#     answer of a permitted user. The name does not exist and is never
#     created, so the sessions write nothing. In a default RAKF set-up the
#     SYS1.* data sets are expected to be refused for an ordinary user; that
#     is not verified here.
#   - nothing from the other chapters. No UFS files, no jobs, no console.
#
# The variable ETAG is set from the answers of d-etag-get and d-etag-put and
# exported, so the commands of the following sessions show $ETAG the way they
# show $MVSMF_URL. In the book the reader copies the value of the ETag header
# of the answer before.

. "$(dirname "$0")/lib.sh"

# hv FILE  -> the value of the first ETag header in a session file
hv() {
	sed -n 's/^[Ee][Tt][Aa][Gg]: *//p' "$EXDIR/$1" | head -n 1 | tr -d '\r\n'
}

# ---- 0. clean up what an earlier run left ---------------------------------

for n in SEQ PDS BIN; do
	hid 'curl -s -o /dev/null -u "$MVSMF_USER:$MVSMF_PASS" -X DELETE "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.DEMO.'$n'"'
done

# ---- 1. create a data set and a PDS ----------------------------------------

ses ug-data/d-create-seq.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" -X POST \
  -H 'Content-Type: application/json' \
  -d '{"dsorg":"PS","recfm":"FB","lrecl":80,"blksize":3120,"alcunit":"TRK","primary":1,"secondary":1}' \
  "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.DEMO.SEQ"
EOF
)"

ses ug-data/d-create-pds.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" -X POST \
  -H 'Content-Type: application/json' \
  -d '{"dsorg":"PO","recfm":"FB","lrecl":80,"blksize":3120,"alcunit":"TRK","primary":1,"secondary":1,"dirblk":5}' \
  "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.DEMO.PDS"
EOF
)"

# one required field missing: lrecl, blksize and primary are absent
ses ug-data/d-create-bad.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" -X POST \
  -H 'Content-Type: application/json' \
  -d '{"dsorg":"PS","recfm":"FB"}' \
  "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.DEMO.BAD"
EOF
)"

# the third data set, not part of the story: the binary sessions use it
hid 'curl -s -o /dev/null -u "$MVSMF_USER:$MVSMF_PASS" -X POST -H "Content-Type: application/json" -d "{\"dsorg\":\"PS\",\"recfm\":\"FB\",\"lrecl\":80,\"blksize\":3120,\"alcunit\":\"TRK\",\"primary\":1,\"secondary\":1}" "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.DEMO.BIN"'

# ---- 2. write a sequential data set and a member, read them back ----------

ses ug-data/d-put-seq.txt "$(cat <<'EOF'
printf 'HELLO FROM CURL\nSECOND LINE\n' | curl -si -u "$MVSMF_USER:$MVSMF_PASS" -X PUT \
  -H 'Content-Type: text/plain' --data-binary @- \
  "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.DEMO.SEQ"
EOF
)"

ses ug-data/d-get-seq.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.DEMO.SEQ"
EOF
)"

ses ug-data/d-put-mbr.txt "$(cat <<'EOF'
printf 'MEMBER HELLO\nSECOND LINE\n' | curl -si -u "$MVSMF_USER:$MVSMF_PASS" -X PUT \
  -H 'Content-Type: text/plain' --data-binary @- \
  "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.DEMO.PDS(HELLO)"
EOF
)"

# two more members, for the listings
for m in HOLA ZETA; do
	hid 'printf "MEMBER '$m'\n" | curl -s -o /dev/null -u "$MVSMF_USER:$MVSMF_PASS" -X PUT -H "Content-Type: text/plain" --data-binary @- "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.DEMO.PDS('$m')"'
done

ses ug-data/d-get-mbr.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.DEMO.PDS(HELLO)"
EOF
)"

# ---- 3. list data sets and members -----------------------------------------

ses ug-data/d-list-ds.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restfiles/ds?dslevel=$MVSMF_USER.DEMO"
EOF
)"

ses ug-data/d-list-ds-page.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'X-IBM-Max-Items: 1' \
  "$MVSMF_URL/zosmf/restfiles/ds?dslevel=$MVSMF_USER.DEMO"
EOF
)"

ses ug-data/d-list-ds-next.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'X-IBM-Max-Items: 1' \
  "$MVSMF_URL/zosmf/restfiles/ds?dslevel=$MVSMF_USER.DEMO&start=$MVSMF_USER.DEMO.PDS"
EOF
)"

ses ug-data/d-list-mbr.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.DEMO.PDS/member"
EOF
)"

ses ug-data/d-list-mbr-page.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'X-IBM-Max-Items: 1' \
  "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.DEMO.PDS/member?pattern=H*"
EOF
)"

ses ug-data/d-list-mbr-next.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'X-IBM-Max-Items: 1' \
  "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.DEMO.PDS/member?pattern=H*&start=HOLA"
EOF
)"

# ---- 4. binary and text, the two codepages ---------------------------------

ses ug-data/d-put-bin.txt "$(cat <<'EOF'
printf 'ABC\000\001\377' | curl -si -u "$MVSMF_USER:$MVSMF_PASS" -X PUT \
  -H 'Content-Type: application/octet-stream' \
  -H 'X-IBM-Data-Type: binary' --data-binary @- \
  "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.DEMO.BIN"
EOF
)"

ses ug-data/d-get-bin.txt "$(cat <<'EOF'
curl -s -u "$MVSMF_USER:$MVSMF_PASS" -H 'X-IBM-Data-Type: binary' \
  "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.DEMO.BIN" | od -An -tx1 | head -n 2
EOF
)"

ses ug-data/d-enc-put.txt "$(cat <<'EOF'
printf 'A[B]^\n' | curl -si -u "$MVSMF_USER:$MVSMF_PASS" -X PUT \
  -H 'Content-Type: text/plain' --data-binary @- \
  "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.DEMO.SEQ"
EOF
)"

ses ug-data/d-enc-get.txt "$(cat <<'EOF'
curl -s -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.DEMO.SEQ"
EOF
)"

ses ug-data/d-enc-get1047.txt "$(cat <<'EOF'
curl -s -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'X-IBM-Data-Type: text;fileEncoding=IBM-1047' \
  "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.DEMO.SEQ"
EOF
)"

ses ug-data/d-enc-bad.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'X-IBM-Data-Type: text;fileEncoding=IBM-273' \
  "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.DEMO.SEQ"
EOF
)"

# ---- 5. safe update with an ETag -------------------------------------------

ses ug-data/d-etag-get.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" \
  -H 'X-IBM-Return-Etag: true' \
  "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.DEMO.SEQ"
EOF
)"
ETAG=$(hv ug-data/d-etag-get.txt); export ETAG

ses ug-data/d-etag-put.txt "$(cat <<'EOF'
printf 'NEW CONTENT\n' | curl -si -u "$MVSMF_USER:$MVSMF_PASS" -X PUT \
  -H 'Content-Type: text/plain' --data-binary @- \
  -H "If-Match: $ETAG" -H 'X-IBM-Return-Etag: true' \
  "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.DEMO.SEQ"
EOF
)"
NEWETAG=$(hv ug-data/d-etag-put.txt)

# the same ETag again: the data set has changed since it was issued
ses ug-data/d-etag-stale.txt "$(cat <<'EOF'
printf 'LOST UPDATE\n' | curl -si -u "$MVSMF_USER:$MVSMF_PASS" -X PUT \
  -H 'Content-Type: text/plain' --data-binary @- \
  -H "If-Match: $ETAG" \
  "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.DEMO.SEQ"
EOF
)"

# the reader now takes the ETag of d-etag-put
ETAG=$NEWETAG; export ETAG
ses ug-data/d-etag-304.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" \
  -H "If-None-Match: $ETAG" \
  "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.DEMO.SEQ"
EOF
)"

# ---- 6. rename and delete ---------------------------------------------------

# the member in the URL is the new name, the member in the body the old one
ses ug-data/d-rename-mbr.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" -X PUT \
  -H 'Content-Type: application/json' \
  -d '{"request":"rename","from-dataset":{"dsn":"'$MVSMF_USER'.DEMO.PDS","member":"HOLA"}}' \
  "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.DEMO.PDS(ADIOS)"
EOF
)"

ses ug-data/d-del-mbr.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" -X DELETE \
  "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.DEMO.PDS(ZETA)"
EOF
)"

ses ug-data/d-del-mbr-gone.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.DEMO.PDS(ZETA)"
EOF
)"

ses ug-data/d-del-ds.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" -X DELETE \
  "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.DEMO.SEQ"
EOF
)"

ses ug-data/d-del-ds-gone.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" \
  "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.DEMO.SEQ"
EOF
)"

# ---- 7. what a caller without access sees -----------------------------------
# LOW_USER / LOW_PASS: an ordinary user (see the top of this file). The name
# does not exist, and the check comes before the catalog lookup.

(
	if [ -n "${LOW_USER:-}" ]; then
		MVSMF_USER=$LOW_USER
		MVSMF_PASS=${LOW_PASS:-}
		export MVSMF_USER MVSMF_PASS
	fi

	ses ug-data/d-denied-put.txt "$(cat <<'EOF'
printf 'X\n' | curl -si -u "$MVSMF_USER:$MVSMF_PASS" -X PUT \
  -H 'Content-Type: text/plain' --data-binary @- \
  "$MVSMF_URL/zosmf/restfiles/ds/SYS1.MVSMF.NOSUCH"
EOF
)"

	ses ug-data/d-denied-del.txt "$(cat <<'EOF'
curl -si -u "$MVSMF_USER:$MVSMF_PASS" -X DELETE \
  "$MVSMF_URL/zosmf/restfiles/ds/SYS1.MVSMF.NOSUCH"
EOF
)"
)

# ---- 8. clean up -------------------------------------------------------------

for n in SEQ PDS BIN; do
	hid 'curl -s -o /dev/null -u "$MVSMF_USER:$MVSMF_PASS" -X DELETE "$MVSMF_URL/zosmf/restfiles/ds/$MVSMF_USER.DEMO.'$n'"'
done
