# GET /zosmf/restfiles/fs — List Directory

Lists files and directories at the specified USS path.

## Request

```
GET /zosmf/restfiles/fs?path=<filepath>
```

### Query Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `path`    | Yes      | Absolute path to the directory to list |

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
| `name`  | UFSDLIST.name     | string | File or directory name |
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
| 404    | Path not found or not a directory |
| 503    | UFSD subsystem not available |

## Handler

- Function: `ussListHandler`
- Source: `src/ussapi.c`
- ASM label: `UAPI0001`
