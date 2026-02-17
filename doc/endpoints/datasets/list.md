# List Datasets

Returns a list of datasets matching the specified filter criteria.

## HTTP Method
GET

## URL Path
`/zosmf/restfiles/ds`

## Query Parameters
- `dslevel` (required): Dataset name filter pattern (e.g. `USER.**`, `SYS1.MAC*`)
- `volser` (optional): Filter by volume serial
- `start` (optional): Starting dataset name for pagination

## Response
On successful completion, this request returns HTTP status code 200 (OK) and a JSON object:

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

## Limitations
- Only NONVSAM datasets are listed
- `moreRows` is always `false` (no pagination support yet)

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
