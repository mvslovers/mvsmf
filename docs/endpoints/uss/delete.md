# DELETE /zosmf/restfiles/fs/{filepath} — Delete File or Directory

Deletes a file or directory from the UFS filesystem.

## Request

```
DELETE /zosmf/restfiles/fs/{filepath}
```

### Path Parameters

| Parameter  | Description |
|------------|-------------|
| `filepath` | Absolute path to the file or directory (wildcard capture, includes `/`) |

### Headers

| Header         | Required | Default | Description |
|----------------|----------|---------|-------------|
| `X-IBM-Option` | No       | —       | Set to `recursive` to delete non-empty directories |

## Behavior

1. Tries `ufs_remove()` first (works for regular files)
2. If the target is a directory (UFSD_RC_ISDIR):
   - Without `X-IBM-Option: recursive`: calls `ufs_rmdir()` (fails if not empty)
   - With `X-IBM-Option: recursive`: walks the directory tree depth-first,
     removing all files and subdirectories before removing the directory itself

## Response

### Success (204 No Content)

No response body.

## Error Responses

| Status | Condition |
|--------|-----------|
| 400    | Missing filepath, path too long, or directory not empty without recursive |
| 404    | File or directory not found |
| 403    | Read-only file system |
| 500    | I/O error or other server error |
| 503    | UFSD subsystem not available |

## Examples

### Delete a file with curl

```bash
curl -X DELETE -u IBMUSER:sys1 \
  "http://mvs:1080/zosmf/restfiles/fs/home/ibmuser/myfile.txt"
```

### Delete a directory recursively with curl

```bash
curl -X DELETE -u IBMUSER:sys1 \
  -H "X-IBM-Option: recursive" \
  "http://mvs:1080/zosmf/restfiles/fs/home/ibmuser/mydir"
```

### Delete with Zowe CLI

```bash
zowe files delete uf "/home/ibmuser/myfile.txt"
```

## Limitations vs Real z/OSMF

- Only `recursive` is supported for `X-IBM-Option` (no other options)
- No symbolic link handling (UFSD has no symlink support)

## Handler

- Function: `ussDeleteHandler`
- Source: `src/ussapi.c`
- ASM label: `UAPI0005`
