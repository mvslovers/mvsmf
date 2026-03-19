# POST /zosmf/restfiles/fs/{filepath} — Create File or Directory

Creates a new file or directory at the specified USS path.

## Request

```
POST /zosmf/restfiles/fs/{filepath}
```

### Path Parameters

| Parameter  | Description |
|------------|-------------|
| `filepath` | Absolute path to the file or directory to create (wildcard capture, includes `/`) |

### Headers

| Header         | Required | Default            | Description |
|----------------|----------|--------------------|-------------|
| `Content-Type` | Yes      | `application/json` | Must be `application/json` |

### Body (JSON)

```json
{
  "type": "file",
  "mode": "rwxr-xr-x"
}
```

| Field  | Required | Default     | Description |
|--------|----------|-------------|-------------|
| `type` | Yes      | —           | `file`, `directory`, or `dir` |
| `mode` | No       | `rwxr-xr-x` | Unix permission string (9 characters, e.g. `rw-r--r--`) |

## Behavior

- **`type: "file"`**: Creates an empty file via `ufs_fopen("w")` + `ufs_fclose()`. Returns 400 if the file already exists (does not truncate).
- **`type: "directory"` or `"dir"`**: Creates a directory via `ufs_mkdir()`. Returns 400 if the directory already exists.
- **`mode`**: Parsed as a Unix permission string (`rwxr-xr-x` → octal 0755). Applied via `ufs_set_create_perm()` before creation, then restored to the previous default.

## Response

### Success (201 Created)

No response body.

## Error Responses

| Status | Condition |
|--------|-----------|
| 400    | Missing filepath, missing or invalid `type`, file/directory already exists, path too long, or parent directory not found |
| 503    | UFSD subsystem not available |

## Examples

### Create a directory with curl

```bash
curl -X POST -u IBMUSER:sys1 \
  -H "Content-Type: application/json" \
  -d '{"type":"directory","mode":"rwxr-xr-x"}' \
  "http://mvs:1080/zosmf/restfiles/fs/home/ibmuser/mydir"
```

### Create a file with curl

```bash
curl -X POST -u IBMUSER:sys1 \
  -H "Content-Type: application/json" \
  -d '{"type":"file","mode":"rw-r--r--"}' \
  "http://mvs:1080/zosmf/restfiles/fs/home/ibmuser/myfile.txt"
```

### Create a directory with Zowe CLI

```bash
zowe zos-uss issue ssh "mkdir /home/ibmuser/mydir"
```

> **Note:** Zowe CLI does not have a direct `zos-files create uss-file` command.
> The closest equivalent is `zowe zos-uss issue ssh` with a mkdir/touch command,
> or using the API directly via `zowe zos-files invoke rest-api`.

## Limitations vs Real z/OSMF

- The `mode` field accepts only symbolic permission strings (`rwxr-xr-x`), not octal values
- No support for creating symbolic links
- Maximum path length is limited by `UFS_PATH_MAX`

## Handler

- Function: `ussCreateHandler`
- Source: `src/ussapi.c`
- ASM label: `UAPI0004`
