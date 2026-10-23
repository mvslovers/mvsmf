# List Datasets

Returns a list of datasets matching the specified filter criteria.

## HTTP Method
GET

## URL Path
`/zosmf/restfiles/ds`

## Query Parameters
- `dslevel` (required): Dataset name filter pattern. Upper-cased before use, so `mike.test` and `MIKE.TEST` are equivalent; a value longer than 44 characters is refused with `400`. Supports exact names (`USER.TEST.DATA`), hierarchical prefixes (`USER.TEST`), and wildcard patterns (`USER.*`, `USER.**`, `USER.C*`). Internally, the longest concrete prefix is used for the catalog lookup and any wildcard or extra-qualifier filtering is applied afterwards.
- `volser` (optional): Filter by volume serial
- `start` (optional): Starting dataset name for pagination. The listing begins
  at this name — **inclusive**, as in z/OSMF — and runs to the end of the list.
  The value is folded to upper case and trailing blanks are trimmed. A value
  longer than the 44 characters a dataset name can hold is cut to 44, and the
  page then begins *after* that prefix: no cataloged name can be the value
  itself, and one equal to the prefix sorts before it (issue #240).

## Request Headers
- `X-IBM-Max-Items` (optional): Maximum number of items to return. Value `0` means unlimited (default behavior). When the result set is truncated, `moreRows` is set to `true`.

## Response
HTTP status code 200 (OK), whether the listing is complete or was cut short by
`X-IBM-Max-Items` — the truncation is carried in `moreRows` and nowhere else.
That is what real z/OSMF does; it emits no 206 on the files service at all
(issue #274).

**`moreRows` appears only when it is `true`.** A complete listing carries no
such key, again matching the reference (issue #279) — so read the field as a
flag, not as a value to compare against `false`.

The body is a JSON object:

```json
{
    "items": [
        {
            "dsname": "string",
            "blksz": "string",
            "catnm": "string",
            "cdate": "string",
            "dev": "string",
            "dsntp": "string",
            "dsorg": "string",
            "edate": "string",
            "extx": "string",
            "lrecl": "string",
            "migr": "string",
            "mvol": "string",
            "ovf": "string",
            "rdate": "string",
            "recfm": "string",
            "sizex": "string",
            "spacu": "string",
            "used": "string",
            "vol": "string",
            "vols": "string"
        }
    ],
    "returnedRows": 0,
    "JSONversion": 1
}
```

**Every value of an item is a JSON string, numbers included** (`"lrecl": "80"`,
not `80`). Dates are written `YYYY/MM/DD`.

### Field Descriptions
- `dsname`: Dataset name (up to 44 characters)
- `blksz`: Block size
- `catnm`: Catalog name; always empty
- `cdate`: Creation date
- `dev`: Device type, derived from the tracks per cylinder of the volume the
  data set is on: `3350` (30), `3375` (12), `3380` (19) or `3390` (15, and any
  other value)
- `dsntp`: Dataset type (`PDS` for partitioned, `BASIC` for sequential, `UNKNOWN` for others)
- `dsorg`: Dataset organization (`PO` = partitioned, `PS` = physical sequential)
- `edate`: Expiration date; always `***None***`
- `extx`: Number of extents of the data set on its volume, counting every
  extent, those beyond the third included
- `lrecl`: Logical record length
- `migr`, `mvol`, `ovf`: Migrated, multi-volume and overflow flags; always
  `NO`, `N` and `NO`
- `rdate`: Last referenced date
- `recfm`: Record format (e.g. `FB`, `VB`, `U`)
- `sizex`: Allocated size in **tracks**, the sum over every extent. A data set
  with more than three extents keeps the rest in a further DSCB on the volume
  (the format-3 DSCB), which the listing reads (issue #370). Where that DSCB
  cannot be read, or the sum exceeds 65535 tracks, the value is `"?"` rather
  than a size that is too small.
- `spacu`: The unit the data set was allocated in: `CYLINDERS` if it was
  allocated in cylinders, `TRACKS` otherwise. It describes the allocation, not
  the listing: `sizex` is in tracks either way, so a data set of one cylinder on
  a volume with 30 tracks per cylinder lists `"sizex": "30"` and
  `"spacu": "CYLINDERS"`.
- `used`: How full the data set is, as a whole percent of `sizex` (rounded
  down). It is counted up to the track that holds the last block written, so a
  new, empty data set already counts as one track: 3 on a 30-track allocation,
  not 0. `"?"` whenever `sizex` is `"?"`.
- `vol`/`vols`: Volume serial

## Pagination

The result is sorted by dataset name in EBCDIC order before anything is
emitted, and `start` is compared in that same order. Sorting is not cosmetic:
`start` paging asks for the next page *by name*, so an entry out of order would
be skipped for good once a page boundary passed it — LISTC returns a level's
children in catalog order, and the exact-name entry (the `A.B` that `dslevel=A.B`
returns alongside `A.B.C`) is found separately and would otherwise trail the
list (issue #232).

Entries skipped by `start` are not charged against `X-IBM-Max-Items`, and
`moreRows` counts only what is still fetchable from `start` onwards.

## Error Responses
- HTTP 500 (Internal Server Error)
    - Storage for the catalog list could not be obtained (`category` 7, `rc` 16).
      The operator sees `MVSMF006E` naming `THE DATA SET LIST`. Until issue #360
      this answered 200 with an empty `items` array, which reads as "nothing
      cataloged under that level". An empty level is still 200 with no items.

## Limitations
- Only NONVSAM datasets are listed
- `*` and `**` wildcards are treated identically (both match any number of qualifiers)

## Authorization

**None.** This listing reads the catalog and the VTOC and opens nothing, so no
RACF check is reached: any authenticated caller can enumerate any qualifier.

That is deliberate and matches the reference — real z/OSMF lists a data set the
same userid cannot open, and z/OS does not gate `LISTCAT LEVEL()` per entry
either. See issue #229 and [authorization.md](authorization.md).

## Examples

### Using curl
```bash
curl "http://mvs:1080/zosmf/restfiles/ds?dslevel=MIKE.**"
```

### Using Zowe CLI
```bash
zowe files list data-set "MIKE.**"
```

### Success Response

A data set of seven extents, allocated as one track plus six secondary extents
of one track each, written full:

```json
{
    "items": [
        {
            "dsname": "IBMUSER.DOC.EXTENTS",
            "blksz": "6160",
            "catnm": "",
            "cdate": "2026/10/23",
            "dev": "3350",
            "dsntp": "BASIC",
            "dsorg": "PS",
            "edate": "***None***",
            "extx": "7",
            "lrecl": "80",
            "migr": "NO",
            "mvol": "N",
            "ovf": "NO",
            "rdate": "2026/10/23",
            "recfm": "FB",
            "sizex": "7",
            "spacu": "TRACKS",
            "used": "100",
            "vol": "WORK01",
            "vols": "WORK01"
        }
    ],
    "returnedRows": 1,
    "JSONversion": 1
}
```
