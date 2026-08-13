# List PDS Members

Returns a list of members in a partitioned dataset (PDS).

## HTTP Method
GET

## URL Path
`/zosmf/restfiles/ds/{dataset-name}/member`

or with explicit volume:

`/zosmf/restfiles/ds/-({volume-serial})/{dataset-name}/member`

## Path Parameters
- `dataset-name`: Name of the partitioned dataset
- `volume-serial` (optional): Volume serial number

## Query Parameters
- `start` (optional): Starting member name for pagination. The listing begins at
  this member — **inclusive**, as in z/OSMF — and runs to the end of the
  directory. The name is folded to upper case and trailing blanks are trimmed,
  so a name echoed back from a previous listing (which is still padded to eight
  characters, issue #154) works unchanged.
- `pattern` (optional): Member name filter. `*` matches any run of characters
  including none, `%` matches exactly one; everything else matches literally,
  and the value is folded to upper case. A pattern without wildcards is an
  exact name. Note that `%` has to be sent percent-encoded as `%25` —
  unencoded it is consumed as a URL escape before the handler ever sees it.

## Request Headers
- `X-IBM-Max-Items` (optional): Maximum number of members to return. Omitted or `0` returns all of them.

## Response
On successful completion, this request returns HTTP status code 200 (OK) and a JSON object:

```json
{
    "items": [
        {
            "member": "string"
        }
    ],
    "returnedRows": 0,
    "moreRows": false,
    "JSONversion": 1
}
```

`moreRows` is `true` only when the list was cut short by `X-IBM-Max-Items`.

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
the SMP/E keys in `SYS1.SMPCDS` are binary. Any byte that cannot appear literally
in a JSON string is emitted as a `\uXXXX` escape naming its ASCII value, so the
response parses whatever the directory contains. Ordinary names (`A-Z 0-9 @ # $`)
are unaffected.

Names are returned padded to 8 characters, as they are held in the directory
(issue #154).

## Error Responses
- HTTP 400 (Bad Request)
    - The dataset is not partitioned (use the dataset endpoint instead)
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
- No member statistics (TTR, size, dates) are returned yet

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
    "moreRows": false,
    "JSONversion": 1
}
```
