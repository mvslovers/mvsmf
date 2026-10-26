#import "../bookmaster/bookmaster.typ": *

= File Services <ref-uss>

#idx("restfiles/fs")#idx("UFS")#idx("file services")
This chapter lists the endpoints of the file services of mvsMF (mvsmf): the
requests under #cmd("/zosmf/restfiles/fs") that list a directory, read, write,
create and delete files and directories in the UFS of UFSD (ufsd), and the
utility request #cmd("chtag"). The _mvsMF User's Guide_ (chapter "Working with
Files in UFS") shows the tasks with sessions. Authentication and the general
conventions of requests and error reports are in @ref-auth and @ref-conv. The
data set services have their own chapter, @ref-ds.

The text describes mvsMF 1.4.0. The file services need UFSD (mvsMF is built against UFSD 1.4.0) and
HTTPD 4.2.0 or later.

== Endpoints <ref-uss-summary>

#tab(caption: [Endpoints of the file services])[
  #table(columns: (0.8in, 2.1in, 1fr),
    [Method], [Path], [Function],
    [GET], [#cmd("/zosmf/restfiles/fs")], [List a directory (@ref-uss-list).],
    [GET], [#cmd("/zosmf/restfiles/fs/{*filepath}")], [Read a file (@ref-uss-read).],
    [PUT], [#cmd("/zosmf/restfiles/fs/{*filepath}")], [Write or replace a file (@ref-uss-write). With the content type #cmd("application/json"): a utility request (@ref-uss-chtag).],
    [POST], [#cmd("/zosmf/restfiles/fs/{*filepath}")], [Create a file or a directory (@ref-uss-create).],
    [DELETE], [#cmd("/zosmf/restfiles/fs/{*filepath}")], [Delete a file or a directory (@ref-uss-delete).],
  )
]

Every other method on these paths gets the status 405 and the error report with
#cmd("rc") 4, #cmd("category") 6 and #cmd("reason") 7. The message names the
method: #cmd("Http method PATCH is not supported by this URL"). A request whose
method mvsMF cannot parse gets a 405 without a body (@ref-conv-methods).

== Paths <ref-uss-path>

#idx("path", "UFS")
The path of a file or a directory is absolute. In the URL of the single-file
endpoints, the path follows the service path: for #cmd("/tmp/a.txt") the URL
is #cmd("/zosmf/restfiles/fs/tmp/a.txt"). HTTPD decodes the URL once (@ref-conv-path). mvsMF takes the part
after #cmd("/zosmf/restfiles/fs/") and puts a slash in front of it. A literal
percent sign in a name is sent as #cmd("%25"), and a literal plus sign as
#cmd("%2B"). The listing
takes the path in the query parameter #cmd("path").

#tab(caption: [Rules for paths])[
  #table(columns: (2.1in, 1fr),
    [Rule], [Effect],
    [Empty file path on a single-file endpoint], [400, category 2, message #cmd("Missing file path").],
    [More than 254 characters after #cmd("/zosmf/restfiles/fs/")], [400, category 2, message #cmd("Path name too long").],
    [Name of a file or directory], [At most 59 characters.],
  )
]

== Headers of the Answers <ref-uss-headers>

Every answer of the file services, a success or an error report, carries the
headers #cmd("Cache-Control: no-store"), #cmd("Pragma: no-cache"),
#cmd("X-Content-Type-Options: nosniff") and #cmd("Content-Language: en"), and
for a session the session cookie (see @ref-auth). The sections below name the
other headers of each answer.

The framing depends on the request. A listing and a read are sent in chunks and
have no #cmd("Content-Length"). The success of a create (201), of a delete (204)
and of a change or removal of a tag (200) has #cmd("Content-Length: 0") and no
#cmd("Content-Type"). The success of a write (204) has neither
#cmd("Content-Length") nor #cmd("Content-Type"). The answer 304 has no body and
carries the header #cmd("ETag"). An error report has the content type
#cmd("application/json") and a #cmd("Content-Length").

== List a Directory <ref-uss-list>

#idx("directory", "list")#idx("X-IBM-Max-Items")#idx("moreRows")
#cmd("GET /zosmf/restfiles/fs?path=PATH")

#tab(caption: [Request of the listing])[
  #table(columns: (1.6in, 1fr),
    [Element], [Meaning],
    [Query parameter #cmd("path")], [Required. The absolute path of a directory or a file. Missing or empty: 400, category 2, message #cmd("Missing required query parameter 'path'").],
    [Header #cmd("X-IBM-Max-Items")], [The most items to return. The default is 1000. The value 0 means all. The text is converted as a number, and a text that is no number counts as 0, which means all.],
  )
]

*A directory.* The answer is 200 with the content type
#cmd("application/json"). mvsMF sends the body while it reads the directory.
The entries #cmd(".") and #cmd("..") are left out. The order is the order of the
directory.

#tab(caption: [Fields of the listing])[
  #table(columns: (1.6in, 1fr),
    [Field], [Content],
    [#cmd("items")], [Array. One object for each returned entry; empty for an empty directory (the status is still 200).],
    [#cmd("items[].name")], [The name of the entry, without the path.],
    [#cmd("items[].mode")], [A string of ten characters: #cmd("d") for a directory, otherwise #cmd("-"), then nine characters #cmd("rwx") or #cmd("-") for the owner, group and others, from the mode bits of the entry.],
    [#cmd("items[].size")], [The size in bytes, a number.],
    [#cmd("items[].user")], [The owner of the entry, a string.],
    [#cmd("items[].group")], [The group of the entry, a string.],
    [#cmd("items[].links")], [The link count, a number.],
    [#cmd("items[].mtime")], [The time of the last change in UTC, #cmd("YYYY-MM-DDTHH:MM:SSZ").],
    [#cmd("items[].inode")], [The inode number, a number.],
    [#cmd("returnedRows")], [The number of objects in #cmd("items").],
    [#cmd("totalRows")], [The number of entries of the directory, without #cmd(".") and #cmd(".."), also when the limit cut the list.],
    [#cmd("moreRows")], [The value #cmd("true"), present only when the limit cut the list. The status stays 200; mvsMF sends no 206.],
    [#cmd("JSONversion")], [The number 1.],
  )
]

*A file.* When #cmd("path") cannot be opened as a directory, mvsMF looks for it
as an entry of its parent directory. A file found gives 200 with one item with
the same fields. Its #cmd("name") is the whole path as sent. The counts
#cmd("returnedRows") and #cmd("totalRows") are 1, and there is no
#cmd("moreRows").

#tab(caption: [Errors of the listing for a path that is not a directory])[
  #table(columns: (2.4in, 1fr),
    [Condition], [Answer],
    [#cmd("path") has no slash, or ends in a slash], [404, category 6, #cmd("Path not found").],
    [The parent directory cannot be opened], [404, category 6, #cmd("Path not found").],
    [The parent exists and has no such entry], [404, category 6, #cmd("File not found").],
    [The path of the parent has 256 characters or more], [400, category 2, #cmd("Path too long").],
    [The name has 60 characters or more], [400, category 2, #cmd("Filename too long").],
  )
]

== Read a File <ref-uss-read>

#idx("file", "read")#idx("GET")#idx("X-IBM-Return-Etag")#idx("If-None-Match")
#cmd("GET /zosmf/restfiles/fs/{*filepath}")

#tab(caption: [Request headers of the read])[
  #table(columns: (1.6in, 1fr),
    [Header], [Meaning],
    [#cmd("X-IBM-Data-Type")], [Text or binary, and the code page of a text (@ref-uss-datatype). Default: text, IBM-1047.],
    [#cmd("X-IBM-Return-Etag")], [With the value #cmd("true") (case does not matter, blanks around it are ignored) mvsMF returns the ETag in the answer (@ref-uss-etag).],
    [#cmd("If-None-Match")], [One or more ETags. When one matches the file, the answer is 304 (@ref-uss-etag).],
  )
]

The answer is 200. The body is the content of the file. mvsMF reads it in
pieces of 4096 bytes and sends it chunked, so the answer has no
#cmd("Content-Length"). The content type is #cmd("text/plain") for a text and
#cmd("application/octet-stream") for #cmd("binary"). In text mode, each piece
is translated from the code page of the file to ASCII. In binary mode the bytes
are sent as they are. The header #cmd("ETag") is present when the request asked
for it and the file could be read for the checksum.

The data type is checked before the file is opened. A path that does not exist
gives 404, and a path that is a directory gives 400 with the message
#cmd("Is a directory") (@ref-uss-errors).

When a read fails after the headers went out, mvsMF writes #cmd("MVSMF301E")
(@ref-uss-msgs) and closes the connection in the middle of the body. It sends no
final chunk and no error report. The bytes read before the failure were sent
already. A client sees a failed transfer: curl exits with 18 (#cmd("transfer
closed with outstanding read data remaining")). The loop ends as a failure when
UFSD reports an error on the file, and also when it ends without UFSD having
reported the end of the file. A failed open is answered with an error report as in
@ref-uss-errors, because the headers are not out yet.

== Write a File <ref-uss-write>

#idx("file", "write")#idx("PUT")#idx("truncate")
#cmd("PUT /zosmf/restfiles/fs/{*filepath}")

The request makes the file or replaces the content of a file that exists. The
body is the new content.

#tab(caption: [Request of the write])[
  #table(columns: (1.6in, 1fr),
    [Element], [Meaning],
    [Header #cmd("Content-Type")], [A value that contains the text #cmd("application/json") (case matters) makes the request a utility request (@ref-uss-chtag). Any other value, or none, is a write.],
    [Header #cmd("X-IBM-Data-Type")], [@ref-uss-datatype. Default: text, IBM-1047.],
    [Header #cmd("If-Match")], [One or more ETags. The write happens only when the ETag of the file matches (@ref-uss-etag).],
    [Header #cmd("X-IBM-Return-Etag")], [With #cmd("true"), the answer carries the ETag of the new content.],
    [Body], [The content, as bytes. It may be empty. mvsMF reads it by #cmd("Content-Length") or as chunks.],
  )
]

The steps, in this order:

+ mvsMF checks the data type. A wrong value ends the request here.
+ mvsMF reads the body. A body that cannot be read gives 400, category 2,
  #cmd("Failed to read request body"). A body of 16,777,216 bytes (16 MiB) or
  more gives the answer in @ref-uss-body.
+ A text body is translated from ASCII to the code page of the file, byte by
  byte (@ref-uss-datatype).
+ An #cmd("If-Match") header is compared with the ETag of the file. A mismatch
  ends the request here.
+ mvsMF opens the file for output. That makes the file, or empties a file that
  exists. A new file belongs to the user of the request; a file that exists
  keeps its owner.
+ mvsMF writes the body and closes the file.

The answer is 204 without a body. With #cmd("X-IBM-Return-Etag: true") it has the
header #cmd("ETag"), computed from the file as it was closed.

The first four steps leave the file as it was. When the open of step 5
succeeds, the old content is gone. A failure after that leaves the file empty or
partly written. A write that fails because the file reaches its size limit
(@ref-uss-limits) keeps the bytes that fitted. A write that stops short without
a reason from UFSD gives 500, category 10, #cmd("Incomplete write to file").

== Utility Requests: chtag <ref-uss-chtag>

#idx("chtag")#idx("utilities")
#cmd("PUT /zosmf/restfiles/fs/{*filepath}") with a #cmd("Content-Type") that
contains #cmd("application/json")

The body is JSON. The field #cmd("request") names the utility; the only one is
#cmd("chtag"). UFSD has no tags for files, so the utility changes nothing, and
the file need not exist.

#tab(caption: [Request and answers of chtag])[
  #table(columns: (2.1in, 1fr),
    [Request], [Answer],
    [#cmd("request") is #cmd("chtag"), #cmd("action") is #cmd("list")], [200, content type #cmd("application/json"), body #cmd("{\"stdout\":[\"- untagged    T=off PATH\"]}"), where PATH is the absolute path of the request.],
    [#cmd("action") is #cmd("set") or #cmd("remove")], [200 without a body. Nothing is tagged.],
    [Another value of #cmd("action")], [400, category 2, #cmd("Invalid chtag action").],
    [No string #cmd("action")], [400, category 2, #cmd("Missing or invalid 'action' in chtag request").],
    [Another value of #cmd("request")], [400, category 2, #cmd("Unsupported utility request").],
    [No string #cmd("request")], [400, category 2, #cmd("Missing or invalid 'request' in JSON body").],
    [No body, or a body that cannot be read], [400, category 2, #cmd("Failed to read request body").],
  )
]

mvsMF finds the fields of the body by a plain search for a string value of
that name. It does not parse JSON in full.

== Create a File or a Directory <ref-uss-create>

#idx("file", "create")#idx("directory", "create")#idx("mkdir")#idx("POST")#idx("mode")
#cmd("POST /zosmf/restfiles/fs/{*filepath}")

The body is JSON.

#tab(caption: [Body of the create request])[
  #table(columns: (0.8in, 1fr),
    [Field], [Meaning],
    [#cmd("type")], [Required. #cmd("file"), #cmd("directory") or #cmd("dir"); the last two mean the same.],
    [#cmd("mode")], [Optional. Nine characters of #cmd("r"), #cmd("w"), #cmd("x") and #cmd("-"), as in #cmd("rwxr-xr-x"). Any character but #cmd("-") counts as a set bit. A value of another length, and a value of nine #cmd("-"), is ignored. mvsMF passes the mode to UFSD, which does not use it: a new file gets #cmd("rw-r--r--") and a new directory #cmd("rwxr-xr-x") in every case.],
  )
]

The answer is 201 without a body. mvsMF checks the target first: an existing
file or directory gives 400, category 4,
#cmd("File or directory already exists"). A missing parent directory gives 404,
category 6 (@ref-uss-errors). A new file is empty. A request with #cmd("type")
#cmd("file") for a path that is a directory gives 400, category 2,
#cmd("Is a directory").

#tab(caption: [Errors of the create request])[
  #table(columns: (2.1in, 1fr),
    [Condition], [Answer],
    [No body, or an empty body], [400, category 2, #cmd("Failed to read request body").],
    [No string #cmd("type")], [400, category 2, #cmd("Missing or invalid 'type' in request body").],
    [Another value of #cmd("type")], [400, category 2, #cmd("Invalid 'type': must be 'file', 'directory', or 'dir'").],
  )
]

== Delete a File or a Directory <ref-uss-delete>

#idx("file", "delete")#idx("directory", "delete")#idx("recursive delete")#idx("X-IBM-Option")#idx("DELETE")
#cmd("DELETE /zosmf/restfiles/fs/{*filepath}")

#tab(caption: [Request of the delete])[
  #table(columns: (1.6in, 1fr),
    [Header], [Meaning],
    [#cmd("X-IBM-Option")], [With the value #cmd("recursive") (exactly, in lower case) a directory is deleted with everything in it. Any other value, or none, deletes a file or an empty directory.],
  )
]

mvsMF removes the path as a file first. When the path is a directory, mvsMF
removes it as a directory, or with its content when the header says so. The
answer is 204 without a body.

- A directory with entries and no header: 400, category 4,
  #cmd("Directory not empty").
- A path that does not exist: 404, category 6,
  #cmd("File or directory not found").
- The recursive delete removes the files and directories one by one, the
  content of a directory before the directory. When one removal fails, the
  delete stops with the error of UFSD, and what it removed before stays
  removed. There is no undo.
- #cmd("If-Match") has no effect on a delete.

== X-IBM-Data-Type <ref-uss-datatype>

#idx("X-IBM-Data-Type")#idx("IBM-1047")#idx("IBM-037")#idx("binary")#idx("fileEncoding")
The header selects the transfer type on GET and PUT. The part before the first
semicolon is the type; case does not matter. #cmd("binary") is binary,
#cmd("record") is refused, and every other text, including an empty one, is
text. The parameter #cmd("fileEncoding=") (case does not matter) follows after
a semicolon. No blank is removed from the value.

#tab(caption: [Values of X-IBM-Data-Type])[
  #table(columns: (2.3in, 1fr),
    [Value], [Effect],
    [No header, or #cmd("text")], [Text, IBM-1047.],
    [#cmd("text;fileEncoding=IBM-1047") or #cmd("text;fileEncoding=1047")], [Text, IBM-1047.],
    [#cmd("text;fileEncoding=IBM-037") or #cmd("text;fileEncoding=037")], [Text, IBM-037.],
    [#cmd("text;fileEncoding=") with no value, or another parameter], [Text, IBM-1047.],
    [#cmd("text;fileEncoding=OTHER")], [Error, see below. This includes #cmd("IBM-37") and #cmd("CP037").],
    [#cmd("binary"), with or without a parameter], [Binary. No translation; the code page is not used.],
    [#cmd("record"), with or without a parameter], [400, category 1, rc 4, reason 12, message #cmd("X-IBM-Data-Type"), details #cmd("[\"record\"]").],
  )
]

An unsupported code page gives 500, category 16, rc 121, reason
-1037303780, message #cmd("iconv_open() failed."), with one detail:
#cmd("Unsupported encoding in X-IBM-Data-Type 'VALUE': IBM-037 and IBM-1047 are supported."),
where VALUE is the value sent, cut after 64 characters. The accepted names are
#cmd("IBM-037"), #cmd("037"), #cmd("IBM-1047") and #cmd("1047"), in any case.

In text mode, mvsMF translates every byte of the body with a table of 256
entries: on PUT from ASCII to the EBCDIC code page, on GET back. It does not
decode UTF-8, so a UTF-8 sequence is translated byte by byte. The bytes
#cmd("0A") and #cmd("85") both become the EBCDIC line end #cmd("15"); the EBCDIC
bytes #cmd("15") and #cmd("25") become #cmd("0A") and #cmd("85"). The byte
#cmd("0D") stays #cmd("0D").

#note[*A defect* (mvsmf\#234): a UTF-8 character with the byte #cmd("85"), for
example #cmd("C3 85"), changes into a line end in a text transfer.]

From ASCII (Latin-1) to EBCDIC, the tables of IBM-1047 and IBM-037 assign
different bytes to six characters, listed below. For all other bytes they
agree in this direction. From EBCDIC to ASCII they differ in the same six places
and in one more: the EBCDIC byte #cmd("E1") becomes #cmd("B2") under IBM-1047
and #cmd("F7") under IBM-037.

#tab(caption: [Characters with different bytes])[
  #table(columns: (1.15in, 1fr, 1fr, 1fr),
    [Character], [Latin-1], [IBM-1047], [IBM-037],
    [#cmd("[")], [5B], [AD], [BA],
    [#cmd("]")], [5D], [BD], [BB],
    [#cmd("^")], [5E], [5F], [B0],
    [#cmd("¨")], [A8], [BB], [BD],
    [#cmd("¬")], [AC], [B0], [5F],
    [#cmd("Ý")], [DD], [BA], [AD],
  )
]

A file that is read with another code page than the one it was written with
returns the bytes of this table exchanged, without an error. The Latin-1 byte
#cmd("F7") is stored as #cmd("E1") by both tables, so under IBM-1047 it is read
back as #cmd("B2"): a transfer through IBM-1047 does not return #cmd("F7")
unchanged.

== ETag and Conditional Requests <ref-uss-etag>

#idx("ETag")#idx("If-Match")#idx("If-None-Match")#idx("412")#idx("304")
The ETag of a file is a CRC-32 checksum of the stored bytes followed by the
number of bytes, both as eight uppercase hexadecimal digits: sixteen digits in
all. The stored bytes are hashed as they are, without translation, so a text
read and a binary read of one file give the same ETag. mvsMF sends the ETag
without quotes. Computing it reads the whole file once more.

#tab(caption: [ETag on the file services])[
  #table(columns: (2.1in, 1fr),
    [Request], [Behaviour],
    [GET with #cmd("X-IBM-Return-Etag: true") or #cmd("If-None-Match")], [mvsMF computes the ETag. An #cmd("If-None-Match") that matches gives 304 with the header #cmd("ETag") and no body. Otherwise the answer is 200 and carries the ETag. A GET with neither header has no ETag.],
    [GET of a file that cannot be read for the checksum], [No ETag; the open then gives the UFSD error (a directory: 400 #cmd("Is a directory")).],
    [PUT with #cmd("If-Match")], [mvsMF compares before it opens the file for output. No match: 412, category 4, rc 8, reason 1, message #cmd("The resource was modified since the supplied ETag was created"). The file stays as it is.],
    [PUT with #cmd("If-Match") for a file that does not exist or cannot be read], [412, also for #cmd("If-Match: *").],
    [PUT with #cmd("If-Match") for a directory], [The condition is not tested; the answer is the one of a write to a directory, 400 #cmd("Is a directory").],
    [PUT with #cmd("X-IBM-Return-Etag: true")], [204 with the header #cmd("ETag") of the file as closed.],
    [POST, DELETE], [#cmd("If-Match") and #cmd("If-None-Match") are not evaluated.],
  )
]

A header can hold several ETags separated by commas. An ETag may carry quotes,
the prefix #cmd("W/") and blanks around it. The value #cmd("*") matches any
file that can be read. The letters #cmd("A") to #cmd("F") match in either case.
The header #cmd("X-IBM-Return-Etag") accepts #cmd("true") in any case.

== Limits <ref-uss-limits>

#idx("file size")#idx("maximum file size")#idx("limits")
#tab(caption: [Limits of the file services])[
  #table(columns: (1.9in, 1fr),
    [Limit], [Value],
    [Size of a file], [(16 + B / 4) x B bytes for the block size B of the file system. For B = 4096: 4,259,840 bytes (4.0625 MiB). For B = 512: 73,728 bytes. For B = 8192: 16,908,288 bytes. A file has 16 direct blocks and one block of indirect addresses of 4 bytes each.],
    [Failure at the limit], [500, category 8, #cmd("No space left on device"). The same answer is given when the file system has no free block. The file keeps the bytes that fitted.],
    [Entries of a directory], [A directory uses 16 direct blocks, with 64 bytes for each entry, including #cmd(".") and #cmd(".."). For B = 4096: 1024 entries. Creating an entry in a full directory gives the same 500.],
    [Name of a file or directory], [59 characters.],
    [Path in the URL], [254 characters after #cmd("/zosmf/restfiles/fs/").],
    [Body of a request], [Less than 16,777,216 bytes (@ref-uss-body).],
    [Items of a listing], [1000, unless #cmd("X-IBM-Max-Items") says otherwise.],
  )
]

With a block size of 8192 bytes or more, the limit of the body is the lower
one.

== Errors of the Request Body <ref-uss-body>

#idx("413")#idx("request body")
The read of a body (a PUT, and a POST or chtag whose body HTTPD has not read
before) has two failures with an error report of their own:

#tab(caption: [Errors of the request body])[
  #table(columns: (0.8in, 1fr),
    [Status], [Error report],
    [413], [rc 8, category 6, reason 0, #cmd("The request body is too large"). The #cmd("Content-Length") is 16,777,216 or more, or the chunks of the body reach that size.],
    [500], [rc 16, category 7, reason 0, #cmd("Storage for the request body could not be obtained").],
  )
]

== UFSD Errors <ref-uss-errors>

#idx("error", "UFSD")#idx("error report")
A request that UFSD refuses answers with a JSON error report. The fields come in
the order #cmd("rc"), #cmd("category"), #cmd("reason"), #cmd("message"); an
array #cmd("details") follows when there is one. For these errors #cmd("rc") is
8 and #cmd("reason") is 1. The status, the category and the message follow the
return code of UFSD:

#tab(caption: [UFSD return codes])[
  #table(columns: (1.9in, 0.6in, 0.7in, 1fr),
    [UFSD return code], [Status], [Category], [Message],
    [28, file not found], [404], [6], [#cmd("File or directory not found")],
    [32, exists], [400], [4], [#cmd("File or directory already exists")],
    [36, not a directory], [400], [2], [#cmd("Not a directory")],
    [40, is a directory], [400], [2], [#cmd("Is a directory")],
    [44, no space], [500], [8], [#cmd("No space left on device")],
    [48, no inodes], [500], [8], [#cmd("No inodes available")],
    [52, I/O error], [500], [10], [#cmd("I/O error")],
    [56, bad file descriptor], [500], [10], [#cmd("Bad file descriptor")],
    [60, not empty], [400], [4], [#cmd("Directory not empty")],
    [64, name too long], [400], [2], [#cmd("Path name too long")],
    [68, read-only file system], [400], [4], [#cmd("Read-only file system")],
    [Any other, including 72 (no access)], [500], [10], [#cmd("Unknown UFSD error")],
  )
]

When the open of a read or a write fails and UFSD reports no code, mvsMF
answers as for 28. The create request has no such rule.

The table is for a request that fails before the answer starts. A read that
fails after the headers went out has no status to change (@ref-uss-read).

The status codes follow the closed list of z/OSMF. "Exists" and "not empty" are
therefore 400, and "no space" and "no inodes" are 500.

== The UFS Session <ref-uss-session>

#idx("UFSD", "session")#idx("503")#idx("session", "UFS")
Each connection of a client has one UFS session. mvsMF creates it on the first
request that needs it and never closes it; HTTPD closes it with the connection.
For each request, mvsMF sets the user ID and the group of the authenticated
user (up to 8 characters each) on the session before it calls UFSD.

When HTTPD has no UFS system, the answer is 503 with the error report #cmd("rc") 8,
#cmd("category") 1, #cmd("reason") 1 and the message
#cmd("UFSD subsystem not available"). HTTPD has none when its parameter
#cmd("UFS") is off, or when it could not create the system.

== Permissions <ref-uss-perm>

#idx("permissions", "UFS")#idx("OWNER")#idx("MODE")
UFSD checks a write at the level of the mount. A mount defined with
#cmd("MODE(RO)") refuses every change with the return code 68. UFSD mounts
read-only when the definition has no #cmd("MODE"). A mount with an
#cmd("OWNER()") that differs from the user of the request refuses with the return
code 72, which mvsMF answers as 500 #cmd("Unknown UFSD error")
(@ref-uss-errors). The check covers making and removing files and
directories, opening a file for output, and writing.

Reading a file and listing a directory are not checked. UFSD does not test the
mode bits and the owner of a file or directory, and the fields #cmd("mode"),
#cmd("user") and #cmd("group") of a listing report what the file system stores.
A new file belongs to the user and the group of the request.

== Operator Messages <ref-uss-msgs>

#idx("messages", "file services")#idx("MVSMF301E")
The file services write one message to the console. The text is in
@apx-messages.

#tab(caption: [Message of the file services])[
  #table(columns: (1.0in, 1fr),
    [Message], [When],
    [#cmd("MVSMF301E")], [A read of a file failed after the answer had started\; the body is short.],
  )
]

A fault of the client (a missing file, a refusal, a directory read as a file)
writes no message.
