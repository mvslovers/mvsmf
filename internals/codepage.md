# Codepages: where the tables live, who translates, how to change one

Moved verbatim from `CLAUDE.md` on 2026-10-19; `CLAUDE.md` keeps the codepage table and the rule.

Read before translating a payload or changing a codepage.

### Where the tables live

**Not in this repo.** There is no `src/xlate.c` and no local table — both were
removed in `edad0e5` (#114/#115) and dropped from the link list in `13acfbf`.
The tables live in **libhttpd** and are reached through the httpx vector:
`httpx->xlate_cp037`, `xlate_1047`, `xlate_legacy` (`HTTPCP *`, each with an
`atoe` and an `etoa` member — see `.mbt/deps/httpd/include/httpxlat.h`).

`httpx` is not a variable you declare — `include/router.h:31` defines it as
`#define httpx http_get_httpx(session->httpd)`, so it resolves wherever a
`session` is in scope. mvsMF never calls `http_xlate_init()` and never selects a
codepage globally: **selection is per call site**, by naming the field.

```c
/* USS payload, EBCDIC -> ASCII on the way out */
http_xlate((unsigned char *)buf, n, httpx->xlate_1047->etoa);

/* dataset payload, ASCII -> EBCDIC on the way in */
http_xlate((unsigned char *)body, body_len, httpx->xlate_cp037->atoe);
```

### Who translates what

- **`http_printf()` translates for you.** It goes through `http_printv()`, which
  applies `http_etoa()` with the *server-default* table. Response headers and
  JSON bodies built with `http_printf` need no explicit call — and must not be
  pre-translated, or they get converted twice.
- **`send_all()` does not translate.** It sends the buffer raw and expects the
  caller to have produced ASCII already. (Neither does the `http_send()` under
  it — which nothing outside `common.c` may call, see **Sending** below.)
- **Raw bytes are always yours.** Every explicit `http_xlate()` in this repo sits
  on payload crossing a boundary — outbound before `send_all()` (`dsapi.c:236`,
  `ussapi.c:741`), inbound after reading a body or a chunk header
  (`dsapi.c:1528`, `ussapi.c:847`), or before writing a record to a data set
  (`dsapi.c:754`). None of them wrap a `http_printf()`.

So the rule is: **payload bytes are yours to translate, formatted output is
httpd's.**

### Changing a codepage

A codepage change is an **httpd-side change**, not a local edit — there is no
local table to edit. The order is: change the table in httpd → cut/refresh the
httpd release → `mbt deps --update` in mvsMF (updates `mbt.lock`) → rebuild and
`mbt deploy`. Editing anything in mvsMF alone cannot change a codepage.
