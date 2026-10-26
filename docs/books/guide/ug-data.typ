#import "../bookmaster/bookmaster.typ": *

= Working with Data Sets <ug-data>

#idx("data sets")#idx("PDS")#idx("restfiles/ds")
This chapter shows how to work with MVS data sets through mvsMF: create a
sequential data set and a partitioned data set (PDS), write and read them, list
data sets and members, move between text and binary, update a data set without
losing a change that somebody else made, rename a member, delete, and see what a
user without access gets. Each section is a task, and each task has a session
that was typed with #cmd("curl"). The _mvsMF Reference_ lists every request,
parameter, header and error report of the data set services, in the chapter
“Data Set Services”.

The variables #cmd("MVSMF_URL"), #cmd("MVSMF_USER") and #cmd("MVSMF_PASS") in
the sessions, and the way to read them, are explained in @ug-first. One more
appears in the sections on the ETag. #cmd("ETAG") holds the value of the header
#cmd("ETag") of an earlier answer. Copy it from that answer by hand.

== Names and What to Expect <ug-data-names>

#idx("data set name")#idx("case")
Every request in this chapter has the address
#cmd("MVSMF_URL/zosmf/restfiles/ds"), followed by the name of a data set. A
member goes in parentheses after the name: #cmd("MY.DATA(HELLO)"). mvsMF turns
the names to upper case, so #cmd("my.data") and #cmd("MY.DATA") are the same
data set. A data set name has at most 44 characters, a member name at most 8.
A longer name gets the status #cmd("400").

The sessions use three data sets below the user ID of the caller:
#cmd("MVSMF_USER.DEMO.SEQ") (a sequential data set), #cmd("MVSMF_USER.DEMO.PDS")
(a PDS) and #cmd("MVSMF_USER.DEMO.BIN") (a sequential data set for binary data).
Where a session shows #cmd("$MVSMF_USER.DEMO.SEQ"), the shell fills in your
user ID. The user needs some space on a volume. Creating a data set needs one
more right than writing it, which @ug-data-create names.

mvsMF does not need the header #cmd("X-CSRF-ZOSMF-HEADER"), and no request in
this chapter sends it. Most sessions use #cmd("curl -si"), so that the output
begins with the status line and the headers. The sessions that show only bytes
use #cmd("curl -s"). The answers carry the header #cmd("Set-Cookie") with a
session token. The sessions show its value as #cmd("<token>").

#note[*The status line is the first thing to read.* A request that fails
returns a JSON error report with the fields #cmd("category"), #cmd("rc"),
#cmd("reason") and #cmd("message"), and sometimes #cmd("details"). The reports
are listed in the _mvsMF Reference_, and @ug-errors explains how to read one.]

== Creating a Data Set and a PDS <ug-data-create>

#idx("create", "data set")#idx("PDS", "create")#idx("allocation")
A #cmd("POST") to the name of a new data set allocates and catalogs it. The body
is JSON. A sequential data set needs five fields: #cmd("dsorg"), #cmd("recfm"),
#cmd("lrecl"), #cmd("blksize") and #cmd("primary"). The first two are strings,
the others are numbers without quotes. The fields #cmd("secondary") and
#cmd("alcunit") are optional. The unit defaults to tracks. This session creates
a sequential data set of fixed blocked records of 80 bytes:

#screen(raw(read("../ex/ug-data/d-create-seq.txt"), block: true))

The status is #cmd("201"), and the answer has no body. A PDS is the same
request with #cmd("dsorg") #cmd("PO") and a field #cmd("dirblk"), the number of
directory blocks. The directory limits how many members the library can hold:

#screen(raw(read("../ex/ug-data/d-create-pds.txt"), block: true))

A request with a field missing is refused before anything is allocated. The
status is #cmd("400") and the message is
#cmd("Invalid or missing allocation parameters"):

#screen(raw(read("../ex/ug-data/d-create-bad.txt"), block: true))

A field with a number in quotes counts as missing: write #cmd("80"), not
#cmd("\"80\"").

mvsMF has no check of its own for a create. The system allocates the data set
for the caller, and RAKF can refuse it there, in two steps. The first looks at
the name of the new data set: a data set whose first qualifier is the user ID of
the caller is always allowed. The second looks at the catalog: when the first
qualifier has no alias in the catalog, the caller needs UPDATE to the resource
#cmd("SYS1.VSAM.MASTER.CAT"). The sessions of this chapter were taken by a
user who has this right through a group. @ug-security shows how to give it. If
the allocation fails, the answer is #cmd("500") with the return code
#cmd("900"), the category #cmd("8"), the reason #cmd("7") and the message
#cmd("Dynamic allocation Error"). The report does not say whether RAKF refused
the name, RAKF refused the catalog, or the system could not meet the
parameters: the code gives the same answer for all of them.

