# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**This file is listed in `.gitignore` and must not be committed to the repository.**

## Project Overview

mvsMF is a z/OSMF REST API implementation for MVS 3.8j, built as a CGI module for Mike Rayborn's HTTPD server. It enables modern clients (Zowe Explorer, Zowe CLI, JetBrains IDEs) to interact with classic MVS systems via standard z/OSMF REST endpoints.

## C Standard Override

**This project uses `-std=gnu99`**, overriding the root CLAUDE.md's strict C89 rule.

Implications:
- `//` line comments are allowed
- Mixed declarations and statements are allowed
- `snprintf`, `stdbool.h`, designated initializers are available
- VLAs are still forbidden (stack constraints)
- All variable declarations should still prefer top-of-block for readability

Cross-compiled for MVS/370 using the `c2asm370` compiler (GCC 3.2.3 fork). All other platform constraints from the root CLAUDE.md still apply (24-bit addressing, EBCDIC, no POSIX, memory efficiency, etc.).

## Development Workflow

1. Every bug fix or feature requires a **GitHub Issue**. If none exists, create one first.
2. **Plan and analyze first** using the Opus 4.6 model. Implementation follows using Sonnet 4.6.
3. Develop each fix/feature on a **feature branch**.
4. When done, merge via **Pull Request** and close the issue with a short comment.
5. **Never reference AI or Claude** in commit messages, comments, PR descriptions, or anywhere else in the project.

## Custom Commands

### /fix-issue \<number\>

Autonomous workflow for resolving a GitHub issue end-to-end:

1. **Read the issue** — `gh issue view <number> --repo mvslovers/mvsmf`
2. **Check for spec** — If the issue has label `uss-phase1`, read `doc/uss-spec.md` first
3. **Create a feature branch** — `git checkout -b issue-<number>-<short-description>`
4. **Analyze** — Identify affected files, understand the existing patterns in nearby code
5. **Implement** — Write code following the conventions in this CLAUDE.md
6. **Verify syntax** — Run `make compiledb` and check clangd diagnostics (no errors)
7. **Update tests** — Add/update tests in `tests/` matching the change
8. **Update docs** — If touching an endpoint handler, update `doc/endpoints/`
9. **Commit** — Descriptive message, no AI references. Reference the issue: `Fixes #<number>`
10. **Push and create PR** — `gh pr create --title "..." --body "Fixes #<number>"`
11. **Summary** — Report what was done, what to verify on the live MVS system

If any step fails, stop and report the issue rather than guessing.

### /sync-docs

Synchronize endpoint documentation with current implementation:

1. Scan all `add_route()` calls in `src/mvsmf.c`
2. For each route, check if matching doc exists in `doc/endpoints/`
3. Report missing or outdated documentation
4. Optionally generate stubs for undocumented endpoints

## Specifications

### USS/UFS Feature Pack

The authoritative specification for all USS-related work is `doc/uss-spec.md`. **Read it before working on any issue labeled `uss-phase1`.** It contains:

- Gap analysis: z/OSMF USS API vs. libufs capabilities
- Architecture decisions (router wildcard, session lifecycle, MBT integration)
- UFSD error code → HTTP status mapping (complete table)
- Encoding rules and I/O patterns
- Implementation plan with task dependencies

## Build System (mbt)

