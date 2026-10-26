#import "../bookmaster/bookmaster.typ": *

= Data Set Services <ref-ds>

#idx("data sets", "REST services")#idx("restfiles/ds")
This chapter lists every request that mvsMF answers below
#cmd("/zosmf/restfiles/ds"): the requests that list, read, write, create,
rename and delete data sets and PDS members. For each request it gives the
method, the path, the query parameters, the request headers, the body, the
response, and the statuses and error reports. The conventions that hold for all
services are in @ref-conv. The access that RAKF must give is in @ref-ds-auth,
and the operator messages that these requests write are in @ref-ds-msgs. The
_mvsMF User's Guide_ shows each task with a session.

mvsMF is a clone of the z/OSMF data set service. This chapter describes what
mvsMF 1.4.0 does.

== Request Summary <ref-ds-sum>

#tab(caption: [Data set requests])[
  #table(columns: (0.7in, 2.45in, 1fr),
    [Method], [Path], [Function],
    [GET], [#cmd("/zosmf/restfiles/ds")], [List data sets (@ref-ds-list).],
    [GET], [#cmd("/zosmf/restfiles/ds/{dataset-name}/member")],
      [List the members of a PDS (@ref-ds-members).],
    [GET], [#cmd("/zosmf/restfiles/ds/{dataset-name}")],
      [Read a sequential data set (@ref-ds-read).],
    [GET], [#cmd("/zosmf/restfiles/ds/{dataset-name}({member-name})")],
      [Read a PDS member (@ref-ds-read).],
    [PUT], [#cmd("/zosmf/restfiles/ds/{dataset-name}")],
      [Replace the content of a sequential data set (@ref-ds-write), or rename
      a data set when the body is a rename request (@ref-ds-rename).],
    [PUT], [#cmd("/zosmf/restfiles/ds/{dataset-name}({member-name})")],
      [Replace or create a PDS member (@ref-ds-write), or rename a member
      (@ref-ds-rename).],
    [POST], [#cmd("/zosmf/restfiles/ds/{dataset-name}")],
      [Create a data set or a PDS (@ref-ds-create).],
    [DELETE], [#cmd("/zosmf/restfiles/ds/{dataset-name}")],
      [Delete a data set (@ref-ds-delete).],
    [DELETE], [#cmd("/zosmf/restfiles/ds/{dataset-name}({member-name})")],
      [Delete a PDS member (@ref-ds-delete).],
  )
]

No other method and path pair is routed. A request for one of the nine paths
with a method that the path does not offer (a POST to a member, a PUT to the
member list) gets #cmd("405") with the report #cmd("Http method POST is not
supported by this URL") (category 6, rc 4, reason 7). A request that matches
none of the paths (a GET below #cmd("/member"), a path that names a volume
serial in parentheses after the data set name) gets #cmd("404") with the
report #cmd("Not Found") (category 6, rc 4, reason 7). An HTTP method that
mvsMF does not know at all gets #cmd("405") with no body. The routes that named
a volume serial were withdrawn in mvsMF 1.4.0: they ignored the serial.

== Names and Case <ref-ds-names>

#idx("data set name")#idx("member name")#idx("case")
HTTPD percent-decodes the path once before it is matched. A client may send the
parentheses of a member name as #cmd("%28") and #cmd("%29"). The value of
#var("dataset-name") ends at a slash and at a parenthesis.

mvsMF folds a data set name, a member name and the value of #cmd("dslevel") to
upper case before it asks RAKF and before it looks at the catalog. The names in
the body of a rename request and the field #cmd("like") of a create request are
folded in the same way.

#tab(caption: [Name limits])[
  #table(columns: (1.6in, 0.6in, 1fr),
    [Name], [Limit], [Answer for a longer name],
    [Data set name, #cmd("dslevel")], [44], [#cmd("400"), category 6, rc 8, reason 1, #cmd("Dataset name is too long") (for #cmd("dslevel"): #cmd("Dataset level is too long")).],
    [Member name], [8], [#cmd("400"), reason 1, #cmd("Member name is too long").],
    [Member pattern], [44], [#cmd("400"), reason 9, #cmd("Member pattern is too long") (a pattern of 45 characters or more).],
  )
]

== Headers and Common Response Fields <ref-ds-common>

#idx("headers", "request")#idx("headers", "response")
All requests need the user that HTTPD has authenticated. A request with no
resolved user gets #cmd("401") with no body. The data set services read these
request headers:

#tab(caption: [Request headers of the data set services])[
  #table(columns: (1.7in, 1fr),
    [Header], [Used by],
    [#cmd("X-IBM-Max-Items")], [The two lists (@ref-ds-list, @ref-ds-members).],
    [#cmd("X-IBM-Data-Type")], [Read and write (@ref-ds-type).],
    [#cmd("X-IBM-Return-Etag")], [Read and write (@ref-ds-etag).],
    [#cmd("If-None-Match")], [Read (@ref-ds-etag).],
    [#cmd("If-Match")], [Write (@ref-ds-etag).],
    [#cmd("Content-Type")], [A value that contains #cmd("application/json") makes a PUT a rename request (@ref-ds-rename).],
    [#cmd("Content-Length"), #cmd("Transfer-Encoding")], [Write: one of the two is required (@ref-ds-write).],
  )
]

mvsMF does not need #cmd("X-CSRF-ZOSMF-HEADER") and does not read it.
#cmd("X-IBM-Attributes") is read by no request of this chapter.

Every response carries #cmd("Cache-Control: no-store"), #cmd("Pragma: no-cache"),
#cmd("X-Content-Type-Options: nosniff") and #cmd("Content-Language: en"). A
response to a request with an #cmd("Authorization") header also carries the
session cookie when HTTPD has a token for the user.

The framing of a reply depends on the request. A reply that reads (a list, a
member list, a read) has no #cmd("Content-Length"); HTTPD sends it in chunks.
The success of a create is #cmd("201") with the content type
#cmd("application/json") and no body; it is chunked and has no
#cmd("Content-Length"). The success of a write, a delete and a rename is
#cmd("204") with the content type #cmd("application/json") and no
#cmd("Content-Length"). The answer #cmd("304") has neither #cmd("Content-Type")
nor #cmd("Content-Length"). An error report has the content type
#cmd("application/json") and a #cmd("Content-Length").

== List Data Sets <ref-ds-list>

#idx("list", "data sets")#idx("dslevel")#idx("catalog", "listing")
#cmd("GET /zosmf/restfiles/ds?dslevel=LEVEL")

The request lists the cataloged non-VSAM data sets that match a level. mvsMF
makes no RAKF check for this request (@ref-ds-auth).

#tab(caption: [Query parameters and header of the data set list])[
  #table(columns: (1.35in, 1fr),
    [Name], [Meaning],
    [#cmd("dslevel")], [The level or pattern (@ref-ds-level). More than 44
      characters gives #cmd("400") (@ref-ds-names).],
    [#cmd("start")], [A data set name. The list begins with this name if it
      exists, or with the next name in the order of the list. Trailing blanks
      are dropped and the value is folded to upper case. A value longer than 44
      characters is cut, and the list then begins after the cut name instead of
      at it.],
    [#cmd("volser")], [Read and ignored. The list is not restricted to a
      volume.],
    [#cmd("X-IBM-Max-Items")], [Header. The largest number of items to
      return. 0, no value, or a value that is not a number means no limit.],
  )
]

=== The Level <ref-ds-level>

#idx("dslevel", "wildcards")
The level may contain the wildcard characters #cmd("*") and #cmd("?"). The
level #cmd("HLQ.**") gives the same list as the bare level #cmd("HLQ"). A level
with a dot and no wildcard lists the data set of exactly that name, if it is
cataloged, and every data set below it.

=== The Response <ref-ds-list-resp>

The list is sorted by name in EBCDIC order, and the page is cut from the sorted
list. The status is #cmd("200"), also when #cmd("X-IBM-Max-Items") cut the
list and when nothing matches. The body is a JSON object:

#tab(caption: [Fields of the data set list])[
  #table(columns: (1.35in, 0.9in, 1fr),
    [Field], [Type], [Value],
    [#cmd("items")], [array], [One object for each data set (below). The array is empty when nothing matches.],
    [#cmd("returnedRows")], [number], [The number of objects in #cmd("items").],
    [#cmd("moreRows")], [boolean], [Present, with the value #cmd("true"), only when more data sets follow the page. Absent otherwise.],
    [#cmd("JSONversion")], [number], [Always #cmd("1").],
  )
]

mvsMF does not send #cmd("totalRows").

#tab(caption: [Fields of an item, in the order mvsMF writes them])[
  #table(columns: (0.85in, 1fr),
    [Field], [Value (all are strings)],
    [#cmd("dsname")], [The data set name.],
    [#cmd("blksz")], [The block size.],
    [#cmd("catnm")], [Always the empty string.],
    [#cmd("cdate")], [The creation date as #cmd("YYYY/MM/DD").],
    [#cmd("dev")], [The device type of the volume, named from the track capacity in bytes
      that its format-4 DSCB reports: 13165 gives #cmd("3330"), 19254 gives #cmd("3350"),
      36000 gives #cmd("3375"), 47968 gives #cmd("3380"), 58786 gives #cmd("3390").
      Any other capacity, and a volume whose format-4 DSCB cannot be read, give
      #cmd("????"): mvsMF does not guess a device. The number of tracks per
      cylinder does not decide it, because a 3380 and a 3390 both have 15.
      Before 1.4.0 the name came from that number, and a 3380 was listed as
      #cmd("3390").],
    [#cmd("dsntp")], [#cmd("PDS") for organization #cmd("PO"), #cmd("BASIC") for #cmd("PS"), #cmd("UNKNOWN") for any other.],
    [#cmd("dsorg")], [The data set organization.],
    [#cmd("edate")], [Always #cmd("***None***").],
    [#cmd("extx")], [The number of extents of the data set on its volume, all of them.],
    [#cmd("lrecl")], [The logical record length.],
    [#cmd("migr")], [Always #cmd("NO").],
    [#cmd("mvol")], [Always #cmd("N").],
    [#cmd("ovf")], [Always #cmd("NO").],
    [#cmd("rdate")], [The reference date as #cmd("YYYY/MM/DD").],
    [#cmd("recfm")], [The record format, for example #cmd("FB").],
    [#cmd("sizex")], [The number of allocated tracks, whatever the value of #cmd("spacu") is. The sum covers every extent. The disk label holds three extents of a data set, and a data set with more has the rest in a further label on the volume, which mvsMF reads. If mvsMF cannot read it, the value is the string #cmd("?").],
    [#cmd("spacu")], [#cmd("CYLINDERS") or #cmd("TRACKS"), the unit of the allocation.],
    [#cmd("used")], [The share of the allocated tracks that the data set uses, in percent. The count goes up to the track that holds the last block written, so a new data set that is empty already uses one track. The value is #cmd("?") whenever #cmd("sizex") is #cmd("?"), and 0 when no track is allocated.],
    [#cmd("vol")], [The volume serial.],
    [#cmd("vols")], [The volume serials.],
  )
]

#idx("device type", "data set list")

=== Errors <ref-ds-list-err>

The list has two error answers. A level of more than 44 characters answers
#cmd("400") with reason 1. A storage shortage while the list is built answers
#cmd("500") with the report #cmd("Storage for the list could not be obtained")
(category 7, rc 16, reason 0) and writes #cmd("MVSMF006E") (@ref-ds-msgs). A
level that matches nothing is a #cmd("200") with an empty #cmd("items").

*Change from mvsMF 1.3.0:* a storage shortage answered #cmd("200") with an
empty list. It answers #cmd("500") now.

=== Lists Take Turns <ref-ds-list-turns>

#idx("lock", "data set list")#idx("list", "parallel requests")
#idx("MVSMF915I")#idx("MVSMF916W")
mvsMF runs the catalog search of one data set list at a time in a server. The
search has IDCAMS write the catalog entries into a temporary data set, and two
searches must not use the same one. The search takes an exclusive lock, an ENQ
with the resource name #cmd("MVSMF.LISTDS") and the scope of the job step, and
gives it up when the search is done.

- A list that arrives while another search runs waits for it and is then
  served. No list is refused. The wait has no limit in mvsMF.
- The lock covers the catalog search only. The answer is sent after the lock is
  released.
- #cmd("GET /zosmf/test?fn=listds") (@ref-test-listds), which only a
  development build has, takes the same lock. The
  list of members (@ref-ds-members) and the other requests do not.
- The status and the body of a list are the same with or without a wait.
- When a list abends while it holds the lock, the recovery releases it and
  writes MVSMF915I. When that release abends in turn, the recovery writes
  MVSMF916W, and every later list waits (@apx-messages).

*Change from mvsMF 1.3.0:* the lists did not take turns. With the C library
that mvsMF 1.4.0 is built against, two lists that ran at the same time could
use the same temporary data set. One of them then abended with S213-04, and the
client got status 500 with the message MVSMF901E on the console.

== List the Members of a PDS <ref-ds-members>

#idx("list", "members")#idx("member list")#idx("pattern, member")
#cmd("GET /zosmf/restfiles/ds/{dataset-name}/member")

The request needs READ access to the library (@ref-ds-auth).

#tab(caption: [Query parameters and header of the member list])[
  #table(columns: (1.35in, 1fr),
    [Name], [Meaning],
    [#cmd("start")], [A member name. The list begins with this name if it
      exists, or with the next name in directory order. Trailing blanks are
      dropped and the value is folded to upper case. A value longer than 8
      characters is cut, and the list then begins after the cut name instead of
      at it.],
    [#cmd("pattern")], [A pattern. #cmd("*") stands for any run of characters,
      also none, and #cmd("%") for exactly one character. 45 or more
      characters give #cmd("400"), reason 9.],
    [#cmd("X-IBM-Max-Items")], [Header. The largest number of items to return.
      0, no value, or a value that is not a number means no limit.],
  )
]

The directory is read in its own order, which is the EBCDIC order of the names.
mvsMF writes the list while it reads the directory, and it looks one matching
member past the end of the page to know whether more follow. The body has the
fields #cmd("items"), #cmd("returnedRows"), #cmd("moreRows") and
#cmd("JSONversion") of @ref-ds-list-resp, with the same rules. Each item is an
object with one field:

#tab(caption: [Item of the member list])[
  #table(columns: (1.35in, 1fr),
    [Field], [Value],
    [#cmd("member")], [The member name. A character that is not printable, a
      quotation mark and a backslash are written as a #cmd("\\uXXXX") escape that
      names the ASCII value.],
  )
]

mvsMF checks in this order: the length of the names, READ access, the length of
the pattern, and the data set. A data set that is not cataloged answers
#cmd("404") (category 6, rc 8, reason 4, #cmd("Dataset not found")). A data set
that is not partitioned answers #cmd("400") (reason 1). A directory that cannot
be opened after these checks answers #cmd("404") with the same message in
category 7 (category 7, rc 8, reason 4).

== Read a Data Set or a Member <ref-ds-read>

#idx("read", "data set")#idx("read", "member")
#cmd("GET /zosmf/restfiles/ds/{dataset-name}")

#cmd("GET /zosmf/restfiles/ds/{dataset-name}({member-name})")

Both requests need READ access, a member request on the library
(@ref-ds-auth). The data type header chooses how the records are sent
(@ref-ds-type). The ETag headers are in @ref-ds-etag.

mvsMF checks in this order: the length of the names (#cmd("400")), READ access
(#cmd("500"), @ref-ds-denied), for a sequential request whether the data set is
a PDS (#cmd("400"), reason 1, #cmd("Dataset is a partitioned dataset (PDS). Use /ds/{dataset-name}({member-name}) to access members")),
the data type header (#cmd("500"), @ref-ds-type), the ETag headers
(@ref-ds-etag), and then the open and the read.

An open that fails is explained by looking at the catalog:

#tab(caption: [Statuses of a failed open])[
  #table(columns: (0.6in, 0.45in, 2.0in, 1fr),
    [Status], [Reason], [Report], [Cause],
    [404], [4], [#cmd("Dataset not found")], [The name is not in the catalog.],
    [404], [5], [#cmd("PDS member not found")], [The library has no such member.],
    [400], [1], [#cmd("Dataset is not partitioned (use the dataset endpoint instead)")], [A member request for a data set that is not a PDS.],
    [500], [0], [#cmd("Storage for the list could not be obtained") (category 7, rc 16)], [The check for the member found no storage. Writes #cmd("MVSMF006E").],
    [500], [3], [#cmd("Cannot open dataset") or #cmd("Cannot open dataset member")], [Any other failure of the open.],
  )
]

*Change from mvsMF 1.3.0:* a storage shortage in this check answered
#cmd("404"), #cmd("PDS member not found"). It answers #cmd("500") now.

The response is #cmd("200"). The content type and the body depend on the data
type (@ref-ds-type). When the read meets an I/O error after the status has gone
out, mvsMF writes #cmd("MVSMF106E") and aborts the response.

== The Data Type Header <ref-ds-type>

#idx("X-IBM-Data-Type")#idx("binary")#idx("record mode")#idx("codepage")
#idx("IBM-037")#idx("IBM-1047")#idx("fileEncoding")
The request header #cmd("X-IBM-Data-Type") chooses the type of the transfer and,
for text, the code page. The text before the first semicolon is the type:
#cmd("text"), #cmd("binary") or #cmd("record"), in any case. Any other value,
and no header, means text. The type must be the whole text before the
semicolon: a blank around the word makes it text.

#tab(caption: [Data types])[
  #table(columns: (0.8in, 1.5in, 1fr),
    [Type], [Content type of a read], [Transfer],
    [#cmd("text")], [#cmd("text/plain")], [Read: one line for each record, translated from EBCDIC to ASCII with the chosen table. For F and FB records the trailing blanks are removed first, and each line ends with a line feed. Records of other formats keep their blanks. Write: see @ref-ds-write.],
    [#cmd("binary")], [#cmd("application/octet-stream")], [Read: the records as they are, one after another, with no separator and no translation. Write: the bytes are cut into records (@ref-ds-write).],
    [#cmd("record")], [#cmd("application/octet-stream")], [Read: each record is preceded by four bytes, a big-endian binary length. A read is possible for the record formats F and FB only. A data set or member of the format V, VB or VBS is refused (@ref-ds-record). Write: not usable. Use #cmd("text") or #cmd("binary").],
  )
]

For text, the parameter #cmd("fileEncoding=NAME") after a semicolon chooses the
table. The name of the parameter is not case sensitive. mvsMF does not trim
blanks, so #cmd("text; fileEncoding=IBM-1047") has no encoding and means the
default.

#tab(caption: [Values of fileEncoding])[
  #table(columns: (1.8in, 1fr),
    [Value], [Table],
    [#cmd("IBM-037"), #cmd("037")], [CP037.],
    [#cmd("IBM-1047"), #cmd("1047")], [IBM-1047.],
    [no parameter, #cmd("fileEncoding=") with no value, another parameter], [CP037, the default for data sets.],
    [any other value], [Error. #cmd("500"), category 16, rc 121, reason -1037303780, #cmd("iconv_open() failed."), with the detail #cmd("Unsupported encoding in X-IBM-Data-Type 'VALUE': IBM-037 and IBM-1047 are supported."). VALUE is cut at 64 characters.],
  )
]

The values of the encoding are not case sensitive. CP037 and IBM-1047 give
different bytes for some characters, among them #cmd("[") #cmd("]") and
#cmd("^"). For #cmd("binary") and #cmd("record") the encoding is not looked at,
so a value after the semicolon is not checked. A request with an encoding that
is refused ends before the data set is opened for output, so nothing is
truncated.

=== Record Mode and Variable Records <ref-ds-record>

#idx("record mode")#idx("RECFM=V")
A read with the type #cmd("record") of a data set or a member with the record
format V, VB or VBS answers #cmd("400") with category 6, return code 8 and reason
code 12, and the message #cmd("Record mode (X-IBM-Data-Type: record) is not
supported for RECFM=V data sets"). mvsMF checks this before the headers go out
and before the first record is read, so no data is sent. Before 1.4.0 such a
read answered #cmd("200") with chunks of the length LRECL that ran across the
record boundaries, each with a length prefix that matched no record. Text and
binary reads of the same data set are not affected, and neither are the formats
F and FB. A record mode for variable records is not available yet.

=== The End of a Sequential Data Set <ref-ds-eod>

#idx("end of data")#idx("blocks per track")#idx("3380")
A binary or record read of a sequential data set, and the ETag of a sequential
data set (@ref-ds-etag), stop at the last record that the VTOC reports. mvsMF
estimates the number of records from the last-used track and block, the blocks
per track of the device, and the number of records in a block. It makes the
estimate for fixed-block (FB) data sets without keys. The blocks per track follow
the device of the volume: bytes on a 3350, and cells of 32 bytes on a 3380. For
any other record format, and for a device that mvsMF does not know (a 3390 is
not known), there is no estimate and the read goes to the end of the data set.
A text read has no estimate. A member read has none either and goes to the end
of the member.

*Change from mvsMF 1.3.0:* the estimate used one byte formula for every device.
On a 3380 it put 15 blocks of 3120 bytes on a track where 13 fit, so a data set
of 26 blocks counted as 28.

== Write a Data Set or a Member <ref-ds-write>

#idx("write", "data set")#idx("write", "member")#idx("replace")
#cmd("PUT /zosmf/restfiles/ds/{dataset-name}")

#cmd("PUT /zosmf/restfiles/ds/{dataset-name}({member-name})")

The request replaces the content of an existing sequential data set, and it
replaces or creates a member of an existing PDS. It needs UPDATE access, a
member request on the library (@ref-ds-auth). The data set must exist: mvsMF
does not allocate a data set for a PUT (@ref-ds-create). A request whose
#cmd("Content-Type") contains #cmd("application/json") is not a write but a
rename (@ref-ds-rename).

The request headers are #cmd("X-IBM-Data-Type") (@ref-ds-type), #cmd("If-Match")
and #cmd("X-IBM-Return-Etag") (@ref-ds-etag), and one of
#cmd("Content-Length") and #cmd("Transfer-Encoding: chunked"). With neither,
the answer is #cmd("400") (reason 1, #cmd("Missing Content-Length or Transfer-Encoding header")).

mvsMF checks a sequential write in this order: the length of the name
(#cmd("400")), the JSON type (rename), UPDATE access (#cmd("500")), whether the
data set is a PDS (#cmd("400"), reason 1), the data type header (#cmd("500")),
the length header (#cmd("400")), whether the data set exists (#cmd("404"),
reason 4), #cmd("If-Match") (#cmd("412")), and then the body.

A member write checks the length of the names, the JSON type, UPDATE access,
the length header, the data type header, whether the library is cataloged
(#cmd("404"), reason 4), #cmd("If-Match"), and then the body.

=== The Body <ref-ds-write-body>

The records come from the body. mvsMF opens the data set for output when the
first record is complete, not before. From that moment on the old content is
gone. mvsMF does not stage the new content, so a request that fails after the
first record leaves the part that was written.

#tab(caption: [How the body becomes records])[
  #table(columns: (0.8in, 1fr),
    [Type], [Rule],
    [text], [A line feed, a carriage return, or a carriage return and a line
      feed ends a record. A blank line is a record. A last line with no line
      end is a record. A body that ends with a line end adds no empty record.
      The bytes are translated from ASCII to EBCDIC with the chosen table. A
      line that is longer than the record is cut: to LRECL for F, to LRECL minus
      4 for V, to BLKSIZE for U.],
    [binary], [The bytes are cut into records of LRECL bytes, with no
      translation. For V each record gets its four-byte record descriptor. A
      last record that is not full is filled with X'00' to the full length. The
      write of a sequential data set does not fill a record of format U. The
      write of a member does.],
  )
]

An empty body empties the data set or the member. A data set whose record
length is 0 answers #cmd("500") (reason 3, #cmd("Dataset has zero record length")).
When a line was cut, mvsMF writes the body and then answers #cmd("500")
(reason 3, #cmd("Record truncated to the record length of the data set")).

mvsMF writes each record to the access method at once. If the data set runs out
of space, the answer is #cmd("500") (reason 3) and the operator message is
#cmd("MVSMF107E") (@ref-ds-msgs). A failure to open the data set for output is
explained like a failed read (@ref-ds-read), with the messages
#cmd("Cannot open dataset for writing") and
#cmd("Cannot open dataset member for writing") in the last row, and writes
#cmd("MVSMF101E"). Other failures while the body is read or written answer
#cmd("500") (reason 3) with a text such as #cmd("Error reading data"),
#cmd("Error writing record"), #cmd("Error writing final record") or
#cmd("Error writing the last block"). A failure to get storage answers
#cmd("500") (reason 2, #cmd("Memory allocation failed")).

=== The Response <ref-ds-write-resp>

The success is #cmd("204") with the content type #cmd("application/json") and no
body. With #cmd("X-IBM-Return-Etag: true") the response carries #cmd("ETag"),
the value of the data set after the write, read from the data set again
(@ref-ds-etag). If a member does not exist, the request creates it. A create
that fails can leave an empty member.

== ETag and Conditional Requests <ref-ds-etag>

#idx("ETag")#idx("If-Match")#idx("If-None-Match")#idx("X-IBM-Return-Etag")
#idx("412")#idx("304")
An ETag identifies the records of a data set or a member. It is 16 hexadecimal
digits: eight for a 32-bit check value over the records and eight for the total
number of data bytes, in hexadecimal. The check value takes in the length of each
record as well as its bytes. A response sends the ETag without quotes. The value
does not depend on the data type of the read. For a sequential data set it
covers the records up to the estimate of @ref-ds-eod. For a member it covers all
records.

#tab(caption: [Headers that use the ETag])[
  #table(columns: (1.45in, 0.75in, 1fr),
    [Header], [Request], [Effect],
    [#cmd("X-IBM-Return-Etag: true")], [GET, PUT], [Return #cmd("ETag"). The value #cmd("true") is not case sensitive and blanks around it are allowed. On a PUT the ETag is the one of the data set after the write, not of the body.],
    [#cmd("If-None-Match")], [GET], [mvsMF computes the ETag. If the header matches, the answer is #cmd("304") with the headers of every response and #cmd("ETag"), and no body. If not, the read goes on and the response carries #cmd("ETag") as well.],
    [#cmd("If-Match")], [PUT], [mvsMF computes the ETag before it opens the data set for output. If the header does not match, the answer is #cmd("412") (category 6, rc 8, reason 10, #cmd("The resource was modified since the supplied ETag was created")), and nothing is written. A member that does not exist, or that cannot be read, gives #cmd("412") as well. A data set that does not exist gives #cmd("404").],
  )
]

A header value matches when one of its entries equals the ETag. The entries are
separated by commas. An entry may carry the prefix #cmd("W/") and quotes. The
comparison does not distinguish upper and lower case in the hexadecimal digits.
The entry #cmd("*") matches always. An ETag that cannot be computed, because the
read failed, is left out of the response.

== Create a Data Set <ref-ds-create>

#idx("create", "data set")#idx("allocation")#idx("DCB")#idx("like")
#cmd("POST /zosmf/restfiles/ds/{dataset-name}")

The request allocates and catalogs a data set. mvsMF passes no access level to
the security check for it (@ref-ds-auth), but the allocation passes two RAKF
checks of its own (@ref-ds-create-rakf). The body is a JSON object. mvsMF finds the fields by
a plain text search for the name of the field: a field name inside a string
value can be found by mistake, and a numeric field must be a number, not a
string. When mvsMF reads the body from the connection, it takes at most 4095
bytes of it.

#tab(caption: [Fields of the create body])[
  #table(columns: (0.95in, 0.7in, 1fr),
    [Field], [Type], [Meaning],
    [#cmd("dsorg")], [string], [The organization, for example #cmd("PS") or #cmd("PO"). Required without #cmd("like"). mvsMF keeps at most 7 characters.],
    [#cmd("recfm")], [string], [The record format, for example #cmd("FB"). Required without #cmd("like"). mvsMF keeps at most 7 characters.],
    [#cmd("lrecl")], [number], [Required without #cmd("like").],
    [#cmd("blksize")], [number], [Required without #cmd("like").],
    [#cmd("primary")], [number], [The primary quantity. Required without #cmd("like").],
    [#cmd("secondary")], [number], [The secondary quantity. Default 0.],
    [#cmd("dirblk")], [number], [The directory blocks. Default 0. With #cmd("like") and a target of organization #cmd("PO"), the default is 20. The target is #cmd("PO") when the body gives #cmd("dsorg") with the value #cmd("PO"), or, when the body gives no #cmd("dsorg"), when the model is partitioned.],
    [#cmd("alcunit")], [string], [The space unit. Default #cmd("TRK"). Folded to upper case, at most 7 characters. mvsMF passes the value on and does not check it.],
    [#cmd("like")], [string], [The name of a cataloged data set that serves as a model. The other fields are then overrides and none is required.],
  )
]

Other fields are not read. With #cmd("like"), the data set takes the
attributes of the model and the fields override them. When the body has no
#cmd("primary"), the primary quantity comes from the extents of the model, in
tracks over all extents of the model, and the unit is then #cmd("TRK"). A
secondary quantity that the body does not give is derived in the same way, but
only when the unit in force is #cmd("TRK"). With #cmd("like"), a primary
quantity that is still 0 or less becomes 1.

If mvsMF cannot read the extents of the model, it derives no space. The
request is not refused: the allocation uses the quantities and the unit of the
body, and for a primary quantity that the body does not give, 1 in the unit in force. The new
data set can then be much smaller than the model. A client that needs the size
of the model sends #cmd("primary") and #cmd("secondary") itself.

mvsMF builds one allocation request from the fields:
#cmd("DSN=name;DISP=(NEW,CATLG,DELETE)"), then #cmd("DCBDSN=") for a model, the
attributes that were given, and #cmd("SPACE=unit(primary,secondary,dirblk)").

#tab(caption: [Statuses of the create request])[
  #table(columns: (0.6in, 0.5in, 1fr),
    [Status], [Reason], [Cause],
    [201], [], [The data set is allocated and cataloged. Content type #cmd("application/json"), no body, no #cmd("Content-Length") (chunked).],
    [400], [3], [#cmd("Invalid or missing allocation parameters"): the body is empty, a required field is missing or is not of the right type, or the name of the model is too long. A name of the new data set that is too long gives reason 1.],
    [404], [4], [The model of #cmd("like") is not cataloged: #cmd("Dataset not found").],
    [500], [7], [Category 8, rc 900: #cmd("Dynamic allocation Error"). The allocation failed.],
  )
]

The last report covers every failure of the allocation. It does not tell a
refusal by RAKF, a lack of space, and any other cause apart. The failure writes
no operator message.

=== The Two RAKF Checks of a Create <ref-ds-create-rakf>

#idx("create", "RAKF checks")#idx("master catalog")#idx("catalog alias")
mvsMF makes the security check of the data set class for a create through the
dynamic allocation, not through a call of its own. Two checks apply, in this
order.

#tab(caption: [The checks of a create])[
  #table(columns: (0.4in, 1fr),
    [Step], [Check],
    [1], [The #cmd("DATASET") resource of the new name. RAKF permits a name whose first qualifier is the ID of the user. Under any other first qualifier the user needs ALTER access through a profile.],
    [2], [When the first qualifier of the name has no catalog alias, so that the data set is cataloged in the master catalog: UPDATE access to the master catalog, the #cmd("DATASET") resource #cmd("SYS1.VSAM.MASTER.CAT").],
  )
]

A refusal of either check, and any other failure of the allocation, has the same
answer: #cmd("500") with the report #cmd("{\"rc\":900,\"category\":8,\"reason\":7,\"message\":\"Dynamic allocation Error\"}").
The answer does not say which check refused. The security product records the
refusal in its own log. The profiles are described in “Setting Up Security” in
the _mvsMF User's Guide_.

== Delete a Data Set or a Member <ref-ds-delete>

#idx("delete", "data set")#idx("delete", "member")#idx("scratch")
#cmd("DELETE /zosmf/restfiles/ds/{dataset-name}")

#cmd("DELETE /zosmf/restfiles/ds/{dataset-name}({member-name})")

A data set delete needs ALTER access to the data set. A member delete needs
UPDATE access to the library. The check comes first. For a data set, mvsMF then
looks the name up in the catalog (#cmd("404"), reason 4) and removes it. For a
member, mvsMF opens the member (#cmd("404"), reason 5,
#cmd("PDS member not found")) and removes the entry from the directory. The open
fails, and so the answer is the same, for every cause: a missing member, a
library that does not exist, or a library that cannot be opened. The
success is #cmd("204") with the content type #cmd("application/json") and no
body. A removal that fails answers #cmd("500") (category 6, rc 8, reason 11,
#cmd("Dataset delete failed")) and writes #cmd("MVSMF103E").

== Rename a Data Set or a Member <ref-ds-rename>

#idx("rename")#idx("rename request")
#cmd("PUT /zosmf/restfiles/ds/{new-dataset-name}")

#cmd("PUT /zosmf/restfiles/ds/{dataset-name}({new-member-name})")

A PUT whose #cmd("Content-Type") contains #cmd("application/json") is a rename
request, whatever the body is. A body of 16,777,216 bytes or more answers #cmd("413")
(category 6, rc 8, reason 0, #cmd("The request body is too large")). A storage
shortage while mvsMF reads the body answers #cmd("500") (category 7, rc 16,
reason 0, #cmd("Storage for the request body could not be obtained")).

#tab(caption: [Fields of the rename body])[
  #table(columns: (1.6in, 1fr),
    [Field], [Meaning],
    [#cmd("request")], [Must be #cmd("rename"). Any other value gives #cmd("400"), reason 6, #cmd("Unsupported request; only 'rename' is supported").],
    [#cmd("from-dataset") with #cmd("dsn")], [Data set rename: the old name. The URL names the new name.],
    [#cmd("from-dataset") with #cmd("member")], [Member rename: the old member name. The URL names the new member in the library of the URL. The #cmd("dsn") of the body is not read.],
  )
]

A body without the field that the form needs, or with a name that is too long,
answers #cmd("400") with reason 6. A data set rename needs ALTER access to both
names, checked before the catalog. A member rename needs UPDATE access to the
library.

#tab(caption: [Statuses of the rename request])[
  #table(columns: (0.6in, 0.5in, 1fr),
    [Status], [Reason], [Cause],
    [204], [], [The name is changed. No body.],
    [404], [4], [Data set rename: the old name is not cataloged.],
    [404], [5], [Member rename: the old member does not exist.],
    [400], [7], [Member rename: the new member exists: #cmd("Rename target already exists").],
    [500], [8], [Any other failure: #cmd("Rename operation failed"). Writes #cmd("MVSMF104E") for a data set and #cmd("MVSMF105E") for a member.],
  )
]

== Authorization <ref-ds-auth>

#idx("authorization", "data sets")#idx("RAKF")#idx("DATASET class")
mvsMF asks the security product through HTTPD for the class #cmd("DATASET"),
with the folded name of the data set. For a member, the name is the library.
The check comes before the catalog lookup, so the answer does not tell whether a
data set exists.

#tab(caption: [Access needed])[
  #table(columns: (1.1in, 1fr),
    [Access], [Requests],
    [READ], [Read a data set\; read a member\; list the members.],
    [UPDATE], [Write a data set\; write a member\; rename a member\; delete a member.],
    [ALTER], [Delete a data set\; rename a data set (the old and the new name).],
    [none], [List data sets\; create a data set. mvsMF asks nothing. The allocation of a create passes two RAKF checks: the new name, then UPDATE on the master catalog when the first qualifier has no catalog alias (@ref-ds-create-rakf).],
  )
]

A name that no profile covers is permitted. The profiles themselves are
described in “Setting Up Security” in the _mvsMF User's Guide_.

=== A Refusal <ref-ds-denied>

A refusal is #cmd("500"), not #cmd("403"). The report is category 4, rc 8,
reason 0, with the message #cmd("LMOPEN error") and one detail:
#cmd("Authorization failed - You may not use this protected data set."). When the
refusal comes as an abend S913 from the open, the detail ends with
#cmd("Open 913 abend.").

== Error Reports <ref-ds-err>

#idx("error report")#idx("category")#idx("reason code")
An error report is a JSON object with the numbers #cmd("rc"), #cmd("category")
and #cmd("reason"), the string #cmd("message"), and sometimes the array
#cmd("details") of strings. The table lists every report of this chapter. The
column "Cat/rc" gives category and rc.

#tab(caption: [Error reports of the data set services])[
  #table(columns: (0.5in, 0.5in, 0.55in, 1.85in, 1fr),
    [Status], [Cat/rc], [Reason], [Message], [Cause],
    [400], [6/8], [1], [#cmd("Dataset is a partitioned dataset (PDS). Use /ds/{dataset-name}({member-name}) to access members")], [A sequential request for a PDS.],
    [400], [6/8], [1], [#cmd("Dataset is not partitioned (use the dataset endpoint instead)")], [A member request for a data set that is not a PDS.],
    [400], [6/8], [1], [#cmd("Dataset name is too long"), #cmd("Member name is too long"), #cmd("Dataset level is too long")], [A name over the limit (@ref-ds-names).],
    [400], [6/8], [1], [#cmd("Missing Content-Length or Transfer-Encoding header")], [A write with neither header.],
    [400], [6/8], [3], [#cmd("Invalid or missing allocation parameters")], [@ref-ds-create.],
    [400], [6/8], [12], [#cmd("Record mode (X-IBM-Data-Type: record) is not supported for RECFM=V data sets")], [A record read of a V, VB or VBS data set or member (@ref-ds-record).],
    [400], [6/8], [6], [#cmd("Unsupported request; only 'rename' is supported")], [@ref-ds-rename.],
    [400], [6/8], [7], [#cmd("Rename target already exists")], [A member rename.],
    [400], [6/8], [9], [#cmd("Member pattern is too long")], [The member list.],
    [401], [none], [none], [no body], [HTTPD has not resolved a user.],
    [404], [6/8], [4], [#cmd("Dataset not found")], [The data set is not cataloged, or the model of a create.],
    [404], [6/8], [5], [#cmd("PDS member not found")], [The library has no such member.],
    [404], [7/8], [4], [#cmd("Dataset not found")], [The directory for a member list could not be opened.],
    [404], [6/4], [7], [#cmd("Not Found")], [No route (@ref-ds-sum).],
    [412], [6/8], [10], [#cmd("The resource was modified since the supplied ETag was created")], [@ref-ds-etag.],
    [413], [6/8], [0], [#cmd("The request body is too large")], [A rename body of 16,777,216 bytes or more.],
    [500], [4/8], [0], [#cmd("LMOPEN error")], [A refusal (@ref-ds-denied).],
    [500], [6/8], [2], [#cmd("Memory allocation failed")], [A read or write could not get storage.],
    [500], [6/8], [3], [various (@ref-ds-write)], [An I/O error, a cut record, a data set with record length 0.],
    [500], [6/8], [8], [#cmd("Rename operation failed")], [@ref-ds-rename.],
    [500], [6/8], [11], [#cmd("Dataset delete failed")], [@ref-ds-delete.],
    [500], [6/8], [99], [#cmd("Internal server error (abend Sxxx)")], [An abend in the service.],
    [500], [7/16], [0], [#cmd("Storage for the list could not be obtained")], [The data set list or the diagnosis of a failed open found no storage.],
    [500], [7/16], [0], [#cmd("Storage for the request body could not be obtained")], [A rename body found no storage.],
    [500], [8/900], [7], [#cmd("Dynamic allocation Error")], [A failed create.],
    [500], [16/121], [-1037303780], [#cmd("iconv_open() failed.")], [An encoding that is not supported (@ref-ds-type).],
  )
]

== Operator Messages <ref-ds-msgs>

#idx("messages", "data set services")#idx("MVSMF006E")#idx("MVSMF101E")
#idx("MVSMF103E")#idx("MVSMF104E")#idx("MVSMF105E")#idx("MVSMF106E")#idx("MVSMF107E")
The data set services write these messages to the console. The text of each
message is in @apx-messages.

#tab(caption: [Messages of the data set services])[
  #table(columns: (1.0in, 1fr),
    [Message], [When],
    [#cmd("MVSMF006E")], [No storage for the data set list, or for the check of a failed open.],
    [#cmd("MVSMF101E")], [The open of a data set or member for output failed.],
    [#cmd("MVSMF103E")], [A delete failed.],
    [#cmd("MVSMF104E")], [A data set rename failed.],
    [#cmd("MVSMF105E")], [A member rename failed.],
    [#cmd("MVSMF106E")], [An I/O error while a data set was read.],
    [#cmd("MVSMF107E")], [A data set filled up during a write\; records were lost.],
  )
]

A fault of the client (a wrong name, a missing data set, a refusal) writes no
message.
