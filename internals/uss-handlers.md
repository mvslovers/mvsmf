# USS/UFS handlers -- patterns and mappings

Moved verbatim from `CLAUDE.md` on 2026-10-19; `CLAUDE.md` keeps the rules every session needs and points here.

Read before working on `ussapi.c`. The design is `uss-spec.md`; the codepage rule is in `CLAUDE.md` (**Codepage Override**).

## USS/UFS Endpoints

> **Spec:** `internals/uss-spec.md` — the authoritative architecture and design document.
> **Status:** Phase 1 complete (Issues #77–#89). chtag utility implemented (#106).

### Architecture

- All USS handlers live in `ussapi.c` / `ussapi.h`
- UFS session lifecycle: HTTPD-managed via `http_get_ufs()` — no `ufsnew()`/`ufsfree()` in mvsMF
- ESTAE recovery for UFS: handled by HTTPD's worker ESTAE (not mvsMF)
- Route pattern `{*filepath}` captures entire remaining path including `/` characters
- PUT to /fs/ dispatches by Content-Type: application/json → USS utilities handler, else → file write
- chtag utility: `list` returns "untagged" stub, `set`/`remove` are accepted no-ops
- libufs/ufsd dependency is managed via mbt (mbt.toml)

### Handler Naming Convention and ASM Labels

- `ussListHandler`    — GET    /zosmf/restfiles/fs?path=         — asm("UAPI0001")
- `ussGetHandler`     — GET    /zosmf/restfiles/fs/{*filepath}   — asm("UAPI0002")
- `ussPutHandler`     — PUT    /zosmf/restfiles/fs/{*filepath}   — asm("UAPI0003")
- `ussCreateHandler`  — POST   /zosmf/restfiles/fs/{*filepath}   — asm("UAPI0004")
- `ussDeleteHandler`  — DELETE /zosmf/restfiles/fs/{*filepath}   — asm("UAPI0005")

### Encoding Rules (CRITICAL)

> Read **Codepage Override** above first. USS is **IBM-1047**, not CP037 —
> `httpx->xlate_1047`. Using the dataset table here corrupts `[ ] ^ ! ¬` silently.

- UFSD stores RAW BYTES — no encoding transformation
- Convention: files stored in EBCDIC (so MVS programs can read them)
- ussPutHandler (text mode): ASCII→EBCDIC via `http_xlate(..., cp->atoe)` BEFORE ufs_fwrite()
- ussGetHandler (text mode): EBCDIC→ASCII via `http_xlate(..., cp->etoa)` AFTER ufs_fread()
- `cp` comes from `uss_data_type()`: `xlate_1047` by default, `xlate_cp037` for
  `X-IBM-Data-Type: text;fileEncoding=IBM-037` (#393)
- Binary mode: NO conversion, pass bytes through
- X-IBM-Data-Type is parsed by `parse_data_type()` (`src/datatype.c`, shared
  with the data set API): "text" (default) or "binary", any case, parameters
  allowed; "record" is answered 400 like the reference

### UFS Session Pattern (use in EVERY handler)

Use `uss_get_ufs()` which calls `http_get_ufs()` (HTTPD-managed, lazy init per connection) and sets the session owner via `ufs_setuser()` from the ACEE:

```c
int ussXxxHandler(Session *session) {
    UFS *ufs = uss_get_ufs(session);
    if (!ufs) return -1;  // 503 already sent

    /* ... handler logic ... */

    // NO ufsfree — HTTPD manages the UFS session lifecycle
    return rc;
}
```

### Error Code Mapping (UFSD_RC_* → HTTP)

Use the `ufsd_rc_to_http()`, `ufsd_rc_to_category()`, and `ufsd_rc_message()` mapping functions
in `ussapi.c`. ALWAYS call `sendErrorResponse()` with the mapped values.

**Note:** the table below is correct as it stands — see **HTTP Status Codes**
above. EXIST/NOTEMPTY map to 400 and NOSPACE/NOINODES to 500 not because httpd
lacks 409/507 (it has both), but because the z/OSMF status list does not contain
them. Same for NAMETOOLONG → 400, and since #248 every handler agrees with it:
the 414s that used to sit in `ussGetHandler` and `ussPutHandler` are gone, as is
the 501 for an unsupported USS utility (now 400 — the service offers one
utility, so naming another is an incorrect parameter).

**201 for a created resource is correct** (`dsapi.c:2597`, `ussapi.c:960`),
even though it is absent from the enumerated list. Measured against a real
z/OSMF: `POST /zosmf/restfiles/ds/<new PDS>` answers **201** with an empty body.
The list bounds which codes are permitted, it does not mandate one per
condition — see **Checking behaviour against a real z/OSMF**.

**`UFSD_RC_ROFS → 400` since #250.** It used to be 403, the last row outside the
list. It could not be settled by measurement — a read-only file system is a UFSD
condition and the reference has no equivalent state to provoke — so it was
decided together with the 410 that used to come back for purged spool output,
and both followed the list rather than becoming sanctioned exceptions. Category
4 still separates it. The row is unreachable in practice: UFSD has no read-only
mount, so nothing produces this rc today.

| UFSD RC | Constant | HTTP | Category | Description |
|---------|----------|------|----------|-------------|
| 0  | UFSD_RC_OK       | 200 | —  | Success |
| 28 | UFSD_RC_NOFILE   | 404 | 6  | Not found |
| 32 | UFSD_RC_EXIST    | 400 | 4  | Already exists |
| 36 | UFSD_RC_NOTDIR   | 400 | 2  | Not a directory |
| 40 | UFSD_RC_ISDIR    | 400 | 2  | Is a directory |
| 44 | UFSD_RC_NOSPACE  | 500 | 8  | No space left |
| 48 | UFSD_RC_NOINODES | 500 | 8  | No inodes available |
| 52 | UFSD_RC_IO       | 500 | 10 | I/O error |
| 56 | UFSD_RC_BADFD    | 500 | 10 | Bad file descriptor |
| 60 | UFSD_RC_NOTEMPTY | 400 | 4  | Directory not empty |
| 64 | UFSD_RC_NAMETOOLONG | 400 | 2 | Path name too long |
| 68 | UFSD_RC_ROFS     | 400 | 4  | Read-only file system |

### I/O Pattern for File Read

`send_all()` does not translate — convert the payload before handing it over,
and never reach past it to `http_send()` (see **Sending**).
`uss_data_type()` derives the mode and the table from the `X-IBM-Data-Type`
header, and answers the request itself (unsupported encoding, `record`) when
it returns non-zero.

```c
char          buf[4096];
UINT32        n;
int           data_type;
const HTTPCP *cp = NULL;

if ((rc = uss_data_type(session, &data_type, &cp)) != 0) {
    return rc < 0 ? rc : 0;     /* already answered */
}

while ((n = ufs_fread(buf, 1, sizeof(buf), fp)) > 0) {
    if (data_type == DATA_TYPE_TEXT) {
        /* EBCDIC -> ASCII: IBM-1047 unless fileEncoding said CP037 */
        http_xlate((unsigned char *)buf, n, cp->etoa);
    }
    if (send_all(session, (const UCHAR *)buf, (int)n) < 0) {
        break;  /* real handlers goto their cleanup label */
    }
}
```

### I/O Pattern for File Write

```c
char         *body = NULL;
size_t        body_len = 0;
int           data_type;
const HTTPCP *cp = NULL;

/* Before the body is read and before the truncating "w" open */
if ((rc = uss_data_type(session, &data_type, &cp)) != 0) {
    return rc < 0 ? rc : 0;
}

// Supports Content-Length and Transfer-Encoding: chunked
if (read_request_content(session, &body, &body_len) < 0) {
    return sendErrorResponse(session, 400, ...);
}

if (data_type == DATA_TYPE_TEXT) {
    /* ASCII -> EBCDIC: IBM-1047 unless fileEncoding said CP037 */
    http_xlate((unsigned char *)body, (int)body_len, cp->atoe);
}

UFSFILE *fp = ufs_fopen(ufs, filepath, "w");
if (!fp) { /* handle error */ }
ufs_fwrite(body, 1, (UINT32)body_len, fp);
ufs_fclose(&fp);
free(body);
```

### Recursive Delete Pattern

```c
static int recursive_delete(UFS *ufs, const char *path) {
    UFSDDESC *dd = ufs_diropen(ufs, path, NULL);
    if (!dd) return -1;

    UFSDLIST *entry;
    while ((entry = ufs_dirread(dd)) != NULL) {
        if (strcmp(entry->name, ".") == 0 ||
            strcmp(entry->name, "..") == 0) continue;

        char fullpath[UFS_PATH_MAX];
        snprintf(fullpath, sizeof(fullpath), "%s/%s", path, entry->name);

        if (entry->attr[0] == 'd') {
            recursive_delete(ufs, fullpath);
        } else {
            ufs_remove(ufs, fullpath);
        }
    }
    ufs_dirclose(&dd);
    return ufs_rmdir(ufs, path);
}
```

### File Size Limit

- Max file size: 64 KB (UFSD Phase 1 — direct blocks only)
- ufs_fwrite beyond 64K → UFSD_RC_NOSPACE → HTTP 500


### Testing Requirements (when implemented)

- Every handler needs matching curl test in tests/curl-uss.sh
- Every handler needs matching Zowe CLI test in tests/zowe-uss.sh
- Error paths MUST be tested (UFSD not running → 503, non-existent → 404, etc.)