mvsMF uses [mbt](https://github.com/mvslovers/mbt) as its build tool (Git submodule in `mbt/`). Clone with `--recursive` or run `git submodule update --init`.

### Build Commands

```bash
make doctor        # verify environment (MVS connectivity, tools)
make bootstrap     # resolve dependencies, allocate MVS datasets
make build         # cross-compile C → ASM, assemble on MVS, NCAL link
make link          # final linkedit into load module
make install       # copy load module to install dataset
make compiledb     # generate compile_commands.json for clangd
make clean         # remove .s, .o files, build stamps
make distclean     # deep clean (also removes contrib/ and .mbt/)
```

The build chain is: C source → assembly via c2asm370 → upload to SOURCE PDS → IFOX00 assemble + IEWL NCAL link on MVS. Final linkedit produces the MVSMF load module.

### Dependencies (from project.toml)

```toml
[dependencies]
"mvslovers/crent370" = ">=1.0.6"
"mvslovers/httpd" = "=3.3.1-dev"
```

`make bootstrap` resolves these from GitHub Releases, downloads headers into `contrib/`, and provisions NCALIB/MACLIB datasets on MVS.

### Configuration

Local settings go in `.env` (gitignored). See `.env.example` for the template. Key variables: `MBT_MVS_HOST`, `MBT_MVS_PORT`, `MBT_MVS_USER`, `MBT_MVS_PASS`, `MBT_MVS_HLQ`.

clangd provides IDE diagnostics (configured in `.clangd`).

## Architecture

### Request Processing Pipeline

```
HTTP Request → cgxstart.c (CGI init) → mvsmf.c (router setup)
  → router.c (URL decode, method parse, route match, path var extraction)
    → Middleware chain (authmw.c, logmw.c)
      → API handler (dsapi.c, jobsapi.c, infoapi.c)
        → JSON response (json.c)
```

### Key Source Files

- **mvsmf.c**: Entry point. Registers all routes and middleware, initializes the router and HTTPD session.
- **router.c**: HTTP routing framework. Pattern-based URL matching with `{param-name}` path parameters, percent-decoding, middleware chain execution.
- **dsapi.c**: Dataset REST API handlers — list, read, write, create, delete for sequential datasets and PDS members. Largest file by complexity.
- **jobsapi.c**: Jobs REST API handlers — submit JCL, list/status/purge jobs, read spool files. Uses JES2 interfaces.
- **ussapi.c**: USS file REST API handlers — list, read, write, create, delete for UNIX files/directories via libufs/UFSD. Includes chtag utility stub.
- **infoapi.c**: `/zosmf/info` endpoint (no auth required).
- **authmw.c**: Basic Auth middleware using RACF/ACEE for security context.
- **json.c**: JSON response builder with dynamic buffer management.
- **common.c**: Shared utilities for parameter extraction, HTTP responses, and z/OSMF-compatible error formatting.
- **xlate.c**: EBCDIC/ASCII character translation tables.
- **cgxstart.c**: CGI startup/initialization code bridging HTTPD and the application.
- **testapi.c**: Internal test endpoint for verifying crent370 library functions in isolation.

### REST API Structure

All endpoints are under `/zosmf/`:

- `/zosmf/info` — system info (unauthenticated)
- `/zosmf/restfiles/ds/...` — dataset operations (16 routes)
- `/zosmf/restjobs/jobs/...` — job operations (6 routes)
- `/zosmf/restfiles/fs/...` — USS file operations (5 routes)

Endpoint documentation lives in `doc/endpoints/`.

### Keeping Docs and Tests in Sync

Whenever working on an endpoint handler (in `dsapi.c`, `jobsapi.c`, `ussapi.c`, or `infoapi.c`):

- **Review and update the endpoint documentation** in `doc/endpoints/` to match the current behavior.
- **Review and update the integration tests** in `tests/` to cover the current behavior.

### Integration Tests

Test suites live in `tests/`:

- **curl tests**: `curl-datasets.sh`, `curl-jobs.sh`, `curl-binary.sh`, `curl-uss.sh`
- **Zowe CLI tests**: `zowe-datasets.sh`, `zowe-jobs.sh`, `zowe-binary.sh`, `zowe-uss.sh`
- **test.sh**: Top-level runner

Both curl and Zowe suites should cover every endpoint with all relevant variations (query parameters, headers, error cases). When touching a handler, verify the corresponding tests are complete and up to date.

### HTTP Trace Proxy

`tests/trace-zowe.sh` is a reusable TCP proxy for debugging HTTP traffic between any client and mvsMF. It captures all requests and responses with full headers and bodies.

```bash
# Interactive mode — starts proxy, run commands yourself, Ctrl+C to stop
./tests/trace-zowe.sh --proxy

# Command mode — run a specific command through the proxy, show trace
./tests/trace-zowe.sh --proxy "zowe files list ds 'MIG.ZOWE'"
./tests/trace-zowe.sh --proxy "curl -s -u U:P http://localhost:1081/zosmf/restfiles/ds/MY.DS"
```

### Test Endpoint

`/zosmf/test` (`src/testapi.c`) is an internal endpoint for testing crent370 library functions in isolation. Useful for verifying catalog lookups, DSCB reads, and other low-level MVS operations directly via curl.

```bash
curl -u U:P 'http://host:port/zosmf/test?fn=listds&level=SYS1&filter=SYS1.MAC*'
curl -u U:P 'http://host:port/zosmf/test?fn=locate&dsn=SYS1.MACLIB'
```

### Known Platform Bugs

The MVS 3.8j TCP/IP stack has a ring buffer bug that corrupts data when a multi-byte `recv()` call spans the internal buffer wrap-around point. Corrupted reads return replayed data from earlier in the stream. Single-byte `recv()` calls are not affected because they never cross the boundary.

The `receive_raw_data()` function in `jobsapi.c` works around this by reading one byte at a time from the socket (same approach as the HTTPD's `http_getc`). **Do not change `receive_raw_data()` to use larger recv sizes** — any multi-byte recv will reintroduce data corruption for large request bodies (see PR #22 and Issue #42).

### Conventions

- Headers use `asm("SYMBOL")` annotations for MVS external symbol naming.
- Error responses follow z/OSMF format with category, reason code, and return code.
- Manual memory management — watch for malloc/free pairing and cleanup paths.
- Tab indentation, 4-space width, LF line endings (see `.editorconfig`).

## USS/UFS Endpoints

> **Spec:** `doc/uss-spec.md` — the authoritative architecture and design document.
> **Status:** Phase 1 complete (Issues #77–#89). chtag utility implemented (#106).

### Architecture

- All USS handlers live in `ussapi.c` / `ussapi.h`
- UFS session lifecycle: use `uss_open_session()` helper at handler start, `ufsfree()` before return
- ESTAE recovery: `uss_cleanup_callback()` auto-closes UFS handles on abend (via `session->ufs_cleanup`)
- Route pattern `{*filepath}` captures entire remaining path including `/` characters
- PUT to /fs/ dispatches by Content-Type: application/json → USS utilities handler, else → file write
- chtag utility: `list` returns "untagged" stub, `set`/`remove` are accepted no-ops
- libufs/ufsd dependency is managed via mbt (project.toml)

### Handler Naming Convention and ASM Labels

- `ussListHandler`    — GET    /zosmf/restfiles/fs?path=         — asm("UAPI0001")
- `ussGetHandler`     — GET    /zosmf/restfiles/fs/{*filepath}   — asm("UAPI0002")
- `ussPutHandler`     — PUT    /zosmf/restfiles/fs/{*filepath}   — asm("UAPI0003")
- `ussCreateHandler`  — POST   /zosmf/restfiles/fs/{*filepath}   — asm("UAPI0004")
- `ussDeleteHandler`  — DELETE /zosmf/restfiles/fs/{*filepath}   — asm("UAPI0005")

### Encoding Rules (CRITICAL)

- UFSD stores RAW BYTES — no encoding transformation
- Convention: files stored in EBCDIC (so MVS programs can read them)
- ussPutHandler (text mode): ASCII→EBCDIC via mvsmf_atoe() BEFORE ufs_fwrite()
- ussGetHandler (text mode): EBCDIC→ASCII via mvsmf_etoa() AFTER ufs_fread()
- Binary mode: NO conversion, pass bytes through
- X-IBM-Data-Type header determines mode: "text" (default) or "binary"

### UFS Session Pattern (use in EVERY handler)

Use the `uss_open_session()` helper which handles ufsnew(), ACEE, and ESTAE registration:

```c
int ussXxxHandler(Session *session) {
    UFS *ufs = uss_open_session(session);
    if (!ufs) return -1;  // 503 already sent

    /* ... handler logic ... */

    ufsfree(&ufs);
    session->ufs = NULL;  // clear ESTAE tracking
    return rc;
}
```

### Error Code Mapping (UFSD_RC_* → HTTP)

Use the `ufsd_rc_to_http()`, `ufsd_rc_to_category()`, and `ufsd_rc_message()` mapping functions
in `ussapi.c`. ALWAYS call `sendErrorResponse()` with the mapped values.

**Note:** HTTPD does not support HTTP 409, 414, or 507 status codes. These are
mapped to the closest supported alternative (400 or 500).

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
| 68 | UFSD_RC_ROFS     | 403 | 4  | Read-only file system |

### I/O Pattern for File Read

```c
char buf[4096];
UINT32 n;
while ((n = ufs_fread(buf, 1, sizeof(buf), fp)) > 0) {
    if (is_text_mode) {
        mvsmf_etoa((UCHAR *)buf, n);  /* EBCDIC → ASCII */
    }
    http_write(session->httpc, buf, n);
}
```

### I/O Pattern for File Write

```c
char *body = NULL;
size_t body_len = 0;

// Supports Content-Length and Transfer-Encoding: chunked
if (read_request_content(session, &body, &body_len) < 0) {
    return sendErrorResponse(session, 400, ...);
}

if (is_text_mode) {
    mvsmf_atoe((unsigned char *)body, (int)body_len);  /* ASCII → EBCDIC */
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

### Off-Limits

- `receive_raw_data()` — DO NOT MODIFY (MVS TCP/IP bug workaround)
- Router core logic — modify ONLY for {*} wildcard support in is_pattern_match() and extract_path_vars()

### Testing Requirements (when implemented)

- Every handler needs matching curl test in tests/curl-uss.sh
- Every handler needs matching Zowe CLI test in tests/zowe-uss.sh
- Error paths MUST be tested (UFSD not running → 503, non-existent → 404, etc.)
