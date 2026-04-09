# HTTPD — Notes from the mvsMF Project

Observations and lessons learned while developing mvsMF as a CGI module for the HTTPD server. Intended as input for the HTTPD project's CLAUDE.md.

## Module Caching

The HTTPD caches loaded CGI modules in memory. After installing a new version into the LINKLIB (`make install`), the HTTPD must be restarted for the updated module to take effect. There is currently no hot-reload mechanism — if one exists or gets added, it should be prominently documented.

## TCP/IP Ring-Buffer Bug (MVS 3.8j)

The MVS 3.8j TCP/IP stack has a ring buffer bug: multi-byte `recv()` calls that span the internal buffer wrap-around point return corrupted (replayed) data. The HTTPD's `http_getc` works around this by reading one byte at a time. This is intentional and must not be "optimized" to use larger recv sizes. See mvsMF PR #22 and Issue #42 for context.

## CGI Interface

The HTTPD exposes request data to CGI modules via environment-style variables:

- **Query parameters** are available as `QUERY_<NAME>` (e.g., `QUERY_DSLEVEL`, `QUERY_FN`)
- **Path variables** from route patterns are available as `HTTP_<name>` (e.g., `HTTP_dataset-name`)
- **Request metadata**: `REQUEST_METHOD`, `REQUEST_PATH`, etc.

Key functions for CGI modules:
- `http_get_env(httpc, name)` — read request parameters
- `http_resp(httpc, status)` — send HTTP status
- `http_printf(httpc, fmt, ...)` — write response headers/body

## Worker Thread Architecture

The HTTPD uses worker threads to handle requests. An ABEND (S0C4, S80A, etc.) in a CGI module kills only the worker thread, not the entire server. The server continues accepting new requests on surviving workers.

## RACF / Security Integration

File operations triggered by CGI modules (e.g., VTOC reads via `__dscbdv`, catalog lookups via `__listc`) go through RACF authorization checks (ICHSFR00). Broad catalog scans (e.g., `LISTC LEVEL('HLQ')` on a high-level qualifier with many datasets) can trigger a large number of RACF checks and lead to resource exhaustion or ABENDs. Keep catalog queries as narrow as possible.

## mvsMF as Primary Consumer

mvsMF is currently the largest user of the CGI interface. API or behavioral changes in the HTTPD should be verified against mvsMF. The mvsMF repo lives at the same level (`../mvsmf/`) and its test suites (`tests/curl-datasets.sh`, `tests/curl-jobs.sh`) exercise the CGI interface extensively.
