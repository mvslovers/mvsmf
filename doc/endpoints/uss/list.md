# GET /zosmf/restfiles/fs — List Directory / File Stat

Lists files and directories at the specified USS path. When the path points to
a file instead of a directory, returns a single-item list with the file's
attributes (stat-like query), matching z/OSMF behavior.

## Request

```
GET /zosmf/restfiles/fs?path=<filepath>
```

### Query Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `path`    | Yes      | Absolute path to a directory or file |

### Headers

| Header            | Required | Default | Description |
|-------------------|----------|---------|-------------|
| `X-IBM-Max-Items` | No       | 1000    | Maximum items to return. 0 = unlimited |

## Response (200 OK)

```json
{
  "items": [
    {
      "name": "myfile.txt",
      "mode": "-rw-r--r--",
      "size": 1234,
      "user": "IBMUSER",
      "group": "SYS1",
      "links": 1,
      "mtime": "2026-03-15T14:30:00Z",
      "inode": 42
    }
  ],
  "returnedRows": 1,
  "totalRows": 1,
  "moreRows": false,
  "JSONversion": 1
}
```

### Item Fields

| Field   | Source            | Type   | Description |
|---------|-------------------|--------|-------------|
| `name`  | UFSDLIST.name     | string | File or directory name (full path for file stat queries) |
| `mode`  | UFSDLIST.attr     | string | Unix permission string (e.g. `drwxr-xr-x`) |
| `size`  | UFSDLIST.filesize | number | File size in bytes |
| `user`  | UFSDLIST.owner    | string | Owner name |
| `group` | UFSDLIST.group    | string | Group name |
| `links` | UFSDLIST.nlink    | number | Hard link count |
| `mtime` | UFSDLIST.mtime    | string | Last modified time (ISO 8601 UTC) |
| `inode` | UFSDLIST.inode_number | number | Inode number |

### Pagination

When `X-IBM-Max-Items` is set and the directory contains more entries:
- `returnedRows` = number of items in the response
- `totalRows` = total entries in the directory (excluding `.` and `..`)
- `moreRows` = `true` when results were truncated

## Error Responses

| Status | Condition |
|--------|-----------|
| 400    | Missing `path` query parameter |
| 404    | Path not found |
| 503    | UFSD subsystem not available |

## Examples

### List a directory with curl

```bash
curl -u IBMUSER:sys1 \
  "http://mvs:1080/zosmf/restfiles/fs?path=/home/ibmuser"
```

### List with max items

```bash
curl -u IBMUSER:sys1 \
  -H "X-IBM-Max-Items: 10" \
  "http://mvs:1080/zosmf/restfiles/fs?path=/home/ibmuser"
```

### Stat a single file (file path query)

```bash
curl -u IBMUSER:sys1 \
  "http://mvs:1080/zosmf/restfiles/fs?path=/home/ibmuser/myfile.txt"
```

Returns a single-item list with the full path in the `name` field:

```json
{
  "items": [
    {
      "name": "/home/ibmuser/myfile.txt",
      "mode": "-rw-r--r--",
      "size": 1234,
      ...
    }
  ],
  "returnedRows": 1,
  "totalRows": 1,
  "moreRows": false,
  "JSONversion": 1
}
```

### List with Zowe CLI

```bash
zowe files list uf "/home/ibmuser"
```

## Limitations vs Real z/OSMF

- No `depth` query parameter (lists one level only)
- No `filesys`, `symlinks`, `group`, `mtime`, `size`, `perm`, `type` filters
- No `lstat` mode — always follows symlinks (UFSD has no symlink support)
- `mode` field returns UFSD `attr` string (e.g. `drwxr-xr-x`), not the numeric z/OSMF format

## Handler

- Function: `ussListHandler`
- Source: `src/ussapi.c`
- ASM label: `UAPI0001`
