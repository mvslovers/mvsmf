# List PDS Members

Returns a list of members in a partitioned dataset (PDS).

## HTTP Method
GET

## URL Path
`/zosmf/restfiles/ds/{dataset-name}/member`

Also available with a volume serial: `/zosmf/restfiles/ds/-({volume-serial})/{dataset-name}/member`.
The request is served only when the data set is cataloged on that volume;
otherwise it is answered 404 (or 400 for a malformed volume serial). See
[volume-serial.md](volume-serial.md).

## Path Parameters
- `dataset-name`: Name of the partitioned dataset

## Query Parameters
- `start` (optional): Starting member name for pagination. The listing begins at
  this member — **inclusive**, as in z/OSMF — and runs to the end of the
  directory. The name is folded to upper case and trailing blanks are trimmed,
  so a name padded to the directory's eight characters — by an older client, or
  by one that kept a list from before issue #154 — works unchanged. A value
  longer than eight characters cannot name a member: it is cut to eight and the
  page then begins *after* that prefix, since a member named exactly the prefix
  sorts before the value that was sent (issue #240).
- `pattern` (optional): Member name filter. `*` matches any run of characters
  including none, `%` matches exactly one; everything else matches literally,
  and the value is folded to upper case. A pattern without wildcards is an
  exact name. Note that `%` has to be sent percent-encoded as `%25` —
  unencoded it is consumed as a URL escape before the handler ever sees it.
  A pattern of 45 characters or more is rejected with HTTP 400 (`reason` 9)
  rather than truncated, since a shortened pattern would select a different set
  of members and the 200 would be a wrong answer instead of an error.

## Request Headers
- `X-IBM-Max-Items` (optional): Maximum number of members to return. Omitted or `0` returns all of them.
- `X-IBM-Attributes` (optional): `base` adds the ISPF statistics of each member
  to its item (see [ISPF statistics](#ispf-statistics)). `member`, no header,
  or any other word returns the name alone, which is the default. The value is
  not case sensitive, and `base,total` is accepted as `base`: the `total`
  option is not implemented and does not change the answer. Zowe CLI sends
  `base` for `zowe files list am --attributes`.

## Response
HTTP status code 200 (OK), whether the listing is complete or was cut short by
`X-IBM-Max-Items` — the truncation is carried in `moreRows` and nowhere else.
That is what real z/OSMF does; it emits no 206 on the files service at all
(issue #274).

The body is a JSON object:

```json
{
    "items": [
        {
            "member": "string"
        }
    ],
    "returnedRows": 0,
    "JSONversion": 1
}
```

**`moreRows` appears only when the list was cut short by `X-IBM-Max-Items`**,
and is `true` when it does. A complete listing carries no such key, matching the
reference (issue #279) — so read the field as a flag, not as a value to compare
against `false`.

## ISPF statistics

With `X-IBM-Attributes: base` every member whose directory entry carries ISPF
statistics is listed with them, in z/OSMF's fields and order:

```json
{
    "items": [
        {
            "member": "WITHST",
            "vers": 1,
            "mod": 5,
            "c4date": "2015/08/12",
            "m4date": "2015/08/12",
            "cnorc": 22,
            "inorc": 22,
            "mnorc": 3,
            "mtime": "05:48",
            "msec": "43",
            "user": "IBMUSER",
            "sclm": "N"
        },
        { "member": "PLAIN" }
    ],
    "returnedRows": 2,
    "JSONversion": 1
}
```

| Field | Meaning | Type |
|---|---|---|
| `vers`, `mod` | version and modification level | number |
| `c4date` | creation date, `yyyy/mm/dd` | string |
| `m4date` | date of the last change, `yyyy/mm/dd` | string |
| `mtime`, `msec` | time of the last change, `hh:mm` and the seconds as two digits | string |
| `cnorc` | current number of records | number |
| `inorc` | initial number of records | number |
| `mnorc` | number of modified records | number |
| `user` | userid of the last change, without the blank padding | string |
| `sclm` | `Y` when the member was last changed under SCLM, else `N` | string |

The statistics are read from the user data of the directory entry, the 30
bytes ISPF writes there. Nothing is looked up besides the directory, so the
header costs no I/O beyond the directory walk the list does anyway.

**A member without statistics is listed with its name only** — no fields are
invented and the request is not an error. That is the case for

- a member of a load library, whose user data is a linkage editor's, not ISPF's;
- a member whose entry has no user data, or user data of another length, or
  data that does not hold up as ISPF statistics (a field that is not a packed
  number, a date that does not exist) — foreign tools stow their own bytes
  there, and reporting them as a date would be wrong;
- a member written through mvsMF itself (`PUT`), which stows no statistics;
- a member with the **extended** statistics ISPF writes once a member has more
  than 65535 records (a longer user data field, 40 bytes). Those are not
  decoded; the member is listed by name.

`X-IBM-Max-Items`, `start` and `pattern` work as they do without the header, and
`returnedRows` and `moreRows` count members as before.

Not measured against a real z/OSMF: what it answers for a member without
statistics (the name alone is what is documented and what is implemented), and
the exact reading of `sclm` and of the two record counts `cnorc` and `inorc`
for a member that has been edited. The fields follow the ISPF layout and the
IBM documentation; `inorc` is the initial and `cnorc` the current number of
records.

## Large directories

The directory is walked and each member emitted as it is read, so the handler's
storage footprint is one 256-byte block regardless of how many members the data
set has. `SYS1.SMPCDS` (22982 members) returns in about 3 s and 850 KB.

This matters more than it sounds. The handler used to call `__listpd()`, which
builds the complete member array in storage before anything is emitted. On a
data set that size the region is exhausted, the request abends **S878**, and
because the abend unwinds before the handler's `__freepd()` the storage is never
returned — after which httpd can no longer load MVSMF at all and *every*
endpoint answers `S80A` until the server is restarted (issue #212). A single
ordinary request, such as opening a large PDS in Zowe Explorer, was enough.

Use `X-IBM-Max-Items` if a bounded response is wanted; it is no longer needed to
keep the server alive.

## Non-printable member names

Nothing requires a directory entry to hold a printable name, and some do not —
the SMP/E keys in `SYS1.SMPCDS` are binary. A quotation mark is written `\"` and a
backslash `\\`. Every other byte whose character, after the response has been
translated to ASCII, is not a printable ASCII character (below U+0020 or above
U+007E) is emitted as a `\u00XX` escape naming that code point, so the response
parses whatever the directory contains. Ordinary names (`A-Z 0-9 @ # $`) are
unaffected.

## Name padding

The directory holds every name blank padded to eight bytes. Those blanks are
**not** part of the name and are trimmed before the name is emitted, matching
z/OSMF — `"member": "CR"`, not `"member": "CR      "`. The endpoint used to
return the padded form (issue #154), which left a client building
`{dsn}({member})` from the listing asking for a member whose name ends in a
blank.

`start=` still accepts a padded name, so a client holding a list from before the
fix keeps working.

## Error Responses
- HTTP 400 (Bad Request)
    - The dataset is not partitioned (use the dataset endpoint instead)
    - `pattern` is 45 characters or longer (`reason` 9)
- HTTP 404 (Not Found)
    - Dataset not cataloged (`reason` 4)
- HTTP 500 (Internal Server Error)
    - I/O error while reading the directory

The target is checked against the catalog and the DSCB before the directory is
read. `__listpd()` reads it with BPAM, and against a data set that is not
partitioned that is an S001 abend rather than an error return — so the check
has to happen first (issue #193). A dataset that was not cataloged used to be
answered with an empty `items` list and 200, which reads as "this PDS has no
members".

## Pagination

`X-IBM-Max-Items` caps a page, `start` picks up where the last one ended,
`pattern` filters, and `moreRows` says whether anything is left. The three
compose, and neither the members skipped by `start` nor the ones rejected by
`pattern` are charged against the page limit — a page is always
`X-IBM-Max-Items` members long as long as the directory still holds that many
matches. `returnedRows` and `moreRows` therefore count matches, not directory
entries.

The directory is stored in **EBCDIC** order, and `start` is compared in that
same order — `IEAVNPF1` precedes `IEAVNP03`, because `F` (0xC6) sorts before
`0` (0xF0). An ASCII comparison would order the two the other way round and
mis-skip every name mixing letters and digits (issue #232).

```bash
# every JES2 member                -> JES2 JES2BLD JES2JOB JES2LNK JES20098 JES20099
curl 'http://mvs:1080/zosmf/restfiles/ds/SYS1.PROCLIB/member?pattern=JES2*'

# JES2 plus exactly four more       -> JES20098 JES20099   (%25 is '%')
curl 'http://mvs:1080/zosmf/restfiles/ds/SYS1.PROCLIB/member?pattern=JES2%25%25%25%25'

# the filtered list, two per page
curl -H 'X-IBM-Max-Items: 2' \
  'http://mvs:1080/zosmf/restfiles/ds/SYS1.PROCLIB/member?pattern=JES2*'
curl -H 'X-IBM-Max-Items: 2' \
  'http://mvs:1080/zosmf/restfiles/ds/SYS1.PROCLIB/member?pattern=JES2*&start=JES2JOB'
```

## Limitations
- The statistics are the ISPF ones, and only the 30-byte form: members with the
  extended 40-byte statistics (more than 65535 records) are listed by name.
  Load module attributes (size, AMODE, RMODE, ...) of a load library are not
  returned.
- `X-IBM-Attributes: base,total` does not return a `totalRows`.

## Authorization

Requires **READ** on the library in class `DATASET` (issue #228). The check runs
before any catalog, VTOC or data set access, so a refusal is indistinguishable
from "does not exist".

A refusal answers **HTTP 500** with `category 4`, `rc 8`, `reason 0` and the
explanation in `details[]` — the shape a real z/OSMF sends; 403 is not a z/OSMF
status. See [authorization.md](authorization.md).

## Examples

### Using curl
```bash
curl http://mvs:1080/zosmf/restfiles/ds/MIKE.TEST.JCL/member
```

### Using Zowe CLI
```bash
zowe files list all-members "MIKE.TEST.JCL"
```

```bash
# bounded
curl -H 'X-IBM-Max-Items: 100' \
  http://mvs:1080/zosmf/restfiles/ds/SYS1.MACLIB/member

# with the ISPF statistics
curl -H 'X-IBM-Attributes: base' \
  http://mvs:1080/zosmf/restfiles/ds/MIKE.TEST.JCL/member
```

```bash
zowe files list all-members "MIKE.TEST.JCL" --attributes
```

```
- 
  member: WITHST
  vers:   1
  mod:    5
  c4date: 2015/08/12
  m4date: 2015/08/12
  cnorc:  22
  inorc:  22
  mnorc:  3
  mtime:  05:48
  msec:   43
  user:   IBMUSER
  sclm:   N
- 
  member: PLAIN
```

### Success Response
```json
{
    "items": [
        { "member": "MYJOB" },
        { "member": "TESTPGM" },
        { "member": "LINKJOB" }
    ],
    "returnedRows": 3,
    "JSONversion": 1
}
```
