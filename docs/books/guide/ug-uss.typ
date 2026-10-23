#import "../bookmaster/bookmaster.typ": *

= Working with Files in UFS <ug-uss>

#idx("UFS")#idx("files")#idx("directory")#idx("restfiles/fs")
Besides data sets, mvsMF (mvsmf) gives a client the files in the UFS, the Unix
file system of UFSD (ufsd). The files service lives under the path
#cmd("/zosmf/restfiles/fs"). A client lists a directory, reads and writes a
file, makes a file or a directory, and deletes either. This chapter goes
through these tasks, one session for each. The sessions run in order on one
system, and they depend on each other: the file #cmd("hello.txt") is written,
listed, read, replaced and deleted. The _mvsMF Reference_ (chapter "File
Services") lists every parameter, header, field, status code and error report.

== What mvsMF Needs from UFSD <ug-uss-ufsd>

#idx("UFSD")
mvsMF keeps no files of its own. Every request of this chapter goes to UFSD,
which must be running, and HTTPD must run with its UFS support on, which is
the default. When mvsMF cannot get a UFS session, every request of this
chapter answers 503 with the message #cmd("UFSD subsystem not available").
The data sets of @ug-data do not depend on UFSD.

== The URLs and the Demo Directory <ug-uss-urls>

#idx("path", "UFS")#idx("demo directory")
A file is named by its absolute path. The URL of the file is the service path
followed by that path. For the file #cmd("/tmp/mvsmf-demo/hello.txt") the URL is
#cmd("MVSMF_URL/zosmf/restfiles/fs/tmp/mvsmf-demo/hello.txt"). Listing a
directory is the exception: it names the directory in the query parameter
#cmd("path"), as in #cmd("MVSMF_URL/zosmf/restfiles/fs?path=/tmp/mvsmf-demo").

The sessions work in the directory #cmd("/tmp/mvsmf-demo"). Before the
sessions, #cmd("/tmp") must be a UFSD file system that is mounted for reading
and writing, and the user must be allowed to write to it
(@ug-uss-permissions). The sessions use curl with Basic authentication and
the variables #var("MVSMF_URL"), #var("MVSMF_USER") and #var("MVSMF_PASS").

== Making a Directory and a File <ug-uss-make>

#idx("directory", "create")#idx("file", "create")#idx("mkdir")#idx("POST")
A POST request makes a file or a directory. The body is JSON. The field
#cmd("type") is required, and it is #cmd("file"), #cmd("directory") or
#cmd("dir"). The first session makes the demo directory, with the optional
field #cmd("mode"):

#screen(raw(read("../ex/ug-uss/u-mkdir.txt"), block: true))

The answer is #cmd("201") and has no body. A directory is made in an existing
directory only: a request for #cmd("/tmp/mvsmf-demo/notes/more") before
#cmd("/tmp/mvsmf-demo/notes") exists answers 404. The next two sessions make a
directory inside the demo directory, and an empty file:

#screen(raw(read("../ex/ug-uss/u-mksub.txt"), block: true))
#screen(raw(read("../ex/ug-uss/u-mkfile.txt"), block: true))

#note[The field #cmd("mode") is accepted, and it has no effect. UFSD makes every
new file with the mode #cmd("rw-r--r--") and every new directory with
#cmd("rwxr-xr-x"). The listing in @ug-uss-list shows both.]

Making a file or directory that exists answers 400 (@ug-uss-errors).

== Writing a File <ug-uss-write>

#idx("file", "write")#idx("PUT")
A PUT request writes the file. It makes the file, or it replaces the content
of a file that exists. The body is the new content, and the answer is #cmd("204")
without a body:

#screen(raw(read("../ex/ug-uss/u-write.txt"), block: true))

The request replaces the whole content. An empty body empties the file. There is
no way to append. When the file exists, the request opens it for output
first, which truncates it. What happens when the request fails after that
point is in @ug-uss-errors. @ug-uss-etag shows how to refuse a write when
the file has changed meanwhile.

The sessions send the body with the curl option #cmd("--data-binary"), which
sends the data as it is.

A request with the header #cmd("Content-Type: application/json") does not write
the file. mvsMF treats it as a utility request (the _mvsMF Reference_
describes it). Send the body of a file with another content type, or without
one.

== Listing a Directory <ug-uss-list>

#idx("directory", "list")#idx("list")#idx("X-IBM-Max-Items")
A GET request on the service path with the query parameter #cmd("path") lists
the directory:

#screen(raw(read("../ex/ug-uss/u-list.txt"), block: true))

The answer is #cmd("200") with a JSON body. The object has the array
#cmd("items"), the counts #cmd("returnedRows") and #cmd("totalRows"), and
#cmd("JSONversion"). Each element of #cmd("items") describes one entry of the
directory, without the entries #cmd(".") and #cmd(".."):

#tab(caption: [Fields of a listed entry])[
  #table(columns: (1.15in, 1fr),
    [Field], [Content],
    [#cmd("name")], [The name of the entry.],
    [#cmd("mode")], [Ten characters: #cmd("d") for a directory or #cmd("-")
      for a file, then the permissions as three triples of #cmd("r"),
      #cmd("w"), #cmd("x") and #cmd("-").],
    [#cmd("size")], [The size in bytes.],
    [#cmd("user"), #cmd("group")], [The owner and the group of the entry.],
    [#cmd("links")], [The number of links.],
    [#cmd("mtime")], [The time of the last change in UTC, as
      #cmd("YYYY-MM-DDTHH:MM:SSZ").],
    [#cmd("inode")], [The inode number.],
  )
]

The order of the entries is the order of the directory. A directory without
entries answers #cmd("200") with an empty array.

The header #cmd("X-IBM-Max-Items") limits the number of entries. Without it the
limit is 1000. The value 0 means no limit. A listing that the limit cuts is still
a #cmd("200"). It carries #cmd("\"moreRows\": true"), and #cmd("totalRows")
holds the number of all entries:

#screen(raw(read("../ex/ug-uss/u-list-max.txt"), block: true))

When #cmd("path") names a file, the answer has one item, and its #cmd("name") is
the whole path:

#screen(raw(read("../ex/ug-uss/u-list-file.txt"), block: true))

A path that does not exist answers 404 (@ug-uss-errors). A request without
#cmd("path") answers 400.

== Reading a File <ug-uss-read>

#idx("file", "read")#idx("GET")#idx("chunked")
A GET request on the path of the file reads it:

#screen(raw(read("../ex/ug-uss/u-read.txt"), block: true))

The answer is #cmd("200") with the content type #cmd("text/plain"). mvsMF
sends the file in pieces (#cmd("Transfer-Encoding: chunked")), so the answer has
no #cmd("Content-Length"). By default the content is text: mvsMF translates
each byte from the code page of the file to ASCII, and the EBCDIC line end of
the file becomes a line feed. The next section is about that code page.

The header #cmd("X-IBM-Data-Type: binary") sends the bytes of the file as
they are, with the content type #cmd("application/octet-stream"). A client that
stores files of any kind needs it.

#note[*A defect* (mvsmf\#423): when UFSD fails while mvsMF reads the file, mvsMF
does not notice. The request ends as a normal #cmd("200") with a file that is
too short.]

A path that is a directory answers 400 with the message #cmd("Is a directory").

== IBM-1047 and IBM-037 <ug-uss-codepage>

#idx("IBM-1047")#idx("IBM-037")#idx("CP037")#idx("code page")#idx("X-IBM-Data-Type")
Text in UFS files is stored in the EBCDIC code page IBM-1047. Data sets
differ: mvsMF reads and writes them in IBM-037 unless the request says
otherwise (@ug-data). A request of this chapter that does not say otherwise
uses IBM-1047.

The two code pages assign different bytes to six characters. All other
characters have the same byte in both:

#tab(caption: [Characters that differ between IBM-1047 and IBM-037])[
  #table(columns: (1.15in, 1fr, 1fr, 1fr),
    [Character], [In Latin-1], [Byte in IBM-1047], [Byte in IBM-037],
    [#cmd("[")], [5B], [AD], [BA],
    [#cmd("]")], [5D], [BD], [BB],
    [#cmd("^")], [5E], [5F], [B0],
    [#cmd("¨")], [A8], [BB], [BD],
    [#cmd("¬")], [AC], [B0], [5F],
    [#cmd("Ý")], [DD], [BA], [AD],
  )
]

The exclamation mark does not differ: it is the byte 5A in both code pages.
The first three characters are the ones that program source needs. A file that
is written with one code page and read with the other is damaged without an
error: the answer is a #cmd("200") or a #cmd("204"), and the bytes are wrong.
The next sessions write a line of C with the default code page and look at the
stored bytes with #cmd("od"):

#screen(raw(read("../ex/ug-uss/u-trap-put.txt"), block: true))
#screen(raw(read("../ex/ug-uss/u-trap-stored.txt"), block: true))

The stored bytes are #cmd("81 AD F1 BD 40 7E 40 82 AD F2 BD 40 5F 40 83 15").
The last byte, #cmd("15"), is the line end of the EBCDIC file. Now the same
file is read as IBM-037. The header
#cmd("X-IBM-Data-Type: text;fileEncoding=IBM-037") asks for it:

#screen(raw(read("../ex/ug-uss/u-trap-as037.txt"), block: true))

The bytes of the answer are #cmd("61 dd 31 a8 20 3d 20 62 dd 32 a8 20 ac 20 63 0a").
The bytes #cmd("AD") and #cmd("BD") of the file became #cmd("Ý") and
#cmd("¨"), and #cmd("5F") became #cmd("¬"). The client got
#cmd("aÝ1¨ = bÝ2¨ ¬ c") instead of #cmd("a[1] = b[2] ^ c"). The reverse is the
same: a file that is written as IBM-037 and read with the default shows
#cmd("[") as #cmd("Ý"), and the other characters of the table change as well.

Use the same code page for the write and for the read. A client that must
write IBM-037 files, for a program that expects that code page, says so with the
header on both requests:

#screen(raw(read("../ex/ug-uss/u-put-037.txt"), block: true))
#screen(raw(read("../ex/ug-uss/u-read-037.txt"), block: true))
#screen(raw(read("../ex/ug-uss/u-stored-037.txt"), block: true))

The file now holds #cmd("81 BA F1 BB 40 7E 40 82 BA F2 BB 40 B0 40 83 15"), and
the read as IBM-037 returns the line that was written. The accepted values of
#cmd("fileEncoding") are #cmd("IBM-037"), #cmd("037"), #cmd("IBM-1047") and
#cmd("1047"). Any other value, for example #cmd("IBM-37"), is an error, and
mvsMF refuses the request before it changes the file.

mvsMF translates byte for byte, from the code page of the request to the one
of the file. It does not decode UTF-8. A character outside Latin-1 is not
translated as a character, and mvsMF does not report it.

#note[*A defect* (mvsmf\#234): the translation tables map the byte #cmd("85") to
the EBCDIC line end, as they do for the line feed. A UTF-8 character with the
byte #cmd("85") in it, for example #cmd("Å") (the bytes #cmd("C3 85")), turns
into a line end in a text file. This applies to the UFS as well. A client that
sends such characters sends them as #cmd("binary").]

== Replacing a File Only if It Is Unchanged <ug-uss-etag>

#idx("ETag")#idx("If-Match")#idx("X-IBM-Return-Etag")
Two clients that write the same file overwrite each other without notice. The
ETag prevents it. When a GET request has the header
#cmd("X-IBM-Return-Etag: true"), mvsMF reads the file once more and returns a
checksum in the header #cmd("ETag"):

#screen(raw(read("../ex/ug-uss/u-etag-get.txt"), block: true))

The value has sixteen hexadecimal digits. It comes from the content of the file
and its length. A PUT request with the header #cmd("If-Match") writes only when
the ETag of the file is the one given. The sessions below use the shell
variable #var("ETAG"). Set it to the value of the header before:

```
ETAG=<value of the ETag header>
```

#screen(raw(read("../ex/ug-uss/u-etag-put.txt"), block: true))

The file has changed, so the ETag that the client holds is stale now. The same
request answers 412 and does not touch the file:

#screen(raw(read("../ex/ug-uss/u-etag-stale.txt"), block: true))

mvsMF checks the ETag before it opens the file for writing. The check
applies to PUT. POST and DELETE ignore #cmd("If-Match"). A file that does not
exist never matches, also with #cmd("If-Match: *"): the answer is 412. When the
PUT carries the header #cmd("X-IBM-Return-Etag: true") as well, the answer
holds the ETag of the new content.

== Errors <ug-uss-errors>

#idx("error", "UFS")#idx("404")#idx("file size")#idx("maximum file size")
A request that fails answers with a JSON error report (see the _mvsMF
Reference_). The fields are #cmd("rc"), #cmd("category"), #cmd("reason") and
#cmd("message"). For the failures that UFSD reports, #cmd("rc") is 8 and
#cmd("reason") is 1. The status, the #cmd("category") and the
#cmd("message") depend on what UFSD reported.

*Not found.* A file or directory that does not exist answers 404:

#screen(raw(read("../ex/ug-uss/u-notfound.txt"), block: true))

The message is #cmd("File or directory not found") and the category is 6. A
missing directory in the path of a read, write, create or delete gives the
same answer.

*Exists.* A POST for a name that is taken answers 400 with the category 4 and
the message #cmd("File or directory already exists"):

#screen(raw(read("../ex/ug-uss/u-exists.txt"), block: true))

*Too large.* A file in UFSD has a size limit that comes from the block size of
the file system. With a block size of 4096 bytes a file holds at most 4,259,840
bytes, which is 4.0625 MiB. The _mvsMF Reference_ gives the formula. The session
writes 5,000,000 bytes. The empty header #cmd("Expect:") keeps curl from
sending #cmd("Expect: 100-continue"):

#screen(raw(read("../ex/ug-uss/u-toolarge.txt"), block: true))

mvsMF answers 500 with the category 8 and the message
#cmd("No space left on device"). UFSD gives the same answer when the file
system is full. The request has already truncated the file, so it leaves the
bytes that fitted before the limit:

#screen(raw(read("../ex/ug-uss/u-big-size.txt"), block: true))

The file #cmd("big.txt") exists now, with a size of at most 4,259,840 bytes. A
client that gets this error writes the file again or deletes it. The body of a
request has its own limit: mvsMF refuses a body of 16 MiB or more with a 413
before the request reaches UFSD.

== Deleting Files and Directories <ug-uss-delete>

#idx("file", "delete")#idx("directory", "delete")#idx("DELETE")#idx("recursive delete")#idx("X-IBM-Option")
A DELETE request removes a file. The answer is #cmd("204") without a body:

#screen(raw(read("../ex/ug-uss/u-delete.txt"), block: true))

A directory with entries is not removed by the same request. The answer is 400
with the message #cmd("Directory not empty"):

#screen(raw(read("../ex/ug-uss/u-delete-busy.txt"), block: true))

The header #cmd("X-IBM-Option: recursive") deletes the directory with everything
in it. The value is exactly #cmd("recursive"):

#screen(raw(read("../ex/ug-uss/u-delete-dir.txt"), block: true))

The recursive delete has no confirmation and no undo. An empty directory needs
no header. A path that does not exist answers 404.

== Permissions <ug-uss-permissions>

#idx("permissions", "UFS")#idx("read-only mount")
For each request mvsMF tells UFSD who the caller is: the user ID and the group
of the authenticated user. UFSD decides about writing at the level of the
mount, not of the file:

- A mount that is read-only (#cmd("MODE(RO)")) refuses every change with 400,
  the category 4 and the message #cmd("Read-only file system").
- A mount with an #cmd("OWNER()") accepts changes from that user only. The
  change of another user fails with 500, the category 10 and the message
  #cmd("Unknown UFSD error").
- UFSD does not check the permission bits and the owner of a file when it reads,
  lists or writes it. The fields #cmd("mode"), #cmd("user") and #cmd("group") of
  a listing report what the file system stores.

A file that a user makes belongs to that user. A file that exists keeps its owner
when another user writes it.
