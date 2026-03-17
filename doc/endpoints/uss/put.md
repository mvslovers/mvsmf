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
| `application/json`  | Returns 501 — USS utilities are Phase 2 |
| Everything else     | Writes file content |

## Error Responses

| Status | Condition |
|--------|-----------|
| 400    | Missing filepath or empty body or missing Content-Length |
| 404    | Cannot open file for writing (parent directory not found) |
| 414    | Path name too long |
| 501    | Content-Type is application/json (Phase 2 utilities) |
| 503    | UFSD subsystem not available |
| 507    | No space left on device (64 KB limit) |

## Max File Size

64 KB (UFSD Phase 1 — direct blocks only).

## Handler

- Function: `ussPutHandler`
- Source: `src/ussapi.c`
- ASM label: `UAPI0003`