The field #cmd("like") names an existing data set as a model. The other fields
then override the model, and none is required. The _mvsMF Reference_ describes
what mvsMF takes from the model.

== Writing a Data Set <ug-data-write>

#idx("write", "data set")#idx("replace")
A #cmd("PUT") to the name of an existing data set replaces its content. The body
is the new content. A line feed, a carriage return, or a carriage return and a
line feed together end a record. The terminator is not stored, and an empty line
is a record of blanks. mvsMF translates the text from ASCII to EBCDIC. mvsMF
does not create the data set for a #cmd("PUT"): create it first, as in the
section before. A name that is not cataloged answers #cmd("404").

#screen(raw(read("../ex/ug-data/d-put-seq.txt"), block: true))

The status is #cmd("204"), and the answer has no body. The data set now holds two
records. The old content is gone once the first new record is written. If the
request fails half way, the part that was written stays. A body that is empty
empties the data set.

A line that is longer than the record length of the data set is cut. mvsMF
writes the body and then answers #cmd("500") with the message
#cmd("Record truncated to the record length of the data set"). Check the status
of every write.

A member is written in the same way. The member is created if it does not
exist, and replaced if it does. The library must exist.

#screen(raw(read("../ex/ug-data/d-put-mbr.txt"), block: true))

A #cmd("PUT") to the name of a PDS without a member is refused with the status
#cmd("400"). The message tells to use the form with the member.

== Reading a Data Set <ug-data-read>

#idx("read", "data set")#idx("read", "member")
A #cmd("GET") reads a sequential data set. The answer is the status line, the
headers, and the text of the records:

#screen(raw(read("../ex/ug-data/d-get-seq.txt"), block: true))

The content type is #cmd("text/plain"). mvsMF translates every record from
EBCDIC to ASCII and ends it with a line feed. For records of fixed length, mvsMF
removes the trailing blanks first, so the two lines come back as they were
written. The answer has no #cmd("Content-Length"): HTTPD sends it in chunks.

A member has the same request with the member in parentheses:

#screen(raw(read("../ex/ug-data/d-get-mbr.txt"), block: true))

A read of a PDS without a member is refused with the status #cmd("400"), as a
write is. A name that is not cataloged answers #cmd("404") with the message
#cmd("Dataset not found"), and a member that is not in the library answers
#cmd("404") with #cmd("PDS member not found"). The sections on deleting show
both.

== Listing Data Sets and Members <ug-data-list>

#idx("list", "data sets")#idx("dslevel")#idx("list", "members")
=== Data Sets by Level <ug-data-list-ds>

A #cmd("GET") to #cmd("MVSMF_URL/zosmf/restfiles/ds") with the parameter
#cmd("dslevel") lists the cataloged data sets that match a level. The level
#cmd("MVSMF_USER.DEMO") lists the three data sets of this chapter:

#screen(raw(read("../ex/ug-data/d-list-ds.txt"), block: true))

The answer is a JSON object. The field #cmd("items") holds one object for each
data set, in EBCDIC order of the names, so #cmd("DEMO.BIN") comes before
#cmd("DEMO.PDS") and #cmd("DEMO.SEQ"). Each object has the fields
#cmd("dsname"), #cmd("vol"), #cmd("dsorg"), #cmd("recfm"), #cmd("lrecl"),
#cmd("blksz") and others. All values are strings. The field #cmd("returnedRows")
counts the items. A level that matches nothing gives the status #cmd("200") and
an empty #cmd("items"). The level may contain the wildcard characters
#cmd("*") and #cmd("?"). The _mvsMF Reference_ lists every field.

mvsMF makes no RAKF check for this request. A user sees every data set that the
catalog holds for the level.

The header #cmd("X-IBM-Max-Items") limits the number of items. This request asks
for one:

#screen(raw(read("../ex/ug-data/d-list-ds-page.txt"), block: true))

The status is still #cmd("200"). The field #cmd("moreRows") with the value
#cmd("true") says that more data sets follow. When there are no more, the field
is not in the answer. The answer holds no cursor and does not name the next data
set. To read the next page, send the name of its first data set in the parameter
#cmd("start"). The list begins with that name: it is included. This request
continues at #cmd("DEMO.PDS"), the data set after the first page in the full
list above:

