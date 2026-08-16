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
| `Content-Length`     | Yes      | —       | Size of the request body in bytes |
| `X-IBM-Data-Type`    | No       | `text`  | `text` or `binary` |
| `Content-Type`       | No       | —       | If `application/json`, dispatches to the USS utilities handler |
| `If-Match`           | No       | —       | An `ETag` from an earlier read. The write proceeds only if the file still matches it; otherwise **412** and nothing is written |
| `X-IBM-Return-Etag`  | No       | —       | `true` returns the `ETag` of the file as it stands after the write |

### Body

Raw file content to write.

## Encoding

- **Text mode (default):** Request body is converted from ASCII to EBCDIC
  (IBM-1047) before writing to UFS
- **Binary mode:** Raw bytes written with no conversion

## Response

### Success (204 No Content)

No response body. Carries an `ETag` header when `X-IBM-Return-Etag: true` was
sent.

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

## Conditional writes (If-Match)

Without `If-Match`, a PUT is last-write-wins: two clients editing the same file
both get 204 and the later save silently discards the earlier one. Nothing in
the response distinguishes that from a clean save.

`If-Match` closes that hole. Read the file with `X-IBM-Return-Etag: true`, keep
the `ETag`, and send it back when saving. The handler re-reads the file and
compares before opening it for output; on a mismatch it answers **412
Precondition Failed** and writes nothing.

- **Take the next `If-Match` from the PUT response**, not from the value you
  sent. The ETag in the PUT response is computed by re-reading the file after
  the write, and is the one the next `If-Match` must carry. Reusing the
  pre-save stamp fails.
- **Accepted forms**: bare (`If-Match: 3F5C…`), quoted (`"3F5C…"`), weak
  (`W/"3F5C…"`), and comma-separated lists of those. Comparison is
  case-insensitive.
- **`If-Match: *`** asserts only that the file exists.
- Without `If-Match` nothing changes; existing clients are unaffected.

### What a missing path answers

A PUT creates the file if it is not there, so there is no 404 to compete with:
when `If-Match` (including `*`) names a path that does not exist, the
precondition has failed and the answer is **412** — nothing is created. This is
the opposite ordering from a GET, where a missing path is **404** before any
conditional header is looked at, because the more specific answer wins.

A path that *is* a directory answers exactly as it would without `If-Match`:
**404**. Adding a precondition does not change how a non-file path is reported.
That 404 is itself a deviation from the `UFSD_RC_ISDIR` → 400 row of the error
mapping — `ufs_fopen()` returns NULL for a directory in either mode, so the
handler has no ISDIR to report — tracked separately as issue #269.

## Error Responses

| Status | Condition |
|--------|-----------|
| 400    | Missing filepath or invalid utility request |
| 404    | Cannot open file for writing (parent directory not found, or the path is a directory — see #269) |
| 412    | `If-Match` was supplied and the file no longer matches it — including a file that no longer exists |
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

### Save a file conditionally with curl

```bash
# Read, keeping the stamp
ETAG=$(curl -s -o hello.txt -D - -u IBMUSER:sys1 \
  -H "X-IBM-Return-Etag: true" \
  "http://mvs:1080/zosmf/restfiles/fs/home/ibmuser/hello.txt" \
  | grep -i '^ETag:' | tr -d '\r' | sed 's/^[^ ]* //')

# Save it back only if nobody else changed it in the meantime
curl -X PUT -u IBMUSER:sys1 \
  -H "If-Match: ${ETAG}" \
  -H "X-IBM-Return-Etag: true" \
  --data-binary @hello.txt \
  "http://mvs:1080/zosmf/restfiles/fs/home/ibmuser/hello.txt"
# -> 204 and a new ETag, or 412 if the file changed in the meantime
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
