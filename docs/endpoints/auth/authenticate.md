# Authentication Service

Token-based login and logout for z/OSMF and Zowe clients. Part of the z/OSMF
REST services API (`/zosmf/services`).

The token is httpd's opaque session identifier (`CREDTOK`, a `SHA-256` session
id) returned base64-encoded as the **`LtpaToken2`** cookie. Clients store it and
replay it on later requests — as the `LtpaToken2` cookie (the standard z/OSMF
transport) or as `Authorization: Bearer <token>` — instead of sending Basic
credentials on every call. It is **not** a real WebSphere LTPA token.

> **Division of labour:** httpd owns the credential *mechanism* — it resolves
> the `Authorization: Basic` header on the login call and accepts the token
> back on later requests — and exposes it to mvsMF through the HTTPX auth
> export. mvsMF owns only these two endpoints; it issues no `racf_login` of its
> own. See `mvslovers/httpd` `docs/auth-redesign.md`.

---

## Log in

### HTTP Method
POST

### URL Path
`/zosmf/services/authenticate`

### Request Headers
- `Authorization: Basic <base64(userid:password)>` (required) — the credentials
  to authenticate.
- `X-CSRF-ZOSMF-HEADER` — sent by z/OSMF/Zowe clients with any value or an empty
  string. mvsMF does **not** require or validate it (consistent with the rest of
  the mvsMF/httpd API, which does not enforce CSRF).
- `Content-Type: application/x-www-form-urlencoded` — sent by clients; the
  request body is empty and is ignored.

### Request Body
None.

### Response
On success, HTTP status code **200 (OK)** with:

- a `Set-Cookie: LtpaToken2=<token>; Path=/` header carrying the session token, and
- the z/OSMF login body:

```json
{
    "returnCode": 0,
    "reasonCode": 0,
    "message": "Success."
}
```

`Path=/` scopes the cookie to the whole `/zosmf` API. No `Secure` attribute is
set — the MVS deployment is plain HTTP.

### Error Responses
- HTTP **401 (Unauthorized)** — bad or missing credentials:

```json
{
    "returnCode": 8,
    "reasonCode": 1,
    "message": "Login failed. Check whether the user ID and password you use for the Basic Auth is correct, and if the user ID has the required SAF permissions."
}
```

  mvsMF does not distinguish expired-password / revoked-user sub-cases; every
  failure returns `returnCode 8, reasonCode 1` (the z/OSMF default when detailed
  login errors are not exposed).

- HTTP **500 (Internal Server Error)** — a server-side error (e.g. the token
  could not be encoded): `returnCode 4, reasonCode 40`.

---

## Log out

### HTTP Method
DELETE

### URL Path
`/zosmf/services/authenticate`

### Request Headers
- `Cookie: LtpaToken2=<token>` (or `Authorization: Bearer <token>`) — the token
  to invalidate.
- `X-CSRF-ZOSMF-HEADER` — as above; not required by mvsMF.

### Request Body
None.

### Response
On a request carrying a valid token, HTTP status code **204 (No Content)**, no
body. The `LtpaToken2` cookie is expired via `Set-Cookie: LtpaToken2=deleted;
Path=/; expires=Thu, 01 Jan 1970 00:00:00 GMT` and the handler calls
`http_logout()` to drop the credential from httpd's store.

A request **without** a valid token is rejected with **401** by httpd's auth
gate before it reaches the handler (the z/OSMF spec also requires a valid token
to log out). The handler itself is idempotent, but that only applies once httpd
forwards the request — see the notes below.

> **Known limitations (httpd side):**
> - Token invalidation currently does not take effect: `http_logout()` is a
>   no-op when called from a CGI, so the token still resolves after logout
>   (mvslovers/httpd#113). The handler logs `MVSMF32W` when invalidation fails.
> - Whether an unauthenticated request reaches this endpoint at all depends on
>   the httpd route policy (mvslovers/httpd#114).

---

## Examples

### Log in with curl (capture the cookie)
```bash
curl -i -X POST \
     -u IBMUSER:SYS1 \
     -H 'X-CSRF-ZOSMF-HEADER: *' \
     -c cookies.txt \
     http://mvs:1080/zosmf/services/authenticate
```

### Use the token on a later request
```bash
curl -b cookies.txt http://mvs:1080/zosmf/restfiles/ds?dslevel=SYS1.**
```

### Log out
```bash
curl -i -X DELETE \
     -H 'X-CSRF-ZOSMF-HEADER: *' \
     -b cookies.txt \
     http://mvs:1080/zosmf/services/authenticate
```

### Zowe CLI (token auth)
```bash
zowe config set 'profiles.mvs.properties.tokenType' LtpaToken2
zowe auth login zosmf --host mvs --port 1080 --user IBMUSER --password SYS1 --reject-unauthorized false
```