#screen(raw(read("../ex/ug-data/d-list-ds-next.txt"), block: true))

The page has one item again, and #cmd("moreRows") is still #cmd("true"), because
#cmd("DEMO.SEQ") follows. The parameter #cmd("volser") is read and ignored.

A server searches the catalog for one list at a time. When several clients ask
for a list together, the lists run one after the other, so each of them can take
longer than a single list does. None is refused and none fails because of it.
A client that lists while others do may need a longer timeout. The list of
members does not wait for the lists of data sets. The _mvsMF Reference_ names
the lock.

*Change from mvsMF 1.3.0:* when mvsMF could not get the storage for the list, it
did not look for the cause and answered #cmd("200") with the list that it had,
which could be empty. It answers #cmd("500") with the message
#cmd("Storage for the list could not be obtained") now, and writes the message
#cmd("MVSMF006E") on the console. An empty level is still a #cmd("200") with no
items.

*Change from mvsMF 1.3.0:* the field #cmd("dev") names the device of the volume
from the track capacity in its format-4 DSCB: #cmd("3330"), #cmd("3350"),
#cmd("3375"), #cmd("3380") or #cmd("3390"). A volume of another capacity, and a
volume whose DSCB cannot be read, give #cmd("????"). Version 1.3.0 took the number
of tracks per cylinder, which a 3380 and a 3390 share, and listed a 3380 as
#cmd("3390").

=== Members of a PDS <ug-data-list-mbr>

The address of the member list is the name of the PDS followed by
#cmd("/member"):

#screen(raw(read("../ex/ug-data/d-list-mbr.txt"), block: true))

The answer has the same form as the list of data sets. Each item has one field,
#cmd("member"). The members come in the order of the directory, which is the
EBCDIC order of the names. The parameter #cmd("pattern") selects names. A
#cmd("*") stands for any run of characters and a #cmd("%") for one character.
With #cmd("X-IBM-Max-Items") the list pages as above:

#screen(raw(read("../ex/ug-data/d-list-mbr-page.txt"), block: true))

The next page begins with the name in #cmd("start"):

#screen(raw(read("../ex/ug-data/d-list-mbr-next.txt"), block: true))

The member list needs READ access to the library. A data set that is not a PDS
gives the status #cmd("400"), and a name that is not cataloged gives
#cmd("404").

== Text, Binary and the Two Codepages <ug-data-type>

#idx("X-IBM-Data-Type")#idx("binary")#idx("codepage")#idx("IBM-037")
#idx("IBM-1047")#idx("fileEncoding")
=== Binary Data <ug-data-binary>

The request header #cmd("X-IBM-Data-Type") chooses how mvsMF treats the bytes.
Without it the type is #cmd("text"), and mvsMF translates between ASCII and
EBCDIC. With #cmd("binary") the bytes are moved as they are, with no
translation. This session writes six bytes into the data set
#cmd("DEMO.BIN"), which has records of 80 bytes. The bytes include #cmd("00") and
#cmd("FF"), which no text translation keeps:

#screen(raw(read("../ex/ug-data/d-put-bin.txt"), block: true))

mvsMF cuts the bytes into records of the record length. The last record, which is
not full, is filled with X'00' to the full length, except in a sequential data
set of record format U. A member is always filled. The six bytes are one record of 80 bytes. The read in binary
mode returns the records one after another, as they are stored:

#screen(raw(read("../ex/ug-data/d-get-bin.txt"), block: true))

The first six bytes of the output are #cmd("41 42 43 00 01 ff"), the bytes that
were written. The 26 bytes after them, which the session shows, are X'00': the
padding of the record. The command pipes the answer to #cmd("od") and keeps its
first two lines, 32 bytes, because the bytes are not text. The answer has the
content type #cmd("application/octet-stream"). The _mvsMF Reference_ describes
the third type, #cmd("record"), which puts a length of four bytes before each
record.

*Change from mvsMF 1.3.0:* a read with the type #cmd("record") of a data set or
member of the record format V, VB or VBS is refused with #cmd("400"). Version
1.3.0 answered #cmd("200") with data that did not match the records. Read such
data with the type #cmd("text") or #cmd("binary"). The formats F and FB are not
affected.

*Change from mvsMF 1.3.0:* a binary read of a fixed-block data set, and the
ETag, stop at the last block that holds data. mvsMF works out that block count
from the position of the last block and from the number of blocks that fit on a
track. Version 1.3.0 used one formula for every device. Version 1.4.0 takes the
formula from the device type in the format-4 DSCB of the volume: bytes per block
for the devices that count a track in bytes (such as the 3350 in the sessions),
and cells for the 3380, which the old formula did not fit. For a device that it
does not know, a 3390 among them, mvsMF makes no estimate and reads to the end
of the data set.

