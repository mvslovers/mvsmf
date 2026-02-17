# mvsMF REST API Endpoints

z/OSMF-compatible REST API for MVS 3.8j. All endpoints require Basic Auth unless noted otherwise.

## System Information

| Method | Path | Description |
|--------|------|-------------|
| GET | [`/zosmf/info`](info.md) | System information (no auth required) |

## Jobs (`/zosmf/restjobs/jobs`)

| Method | Path | Description |
|--------|------|-------------|
| GET | [`/zosmf/restjobs/jobs`](jobs/list.md) | List jobs |
| PUT | [`/zosmf/restjobs/jobs`](jobs/submit.md) | Submit job (inline JCL or dataset reference) |
| GET | [`/zosmf/restjobs/jobs/{name}/{id}`](jobs/status.md) | Job status |
| DELETE | [`/zosmf/restjobs/jobs/{name}/{id}`](jobs/purge.md) | Purge job |
| GET | [`/zosmf/restjobs/jobs/{name}/{id}/files`](jobs/files.md) | List spool files |
| GET | [`/zosmf/restjobs/jobs/{name}/{id}/files/{ddid}/records`](jobs/records.md) | Read spool file content |

## Datasets (`/zosmf/restfiles/ds`)

| Method | Path | Description |
|--------|------|-------------|
| GET | [`/zosmf/restfiles/ds`](datasets/list.md) | List datasets |
| GET | [`/zosmf/restfiles/ds/{name}`](datasets/get.md) | Read sequential dataset |
| PUT | [`/zosmf/restfiles/ds/{name}`](datasets/put.md) | Write sequential dataset |

Volume-specific variants: `/zosmf/restfiles/ds/-({volser})/{name}` for GET and PUT.

## PDS Members (`/zosmf/restfiles/ds`)

| Method | Path | Description |
|--------|------|-------------|
| GET | [`/zosmf/restfiles/ds/{name}/member`](datasets/members-list.md) | List PDS members |
| GET | [`/zosmf/restfiles/ds/{name}({member})`](datasets/members-get.md) | Read PDS member |
| PUT | [`/zosmf/restfiles/ds/{name}({member})`](datasets/members-put.md) | Write PDS member |

## Common Headers

| Header | Used By | Description |
|--------|---------|-------------|
| `X-IBM-Data-Type` | Dataset/member GET & PUT | `text` (default), `binary`, `record` |
| `X-IBM-Intrdr-Mode` | Job submit | Validated but fixed to `TEXT` |
| `X-IBM-Intrdr-Lrecl` | Job submit | Validated but fixed to `80` |
| `X-IBM-Intrdr-Recfm` | Job submit | Validated but fixed to `F` |
