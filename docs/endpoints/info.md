# System Information

Returns z/OSMF system information.

## HTTP Method
GET

## URL Path
`/zosmf/info`

## Authentication
Not required.

## Response
On successful completion, this request returns HTTP status code 200 (OK) and a JSON object with the following properties:

```json
{
    "zosmf_hostname": "string",
    "zosmf_port": "string",
    "zosmf_version": "1.0",
    "zosmf_full_version": "V1R0M0",
    "zosmf_saf_realm": "SAFRealm",
    "api_version": "1",
    "zos_version": "MVS 3.8j"
}
```

## Host and Port

`zosmf_hostname` and `zosmf_port` describe the endpoint **the client used**, not the
address the HTTPD listens on, so both are derived from the request headers:

| Request | `zosmf_port` |
|---|---|
| `Host: name:port` | that port |
| `Host: name`, `X-Forwarded-Port: p` | `p` |
| `Host: name`, `X-Forwarded-Proto: https` | `443` |
| `Host: name` | `80` |
| no `Host` header | `8080` |

A `Host` header without a port is valid — [RFC 7230 §5.4](https://www.rfc-editor.org/rfc/rfc7230#section-5.4)
leaves the port implied by the scheme — and is what browsers and reverse proxies send for
the default ports. Behind a TLS-terminating proxy mvsMF only ever sees plain HTTP on its
own connection, so the public scheme and port can only come from the proxy's
`X-Forwarded-*` headers.

`SERVER_PORT` is deliberately not consulted: it is the HTTPD's listen port, not the port
the client dialled.

`zosmf_hostname` follows the same rule and falls back to `127.0.0.1` when the header
carries no usable name — including the cases that have a colon but nothing in front of
it, `Host: :8080` and `Host: :::garbage:::`. Those used to be reported as an empty
string (issue #260). The two halves fall back independently: `Host: :8080` still yields
port `8080`.

## Error Responses

A `Host` header that cannot be parsed falls back to the defaults above and the request
still returns 200: this is the first call every client makes and it must not fail on a
header quirk (issue #175). Nothing is written to the console either — the client sent the
header, so there is nothing for an operator to act on, and a polling client would repeat
the message forever (issue #201).

**A credential-less request is answered `401`.** The endpoint was documented here as the
*unauthenticated* liveness probe until #324; it never was one. `identity_middleware` gates
every route but `/zosmf/services/authenticate`, and that matches the reference — a real
z/OSMF answers its own `/zosmf/info` with `401` and `WWW-Authenticate: Basic
realm="defaultRealm"`, on every endpoint, and does not drop the challenge even for a
client identifying itself with `X-CSRF-ZOSMF-HEADER`. Both measured. Do not add an
exemption.

## Deliberate deviations from the reference

Recorded so they are not read as bugs by the next person holding the two responses side
by side.

**`zosmf_hostname` and `zosmf_port` describe the endpoint the client reached us on, not
our own identity.** They are derived from `Host` and the `X-Forwarded-*` headers, so
`Host: totally.made.up:9999` is answered with `"zosmf_hostname":"totally.made.up"`. The
reference reports its own configured name instead — a client dialling one hostname gets a
different one back. Ours is deliberate (issues #175, #260): behind a TLS-terminating
reverse proxy the server's own name is the wrong answer for building self-referential
URLs and the forwarded one is right, a case the reference gets wrong. `http_server_name()`
is in the httpx vector if this is ever revisited.

**`zos_version` stays free text** (`MVS 3.8j`) where the reference sends a dotted numeric
(`05.29.00`). It is the truth, and no client parses it — Zowe prints it verbatim.

**`zosmf_version` is a bare major** (`1`), matching the reference's shape (`29`) rather
than its value; `zosmf_full_version` carries the real version. Clients compare the former
as a string — Zowe's `CheckStatus.isZosVersionAtLeast` evaluates `zosmf_version >= "27"`
— so `1` sorts below every z/OSMF level and clients pick their most conservative path.

## Examples

### Using curl
```bash
curl -u USER:PASS http://mvs:1080/zosmf/info
```

### Success Response
```json
{
    "zosmf_hostname": "mvs.example.org",
    "zosmf_port": "1080",
    "zosmf_version": "1",
    "zosmf_full_version": "1.0.0-dev",
    "plugins": [],
    "zosmf_saf_realm": "SAFRealm",
    "api_version": "1",
    "zos_version": "MVS 3.8j"
}
```

`plugins` is always empty — mvsMF has no plugin mechanism. The key is emitted rather than
omitted because the reference always sends it; `zowe zosmf check status` then prints an
empty list instead of a dangling heading.