=== Two Codepages <ug-data-codepage>

Text in a data set is EBCDIC, and there are two EBCDIC tables in use. mvsMF
translates a data set with CP037 (the name #cmd("IBM-037") in the header) unless
the request names IBM-1047. The two tables give different bytes for a few
characters, among them the square brackets and the circumflex. This session
writes the line #cmd("A[B]^") with the default table and reads it back in three
ways. The write:

#screen(raw(read("../ex/ug-data/d-enc-put.txt"), block: true))

The default read uses the same table and returns the line as it was written:

#screen(raw(read("../ex/ug-data/d-enc-get.txt"), block: true))

The same stored bytes read with IBM-1047 are other characters. The session pipes
the answer to #cmd("od"), because the bytes are not all ASCII:

#screen(raw(read("../ex/ug-data/d-enc-get1047.txt"), block: true))

The bytes #cmd("41") and #cmd("42") are #cmd("A") and #cmd("B"), and #cmd("0a")
is the line feed. The three characters between them did not come back. CP037
stored #cmd("[") as X'BA', #cmd("]") as X'BB' and #cmd("^") as X'B0'. IBM-1047
has no square bracket or circumflex at those places. Its table turns the bytes
into the bytes #cmd("dd"), #cmd("a8") and #cmd("ac") of the dump. In ISO 8859-1
these are a capital Y with an acute accent, a diaeresis and a not sign. In
IBM-1047 the characters themselves are X'AD', X'BD' and X'5F'. So
all three characters change, not two.

The rule is: read a data set with the table that wrote it. Pass
#cmd("text;fileEncoding=IBM-1047") on a write as well as on a read when the
other program that uses the data set works in IBM-1047. The accepted values are
#cmd("IBM-037"), #cmd("037"), #cmd("IBM-1047") and #cmd("1047"). Do not put a
blank after the semicolon: mvsMF takes #cmd("text; fileEncoding=IBM-1047") as
text with the default table. Any other value is refused:

#screen(raw(read("../ex/ug-data/d-enc-bad.txt"), block: true))

The status is #cmd("500"). The report has the return code #cmd("121"), the
category #cmd("16") and the message #cmd("iconv_open() failed."), and its detail
names the value and the two tables that are supported. A binary request ignores
the encoding.

#note[*The UNIX side has its own default.* The files below
#cmd("/zosmf/restfiles/fs") use IBM-1047 unless the request says otherwise. The
data sets use CP037. See @ug-uss.]

== Updating a Data Set Safely with an ETag <ug-data-etag>

#idx("ETag")#idx("If-Match")#idx("If-None-Match")#idx("X-IBM-Return-Etag")
Two users can read the same data set, change it, and write it back. The second
write replaces the first. An ETag prevents this. The ETag is a short value that
mvsMF computes from the records of the data set. It changes when the content
changes. It has 16 hexadecimal digits. The first eight are a CRC-32 checksum of
the records, in which the length of every record is part of the sum. The last
eight are the number of bytes in the records, in hexadecimal. The ETags in the
sessions end in #cmd("00000050"), which is 80: one record of 80 bytes, the
record length of the data set. The sum covers the record as it is stored, with
its trailing blanks.

Ask for the ETag with the header #cmd("X-IBM-Return-Etag: true") on a read:

#screen(raw(read("../ex/ug-data/d-etag-get.txt"), block: true))

The answer carries the header #cmd("ETag"). Keep the value in the variable
#cmd("ETAG"). Send it back on the write in the header #cmd("If-Match"), and ask
for the new ETag in the same request:

#screen(raw(read("../ex/ug-data/d-etag-put.txt"), block: true))

The write goes through, because the data set has not changed since the read. The
status is #cmd("204"), and the answer carries the ETag of the data set after the
write. Keep it for the next update. This value is read from the data set again
after the write. It is not a value of the body that was sent.

Now the data set has changed, and the old ETag is stale. In the next session
#cmd("ETAG") still holds the old value, the one of the first read. A write with
it is refused before mvsMF touches the data set:

#screen(raw(read("../ex/ug-data/d-etag-stale.txt"), block: true))

The status is #cmd("412"), the reason is #cmd("10") and the message is
#cmd("The resource was modified since the supplied ETag was created"). The data
set keeps its content. Read the data set again, merge the change, and write with
the new ETag. A member that does not exist, or that mvsMF cannot read, gives the
same #cmd("412") for an #cmd("If-Match"), and a data set that does not exist
gives #cmd("404").

