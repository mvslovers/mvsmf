#!/usr/bin/env python3
"""Does a browser fetch() pop the native Basic-auth dialog on a 401?

The measurement behind mvsMF's one deliberate deviation from the reference
z/OSMF: it sends WWW-Authenticate: Basic on every 401, we withhold it from a
browser fetch. This is why. Keep the probe so the question is re-measurable
rather than re-argued.

The behaviour is the browser's, not mvsMF's, so this needs no deploy and no
MVS. The page and the endpoints are same-origin, which is exactly the Desktop's
situation.

    python3 tests/probe-401-dialog.py      then open http://127.0.0.1:8099/

/challenge  -> 401 WITH  WWW-Authenticate: Basic
/bare       -> 401 WITHOUT the header  (the control)

RESULT, Chrome, 2026-08-19 (mvsmf#324):

    fetch /challenge  credentials:include   dialog: YES   401 after 6080 ms
    XMLHttpRequest /challenge               dialog: YES   401 after 4805 ms
    fetch /challenge  credentials:omit      dialog: no
    fetch /bare       credentials:include   dialog: no     <- control

The elapsed time is the finding, not the dialog alone. A 401 from 127.0.0.1
resolves in single-digit milliseconds; 6080 ms is how long a human took to
dismiss the dialog, so THE RESPONSE IS WITHHELD until then. The page's own
401 handling -- the Desktop's mvsmf:session-expired event -- never runs.

The quiet control is what makes this a measurement rather than an anecdote: the
dialog is tied to the challenge header, not to the status.

credentials:'omit' suppressing it corrects httpd#119's "no reliable client-side
trick suppresses the native dialog". There is one; it is just useless here,
because without credentials the session cookie is not sent either and every
request would 401.

Not measured: whether satisfying the dialog seeds a Basic cache that outlives
the token logout. /challenge rejects every credential by design, so it cannot
show it, and it does not change the decision.
"""
import http.server

PAGE = """<!doctype html><meta charset=utf-8><title>401 dialog probe</title>
<style>body{font:14px system-ui;margin:2rem;max-width:44rem}
button{display:block;margin:.4rem 0;padding:.5rem .8rem;font:inherit}
pre{background:#f4f4f4;padding:1rem;white-space:pre-wrap}</style>
<h1>401 dialog probe</h1>
<p>Click each button and watch for the browser's own credential dialog.
The log tells you whether the JavaScript ever saw the response.</p>
<button onclick="go('/challenge','include')">1. WITH challenge, credentials: include &mdash; the SPA's case</button>
<button onclick="go('/challenge','omit')">2. WITH challenge, credentials: omit</button>
<button onclick="go('/bare','include')">3. WITHOUT challenge (control &mdash; no dialog expected)</button>
<button onclick="xhr()">4. WITH challenge, via XMLHttpRequest</button>
<pre id=log></pre>
<script>
const log = m => document.getElementById('log').textContent += m + "\\n";
/* The elapsed time is the measurement, not a label: a local 401 resolves in
   single-digit milliseconds, so anything in the hundreds or thousands means the
   response waited for a human to dismiss the dialog. */
const verdict = ms => ms < 150
  ? 'resolved IMMEDIATELY -- the dialog did not block it'
  : 'WAITED -- the response was blocked until the dialog was dismissed';
async function go(path, cred) {
  log(`--> fetch ${path} credentials:${cred}`);
  const t0 = performance.now();
  try {
    const r = await fetch(path, {credentials: cred});
    const ms = Math.round(performance.now() - t0);
    log(`    status ${r.status} after ${ms} ms -- ${verdict(ms)}`);
  } catch (e) { log(`    fetch rejected: ${e}`); }
}
function xhr() {
  log('--> XMLHttpRequest /challenge');
  const t0 = performance.now();
  const x = new XMLHttpRequest();
  x.open('GET', '/challenge', true);
  x.onloadend = () => {
    const ms = Math.round(performance.now() - t0);
    log(`    status ${x.status} after ${ms} ms -- ${verdict(ms)}`);
  };
  x.send();
}
</script>"""


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/challenge') or self.path.startswith('/bare'):
            self.send_response(401)
            if self.path.startswith('/challenge'):
                self.send_header('WWW-Authenticate', 'Basic realm="MVS"')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        body = PAGE.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *a):
        print("   %s %s" % (self.command, self.path))


print("http://127.0.0.1:8099/   (Ctrl+C to stop)")
http.server.HTTPServer(('127.0.0.1', 8099), H).serve_forever()
