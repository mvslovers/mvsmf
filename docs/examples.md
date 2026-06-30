# mvsMF API Examples (curl & Zowe CLI)

Working `curl` and [Zowe CLI](https://docs.zowe.org/) examples for every mvsMF
endpoint. Endpoints mirror the z/OSMF REST API, so standard Zowe commands work
against mvsMF.

## Setup

mvsMF speaks **plain HTTP** (no TLS). Replace the placeholders with your system:

```bash
HOST=mvsdev.lan      # MVS host running httpd + mvsMF
PORT=1080            # mvsMF API port
USER=IBMUSER         # MVS user id
PASS=sys1            # password
BASE="http://$HOST:$PORT"
```

**Zowe** — configure a `zosmf` profile once (note `--protocol http`), then the
commands below need no connection flags:

```bash
zowe config init        # or: edit ~/.zowe/zowe.config.json
# host=$HOST  port=$PORT  user=$USER  password=$PASS
# protocol=http  rejectUnauthorized=false  basePath=
```

Or pass them ad hoc on any command:

```bash
zowe files list ds "SYS1.*" \
  --host $HOST --port $PORT --user $USER --password $PASS \
  --protocol http --reject-unauthorized false
```

---

## System Information

### Get system info (no auth)
`GET /zosmf/info`

```bash
curl -s "$BASE/zosmf/info"
```
```bash
zowe zosmf check status
```

---

## Datasets — `/zosmf/restfiles/ds`

### List datasets by level
`GET /zosmf/restfiles/ds?dslevel=<level>`

```bash
curl -s -u $USER:$PASS "$BASE/zosmf/restfiles/ds?dslevel=SYS1.MAC*"
```
```bash
zowe files list ds "SYS1.MAC*"
```

### Read a sequential dataset
`GET /zosmf/restfiles/ds/{dataset-name}`

```bash
curl -s -u $USER:$PASS "$BASE/zosmf/restfiles/ds/IBMUSER.TEST.DATA"
# binary (no EBCDIC->ASCII):   -H 'X-IBM-Data-Type: binary'
```
```bash
zowe files view ds "IBMUSER.TEST.DATA"
```

### Write a sequential dataset
`PUT /zosmf/restfiles/ds/{dataset-name}`

```bash
curl -s -u $USER:$PASS -X PUT --data-binary @local.txt \
  "$BASE/zosmf/restfiles/ds/IBMUSER.TEST.DATA"
```
```bash
zowe files upload ftds ./local.txt "IBMUSER.TEST.DATA"
```

### Create a dataset
`POST /zosmf/restfiles/ds/{dataset-name}`

```bash
curl -s -u $USER:$PASS -X POST -H 'Content-Type: application/json' \
  -d '{"dsorg":"PS","recfm":"FB","lrecl":80,"blksize":3120,"primary":1,"alcunit":"TRK"}' \
  "$BASE/zosmf/restfiles/ds/IBMUSER.TEST.DATA"
```
```bash
zowe files create ps "IBMUSER.TEST.DATA" --recfm FB --lrecl 80 --blksize 3120 --size 1TRK
# a PDS:   zowe files create pds "IBMUSER.TEST.PDS" --recfm FB --lrecl 80 --dirblks 5 --size 1TRK
```

### Delete a dataset
`DELETE /zosmf/restfiles/ds/{dataset-name}`

```bash
curl -s -u $USER:$PASS -X DELETE "$BASE/zosmf/restfiles/ds/IBMUSER.TEST.DATA"
```
```bash
zowe files delete ds "IBMUSER.TEST.DATA" -f
```

> **Volume-qualified variant** for uncataloged datasets (GET/PUT/DELETE):
> `/zosmf/restfiles/ds/-(<volser>)/{dataset-name}`, e.g.
> `curl -s -u $USER:$PASS "$BASE/zosmf/restfiles/ds/-(WORK01)/IBMUSER.TEST.DATA"`.

---

## PDS Members — `/zosmf/restfiles/ds`

### List members
`GET /zosmf/restfiles/ds/{dataset-name}/member`

```bash
curl -s -u $USER:$PASS "$BASE/zosmf/restfiles/ds/IBMUSER.TEST.PDS/member"
```
```bash
zowe files list all-members "IBMUSER.TEST.PDS"
```

### Read a member
`GET /zosmf/restfiles/ds/{dataset-name}({member-name})`

```bash
curl -s -u $USER:$PASS "$BASE/zosmf/restfiles/ds/IBMUSER.TEST.PDS(TESTMBR)"
```
```bash
zowe files view ds "IBMUSER.TEST.PDS(TESTMBR)"
```

### Write a member
`PUT /zosmf/restfiles/ds/{dataset-name}({member-name})`

```bash
curl -s -u $USER:$PASS -X PUT --data-binary @local.txt \
  "$BASE/zosmf/restfiles/ds/IBMUSER.TEST.PDS(TESTMBR)"
```
```bash
zowe files upload ftds ./local.txt "IBMUSER.TEST.PDS(TESTMBR)"
```

### Delete a member
`DELETE /zosmf/restfiles/ds/{dataset-name}({member-name})`

```bash
curl -s -u $USER:$PASS -X DELETE "$BASE/zosmf/restfiles/ds/IBMUSER.TEST.PDS(TESTMBR)"
```
```bash
zowe files delete ds "IBMUSER.TEST.PDS(TESTMBR)" -f
```

---

## Jobs — `/zosmf/restjobs/jobs`

### List jobs
`GET /zosmf/restjobs/jobs?owner=<o>&prefix=<p>`

```bash
curl -s -u $USER:$PASS "$BASE/zosmf/restjobs/jobs?owner=*&prefix=TESTJOB*"
# also: ?status=OUTPUT   ?jobid=JOB00123   header: X-IBM-Max-Items: 50
```
```bash
zowe jobs list jobs --owner "*" --prefix "TESTJOB*"
```

### Submit a job (inline JCL)
`PUT /zosmf/restjobs/jobs` (Content-Type `text/plain`)

```bash
curl -s -u $USER:$PASS -X PUT -H 'Content-Type: text/plain' \
  --data-binary @job.jcl "$BASE/zosmf/restjobs/jobs"
```
```bash
zowe jobs submit local-file ./job.jcl
```

### Submit a job (from a dataset)
`PUT /zosmf/restjobs/jobs` (Content-Type `application/json`)

```bash
curl -s -u $USER:$PASS -X PUT -H 'Content-Type: application/json' \
  -d '{"file":"'\''IBMUSER.JCL(MYJOB)'\''"}' "$BASE/zosmf/restjobs/jobs"
```
```bash
zowe jobs submit data-set "IBMUSER.JCL(MYJOB)"
```

### Job status
`GET /zosmf/restjobs/jobs/{job-name}/{jobid}`

```bash
curl -s -u $USER:$PASS "$BASE/zosmf/restjobs/jobs/MYJOB/JOB00123"
```
```bash
zowe jobs view job-status-by-jobid JOB00123
```

### List spool files
`GET /zosmf/restjobs/jobs/{job-name}/{jobid}/files`

```bash
curl -s -u $USER:$PASS "$BASE/zosmf/restjobs/jobs/MYJOB/JOB00123/files"
```
```bash
zowe jobs list spool-files-by-jobid JOB00123
```

### Read a spool file
`GET /zosmf/restjobs/jobs/{job-name}/{jobid}/files/{ddid}/records`

```bash
curl -s -u $USER:$PASS "$BASE/zosmf/restjobs/jobs/MYJOB/JOB00123/files/2/records"
```
```bash
zowe jobs view spool-file-by-id JOB00123 2
```

### Purge a job
`DELETE /zosmf/restjobs/jobs/{job-name}/{jobid}`

```bash
curl -s -u $USER:$PASS -X DELETE "$BASE/zosmf/restjobs/jobs/MYJOB/JOB00123"
```
```bash
zowe jobs delete job JOB00123
```

---

## USS Files — `/zosmf/restfiles/fs`

### List a directory
`GET /zosmf/restfiles/fs?path=<path>`

```bash
curl -s -u $USER:$PASS "$BASE/zosmf/restfiles/fs?path=/tmp"
```
```bash
zowe files list uss-files "/tmp"
```

### Read a file
`GET /zosmf/restfiles/fs/{filepath}`

```bash
curl -s -u $USER:$PASS "$BASE/zosmf/restfiles/fs/tmp/hello.txt"
# binary:   -H 'X-IBM-Data-Type: binary'
```
```bash
zowe files view uss-file "/tmp/hello.txt"
```

### Write a file
`PUT /zosmf/restfiles/fs/{filepath}`

```bash
curl -s -u $USER:$PASS -X PUT --data-binary @local.txt \
  "$BASE/zosmf/restfiles/fs/tmp/hello.txt"
```
```bash
zowe files upload ftu ./local.txt "/tmp/hello.txt"
```

### Create a file or directory
`POST /zosmf/restfiles/fs/{filepath}`

```bash
curl -s -u $USER:$PASS -X POST -H 'Content-Type: application/json' \
  -d '{"type":"directory"}' "$BASE/zosmf/restfiles/fs/tmp/newdir"
# a file:   -d '{"type":"file"}'
```
```bash
zowe files create uss-directory "/tmp/newdir"
zowe files create uss-file "/tmp/newdir/file.txt"
```

### Delete a file or directory
`DELETE /zosmf/restfiles/fs/{filepath}`

```bash
curl -s -u $USER:$PASS -X DELETE "$BASE/zosmf/restfiles/fs/tmp/hello.txt"
# recursive (non-empty dir):   -H 'X-IBM-Option: recursive'
```
```bash
zowe files delete uss-file "/tmp/hello.txt" -f
zowe files delete uss-file "/tmp/newdir" -r -f      # recursive
```

---

## Console Services — `/zosmf/restconsoles`

The console name is a logical handle (`defcn` below). See
[Console endpoints](endpoints/console/) for the full contract.

### Issue a command
`PUT /zosmf/restconsoles/consoles/{console-name}`

```bash
curl -s -u $USER:$PASS -X PUT -H 'Content-Type: application/json' \
  -d '{"cmd":"D T"}' "$BASE/zosmf/restconsoles/consoles/defcn"
# solicited-keyword: add  "sol-key":"DATE"   async: add  "async":"Y"
```
```bash
zowe zos-console issue command "D T"
zowe zos-console issue command "D T" --solicited-keyword "DATE"
```

### Collect a command response (deltas)
`GET /zosmf/restconsoles/consoles/{console-name}/solmsgs/{cmd-response-key}`

```bash
curl -s -u $USER:$PASS \
  "$BASE/zosmf/restconsoles/consoles/defcn/solmsgs/E2E82A699B2B2001"
```
```bash
zowe zos-console collect sync-responses E2E82A699B2B2001
```

### Detect a keyword in unsolicited messages
`GET /zosmf/restconsoles/consoles/{console-name}/detections/{detection-key}`

Arm it on the issue command with `unsol-key`, then poll the returned key.
*(No standard Zowe CLI command — curl only.)*

```bash
# arm (async) -> returns "detection-key"
curl -s -u $USER:$PASS -X PUT -H 'Content-Type: application/json' \
  -d '{"cmd":"S FTPD","unsol-key":"FTPD"}' \
  "$BASE/zosmf/restconsoles/consoles/defcn"

# poll
curl -s -u $USER:$PASS \
  "$BASE/zosmf/restconsoles/consoles/defcn/detections/D2E82AB1"
```

### Get messages from the hardcopy log
`GET /zosmf/restconsoles/v1/log`

```bash
curl -s -u $USER:$PASS "$BASE/zosmf/restconsoles/v1/log?timeRange=10m"
# anchor + direction:  ?time=2026-06-30T03:32:00Z&timeRange=5m&direction=forward
```
```bash
zowe zos-logs list logs --range 10m
zowe zos-logs list logs --start-time 2026-06-30T03:32:00Z --range 5m --direction forward
```

> mvsMF reads the log from the in-memory Master Trace Table, so timestamps are
> the system's **local** wall clock (labelled `Z`). Anchor a `--start-time` on
> a value you copied from a previous response and it round-trips.

---

## Tips

- **Pretty-print** JSON: append ` | jq .` (or `| python3 -m json.tool`).
- **Show HTTP status**: add `-w '\n%{http_code}\n'` to curl.
- **Zowe JSON output**: add `--rfj` (response-format-json) to any command.
- **Trace** a Zowe/curl call through mvsMF: `tests/trace-zowe.sh --proxy "<cmd>"`.
