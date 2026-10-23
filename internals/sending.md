# `send_all()` -- what it depends on

Moved verbatim from `CLAUDE.md` on 2026-10-19; `CLAUDE.md` keeps the rules every session needs and points here.

Read before touching `send_all()`, `src/sendall.c`, `abort_response()` or the error path of a send.

Three things this depends on that fail silently if broken. The ECB handed to
`cthread_timed_wait()` is zeroed on the waiting frame **every** time; an
already-posted ECB that outlives one wait makes every later wait return
instantly, which is the busy spin again. The reason `send_all()` marks the
client `CSTATE_DONE` on failure is not tidiness — without it the handler's
error path comes straight back through `sendErrorResponse()` and pays the whole
10 s budget again for a peer that is already gone (httpd#203). And it must
clear `keepalive` in the same breath: `CSTATE_DONE` is *normal completion*, so
httpd walks `DONE → REPORT → RESET` and `httprese()` reuses the socket if the
flag is still set — appending the next response to a body that is short of the
Content-Length it announced. A hang traded for a corrupt stream is not a fix.
Both flags are cleared by `abort_response()` (`common.c`), together with
`chunked`: left set, httpd's `httpdone()` closes a chunked body with a clean
`0\r\n\r\n`, and a read error mid-body reaches the client as a complete-looking
200 (#421 — every data set GET is chunked). httpd's own send path already
clears `chunked` when a send fails; the read-error callers in `dsapi.c` had
nothing that did.

The loop lives in its own TU only so `TSTSEND` (`test/host/tstsend.c`) drives
the real one on the host; its four MVS/httpd services are injected through
`SEND_OPS`. Until the Hercules X'75' fix (`mvslovers/hyperion` `1a599b0d`) a
full send buffer froze the emulated CPU rather than returning `EWOULDBLOCK`,
which is the only reason this never fired before 2026-08-18.

Quiesce is asked on a **stalled** send only (`SEND_OPS.stopping`), never on entry;
the entry guard is the dead-client test (`SEND_OPS.dead`) alone. The two were
one test until #398, and a quiescing server then refused every send, so the 503
that answers a console `P HTTPD` went out as headers announcing a body that
never followed. A buffer the socket takes at once costs a stopping server
nothing; what it must not do is wait out the 10 s budget with shutdown waiting
for the worker. `test/host/tstsend.c` pins both halves.
