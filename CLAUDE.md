# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

mvsMF is a z/OSMF REST API implementation for MVS 3.8j, running as a CGI module for Mike Rayborn's HTTPD web server. It enables modern clients (Zowe Explorer, Zowe CLI) to interact with MVS datasets and jobs. **Work in progress, not production-ready.**

The API strictly follows IBM's z/OSMF REST API URL paths and HTTP methods. Where MVS 3.8j JES2 lacks features (e.g. job correlator IDs), endpoints are omitted. Custom endpoints use `/mvsmf/` prefix instead of `/zosmf/`.

Reference docs:
- [z/OSMF Info Service](https://www.ibm.com/docs/en/zos/3.1.0?topic=services-zosmf-information-retrieval-service)
- [z/OS Jobs REST](https://www.ibm.com/docs/en/zos/3.1.0?topic=services-zos-jobs-rest-interface)
- [z/OS Dataset REST](https://www.ibm.com/docs/en/zos/3.1.0?topic=services-zos-data-set-file-rest-interface)

## Build Commands

```bash
make          # Compile all C sources → assembler (.s) → object files (.o)
make clean    # Remove generated .s and .o files
```

Cross-compilation toolchain: `c2asm370` (C → S/370 assembler), then `mvsasm` (assembler → object). Output goes to MVS datasets `FIX0MIG.MVSMF.OBJECT` / `FIX0MIG.MVSMF.NCALIB`.

## Architecture

**Request flow:** HTTPD → `cgxstart.c` (CGI init) → `mvsmf.c` (main, registers routes + middleware) → `router.c` (middleware chain → route matching → handler dispatch)

Key components:
- **router.c/h** — HTTP routing framework with path parameter extraction (e.g. `{job-name}`) and middleware chain. Session struct carries HTTPD context, RACF ACEE, and router reference.
- **authmw.c/h** — Authentication middleware: Basic Auth → Base64 decode → RACF validation → ACEE creation.
- **common.c/h** — HTTP response helpers (`sendJSONResponse`, `sendErrorResponse` in z/OSMF format), parameter extraction (`getQueryParam`, `getPathParam`, `getHeaderParam`).
- **json.c/h** — Dynamic JSON string builder with auto-growing buffer.
- **jobsapi.c/h** — Job endpoints (list, status, files, records, submit, purge, cancel) via JES2 interface. Largest module (~1700 lines).
- **dsapi.c/h** — Dataset endpoints (list, get, put) and PDS member endpoints via VSAM catalog access.
- **infoapi.c/h** — System info endpoint.

Dependencies are Git submodules under `contrib/`:
- `crent370_sdk/` — CRENT370 C library (MVS system calls, JES2, VSAM, RACF, memory, I/O)
- `httpd_cgi_sdk/` — HTTPD CGI SDK (HTTP request/response, CGI interface)

## Code Conventions

### Language & Platform
- **ISO C89** syntax only. Target: MVS 3.8j (24-bit address space).
- Memory and performance matter: use `register`, `const`, `inline` where appropriate. Avoid leaks and unnecessary allocations.
- Use `wtof` for logging with `MVSMFxx[I,W,E,D]` prefix. **Never use `printf`** (except the startup guard in main). Never use `http_` prefix for files, functions, or variables.

### Naming
| Element | Convention | Example |
|---------|-----------|---------|
| Handler functions | lowerCamelCase | `jobListHandler` |
| Static functions | snake_case | `get_self` |
| Variables | snake_case with auxiliary verbs | `is_loading`, `has_error` |
| Structs | snake_case | `struct route` |
| Typedefs | PascalCase | `Router`, `Session` |
| Enums | PascalCase (type), UPPER_CASE (values) | `HttpMethod`, `GET` |
| Macros/constants | UPPER_CASE | `MAX_ROUTES` |
| File names | max 8 characters | `jobsapi.c` |

### ASM Identifier Convention
Public functions in headers **must** have `asm("XXXnnnn")` suffix (3-letter module prefix + 4-digit number):

| Module | Prefix | Example |
|--------|--------|---------|
| router | RTR | `RTR0001` |
| common | CMN | `CMN0001` |
| json | JSON | `JSON000` |
| dsapi | DAPI | `DAPI0001` |
| jobsapi | JAPI | `JAPI0001` |
| infoapi | IAPI | `IAPI0000` |
| xlate | XLT | `XLT0001` |
| authmw | AUTHMW | `AUTHMW00` |
| logmw | LOGMW | `LOGMW00` |

Implementations in `.c` files must **not** have the asm suffix. Static (private) functions need an `__asm__` statement before the function:
```c
__asm__("\n&FUNC    SETC 'funcname'");
static int
funcname(char *param1, char *param2)
{
    ...
}
```

### File Structure Order
includes → defines → typedefs → structs → enums → unions → private function prototypes → public function implementations → private function implementations

### Brace Style
- Functions: opening `{` on **new line**
- Control flow (if/for/while/switch): opening `{` on **same line**
- Closing `}` always on new line
- Static function name on its own line before parameter list

### Formatting
- Tabs for indentation (width 4), max 120 columns, LF line endings, UTF-8, trailing newline

## Git Workflow

Always create a feature branch before making changes: `fix/short-description` or `feat/short-description`. Never commit directly to `main`.

Prefixes: `feat:` | `fix:` | `docs:` | `ref:` | `style:` | `maint:`

Do **not** add `Co-Authored-By` trailers to commit messages. Do **not** add "Generated with Claude Code" lines to PRs, commits, or issue comments.

## Known TODOs

- **Build process**: The final link job (`LKDMVSMF`) on the mainframe must be manually updated when new modules are added (e.g. `INCLUDE NCALIB(XLATE)`). The Makefile only handles compile + assemble + individual link to NCALIB, but the final link JCL lives on the host. Goal: automate so that adding a source file to `C_FILES` in the Makefile is the only step needed.

## Endpoint Documentation

API endpoint docs go in `doc/endpoints/` grouped by service, using Markdown with curl and Zowe CLI examples. Every new endpoint **must** include corresponding documentation. Changes to existing endpoints (parameters, response format, error codes, headers) **must** be reflected in the docs.
