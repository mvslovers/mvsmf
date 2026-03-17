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

## Handler

- Function: `ussGetHandler`
- Source: `src/ussapi.c`
- ASM label: `UAPI0002`
