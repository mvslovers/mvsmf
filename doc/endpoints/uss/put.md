# PUT /zosmf/restfiles/fs/{filepath} — Write File

Writes content to a USS file. Creates the file if it does not exist.

## Request

```
PUT /zosmf/restfiles/fs/{filepath}
```

### Path Parameters

| Parameter  | Description |
|------------|-------------|
| `filepath` | Absolute path to the file (wildcard capture, includes `/`) |

### Headers

| Header            | Required | Default | Description |
|-------------------|----------|---------|-------------|
| `Content-Length`  | Yes      | —       | Size of the request body in bytes |
| `X-IBM-Data-Type` | No       | `text`  | `text` or `binary` |
| `Content-Type`   | No       | —       | If `application/json`, returns 501 (Phase 2 utilities) |

### Body

Raw file content to write.

## Encoding

- **Text mode (default):** Request body is converted from ASCII to EBCDIC
  via `mvsmf_atoe()` before writing to UFS
- **Binary mode:** Raw bytes written with no conversion

## Response

### Success (204 No Content)

No response body.

### Content-Type Dispatch

| Content-Type        | Behavior |
|---------------------|----------|
| `application/json`  | Dispatches to USS utilities handler (see below) |
| Everything else     | Writes file content |

## USS Utilities (Content-Type: application/json)

When the request Content-Type is `application/json`, the body is parsed as a
utility request. The `"request"` field determines which utility to invoke.

### chtag — File Tag Operations

```json
{"request": "chtag", "action": "list|set|remove"}
```

| Action   | Behavior |
|----------|----------|
| `list`   | Returns `{"stdout":["- untagged    T=off <filepath>"]}` (UFSD has no file tagging) |
| `set`    | Accepted as no-op (200, no body) |
| `remove` | Accepted as no-op (200, no body) |

All other utility requests return **501 Not Implemented**.

## Error Responses

| Status | Condition |
|--------|-----------|
| 400    | Missing filepath, empty body, or invalid utility request |
| 404    | Cannot open file for writing (parent directory not found) |
| 414    | Path name too long |
| 500    | No space left on device or I/O error (64 KB limit) |
| 501    | Unsupported USS utility (Content-Type: application/json with unknown request) |
| 503    | UFSD subsystem not available |

## Max File Size

64 KB (UFSD Phase 1 — direct blocks only).

## Examples

### Write a text file with curl

```bash
curl -X PUT -u IBMUSER:sys1 \
  -H "Content-Length: 12" \
  -d "Hello World!" \
  "http://mvs:1080/zosmf/restfiles/fs/home/ibmuser/hello.txt"
```

### Write a binary file with curl

```bash
curl -X PUT -u IBMUSER:sys1 \
  -H "X-IBM-Data-Type: binary" \
  -H "Content-Length: 4" \
  --data-binary $'\x00\x01\x02\x03' \
  "http://mvs:1080/zosmf/restfiles/fs/home/ibmuser/data.bin"
```

### Write a file with Zowe CLI

```bash
echo "Hello World!" | zowe files upload stdin-to-uf "/home/ibmuser/hello.txt"
```

### Query file tag with curl (chtag utility)

```bash
curl -X PUT -u IBMUSER:sys1 \
  -H "Content-Type: application/json" \
  -d '{"request":"chtag","action":"list"}' \
  "http://mvs:1080/zosmf/restfiles/fs/home/ibmuser/hello.txt"
```

## Limitations vs Real z/OSMF

- No `Transfer-Encoding: chunked` on response (request chunked encoding is supported)
- USS utilities limited to `chtag` — `chmod`, `chown`, `extattr` return 501

## Handler

- Function: `ussPutHandler`
- Source: `src/ussapi.c`
- ASM label: `UAPI0003`
