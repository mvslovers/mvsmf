# List Datasets

Returns a list of datasets matching the specified filter criteria.

## HTTP Method
GET

## URL Path
`/zosmf/restfiles/ds`

## Query Parameters
- `dslevel` (required): Dataset name filter pattern. Supports exact names (`USER.TEST.DATA`), hierarchical prefixes (`USER.TEST`), and wildcard patterns (`USER.*`, `USER.**`, `USER.C*`). Internally, the longest concrete prefix is used for the catalog lookup and any wildcard or extra-qualifier filtering is applied afterwards.
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

The body is a JSON object:

```json
{
    "items": [
        {
            "dsname": "string",
            "dsntp": "PDS|BASIC|UNKNOWN",
            "recfm": "string",
            "lrecl": 0,
            "blksize": 0,
            "vol": "string",
            "vols": "string",
            "dsorg": "PO|PS",
            "cdate": "YYYY-MM-DD",
            "rdate": "YYYY-MM-DD"
        }
    ],
    "returnedRows": 0,
    "moreRows": false,
    "JSONversion": 1
}
```

### Field Descriptions
- `dsname`: Dataset name (up to 44 characters)
- `dsntp`: Dataset type (`PDS` for partitioned, `BASIC` for sequential, `UNKNOWN` for others)
- `recfm`: Record format (e.g. `FB`, `VB`, `U`)
- `lrecl`: Logical record length
- `blksize`: Block size
- `vol`/`vols`: Volume serial
- `dsorg`: Dataset organization (`PO` = partitioned, `PS` = physical sequential)
- `cdate`: Creation date
- `rdate`: Last referenced date

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

## Limitations
- Only NONVSAM datasets are listed
- `*` and `**` wildcards are treated identically (both match any number of qualifiers)

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
```json
{
    "items": [
        {
            "dsname": "MIKE.TEST.JCL",
            "dsntp": "PDS",
            "recfm": "FB",
            "lrecl": 80,
            "blksize": 6160,
            "vol": "PUB001",
            "vols": "PUB001",
            "dsorg": "PO",
            "cdate": "2024-01-15",
            "rdate": "2024-06-20"
        }
    ],
    "returnedRows": 1,
    "moreRows": false,
    "JSONversion": 1
}
```
