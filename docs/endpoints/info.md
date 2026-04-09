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

## Error Responses
- HTTP 500 (Internal Server Error)
    - Failed to parse host name or port

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
