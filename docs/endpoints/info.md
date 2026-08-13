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

## Error Responses

None. A `Host` header that cannot be parsed is logged to the console
(`MVSMF01E`/`MVSMF02E`/`MVSMF03E`) and falls back to the defaults above; the request still
returns 200. `/zosmf/info` is the unauthenticated liveness probe every client calls first
and must not fail on a header quirk (issue #175).

## Examples

### Using curl
```bash
curl http://mvs:1080/zosmf/info
```

### Success Response
```json
{
    "zosmf_hostname": "mvs.example.org",
    "zosmf_port": "1080",
    "zosmf_version": "1.0",
    "zosmf_full_version": "V1R0M0",
    "zosmf_saf_realm": "SAFRealm",
    "api_version": "1",
    "zos_version": "MVS 3.8j"
}
```
