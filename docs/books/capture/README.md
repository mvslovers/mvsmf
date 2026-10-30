# Capture scripts

`capture/<chapter>.sh` records the sessions of the chapter `guide/ug-<chapter>.typ`
against a running mvsMF and writes them to `ex/ug-<chapter>/`. The books show
those files; none of them is typed by hand. `lib.sh` documents the environment.

```sh
MVSMF_URL=http://localhost:8080 MVSMF_USER=... MVSMF_PASS=... sh capture/data.sh
```

`capture/jobs-held.sh` records the sessions of one section of the jobs chapter,
"A Purge That Is Only Requested" (`ex/ug-jobs/j-held-*.txt`). It starts and
cancels a punch device, so it runs on a throwaway system only.

`capture/uss-readfail.sh` records the session of one section of the UNIX files
chapter, "A Read That Fails Part-Way" (`ex/ug-uss/u-readfail-log.txt`). It
stops UFSD in the middle of a download and starts it again, so it runs on a
throwaway system only.

`ex/ug-first/open-authenticate.txt` and `ex/ug-first/open-jobs.txt` (section
"Every user is refused") have no script. They were recorded by hand on a
throwaway TK5 system whose RAKF had no user and no profile table, with
HTTPD 4.5.1 or later running, so HTTPD refused every login.