The header #cmd("If-None-Match") works for a read. Send the ETag that you hold;
in the next session #cmd("ETAG") holds the new value from the write.
If the data set has not changed, the answer is #cmd("304") with no body. It
carries the ETag again, and you do not transfer the content again:

#screen(raw(read("../ex/ug-data/d-etag-304.txt"), block: true))

If the data set has changed, the answer is the normal #cmd("200") with the
content, and it carries the new ETag. The value in the header may be written
with quotes or with the prefix #cmd("W/"), and a list of values separated by
commas is allowed. The ETag does not depend on the type of the read: text and
binary reads of a data set give the same value.

#note[*An ETag guards a write that carries it.* A client that sends no
#cmd("If-Match") overwrites the data set at once. The ETag is a check that the
client chooses to make.]

== Renaming a Member <ug-data-rename>

#idx("rename")
A rename is a #cmd("PUT") with a JSON body. In the form for a member, the
address names the new member. The body names the old one in the object
#cmd("from-dataset"). The body must say #cmd("\"request\":\"rename\""), and the
header #cmd("Content-Type") must be #cmd("application/json"). That header makes
mvsMF treat the request as a rename and not as a write of data.

#screen(raw(read("../ex/ug-data/d-rename-mbr.txt"), block: true))

The status is #cmd("204"), and the answer has no body. The member #cmd("HOLA")
is now #cmd("ADIOS"). For a member, mvsMF takes the library from the address
and the old member name from the field #cmd("member") of the body. If the new
name exists, the answer is #cmd("400") with the message
#cmd("Rename target already exists"). If the old member does not exist, the
answer is #cmd("404") with the message #cmd("PDS member not found"). A data set
is renamed in the same way: the address names the new name, and the field
#cmd("dsn") of #cmd("from-dataset") holds the old name, with no field
#cmd("member"). If the old data set is not cataloged, the answer is #cmd("404")
with the message #cmd("Dataset not found"). Any other failure of the rename of a
data set answers #cmd("500") with the message #cmd("Rename operation failed").

== Deleting a Member and a Data Set <ug-data-delete>

#idx("delete", "member")#idx("delete", "data set")#idx("scratch")
A #cmd("DELETE") with the name of a member removes the member from the library:

#screen(raw(read("../ex/ug-data/d-del-mbr.txt"), block: true))

The status is #cmd("204"), and the answer has no body. A read of the member
shows that it is gone. The status is #cmd("404"), and the message is
#cmd("PDS member not found"):

#screen(raw(read("../ex/ug-data/d-del-mbr-gone.txt"), block: true))

A #cmd("DELETE") with the name of a data set removes the data set:

#screen(raw(read("../ex/ug-data/d-del-ds.txt"), block: true))

mvsMF asks for no confirmation, and the data set is scratched and uncataloged.
A read now says that the data set is not
cataloged. The status is #cmd("404"), and the message is #cmd("Dataset not found"):

#screen(raw(read("../ex/ug-data/d-del-ds-gone.txt"), block: true))

A delete of a data set needs a higher access than a write. See the next section.

== What an Unauthorized User Sees <ug-data-denied>

#idx("authorization", "data sets")#idx("RAKF")#idx("403")
mvsMF asks RAKF for every request that reads, writes, renames or deletes, and
asks it before it looks at the catalog. The class is #cmd("DATASET"). The access
needed is READ to read a data set or a member and to list members, UPDATE to
write, to rename a member and to delete a member, and ALTER to delete or rename
a data set. A rename of a data set checks the old name and the new name. A list
of data sets and a create are not checked by mvsMF; for a create, see
@ug-data-create.

A name for which no profile exists is permitted. A refusal is not a #cmd("403").
It is a #cmd("500") with the message #cmd("LMOPEN error") and the detail
#cmd("Authorization failed - You may not use this protected data set."). The
caller who is refused sees this on a write and on a delete:

#screen(raw(read("../ex/ug-data/d-denied-put.txt"), block: true))

#screen(raw(read("../ex/ug-data/d-denied-del.txt"), block: true))

The sessions were taken by a second user ID that has no right to the name. Both
sessions name a data set that does not exist. A caller who has no access to
the name is refused with the report above. A caller for whom no profile covers
the name gets #cmd("404") with #cmd("Dataset not found") instead. Because the
check comes first, a refused caller learns nothing about whether the data set
exists. The profiles that protect data sets are set up as described in
@ug-security.
