# GET /zosmf/restfiles/fs/{filepath} — Read File

Reads the content of a USS file.

## Request

```
GET /zosmf/restfiles/fs/{filepath}
```

### Path Parameters

| Parameter  | Description |
|------------|-------------|
| `filepath` | Absolute path to the file (wildcard capture, includes `/`) |

### Headers

| Header            | Required | Default | Description |
|-------------------|----------|---------|-------------|
| `X-IBM-Data-Type` | No       | `text`  | `text` or `binary` |

## Response (200 OK)

### Text Mode (default)

- Content-Type: `text/plain`
- File content is converted from EBCDIC to ASCII via `mvsmf_etoa()`
- Streamed in 4 KB chunks

### Binary Mode

- Content-Type: `application/octet-stream`
- Raw bytes, no encoding conversion

## Error Responses

| Status | Condition |
|--------|-----------|
| 400    | Missing filepath or path is a directory |
| 404    | File not found |
| 503    | UFSD subsystem not available |

## Max File Size

64 KB (UFSD Phase 1 — direct blocks only). Reads beyond this limit
will return partial data up to the UFSD_RC_NOSPACE boundary.

## Examples

### Read a text file with curl

```bash
curl -u IBMUSER:sys1 \
  "http://mvs:1080/zosmf/restfiles/fs/home/ibmuser/hello.txt"
```

### Read a binary file with curl

```bash
curl -u IBMUSER:sys1 \
  -H "X-IBM-Data-Type: binary" \
  -o output.bin \
  "http://mvs:1080/zosmf/restfiles/fs/home/ibmuser/data.bin"
```

### Read with Zowe CLI

```bash
zowe files download uf "/home/ibmuser/hello.txt" -f hello.txt
```

## Limitations vs Real z/OSMF

- No `Content-Length` header in response (streamed without prior size calculation)
- No `X-IBM-Intrdr-*` headers for record-mode reading
- No `search` query parameter for in-file searching
- No `If-None-Match` / ETag support

## Handler

- Function: `ussGetHandler`
- Source: `src/ussapi.c`
- ASM label: `UAPI0002`
