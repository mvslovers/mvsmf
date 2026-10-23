# Capture scripts

`capture/<chapter>.sh` records the sessions of the chapter `guide/ug-<chapter>.typ`
against a running mvsMF and writes them to `ex/ug-<chapter>/`. The books show
those files; none of them is typed by hand. `lib.sh` documents the environment.

```sh
MVSMF_URL=http://localhost:8080 MVSMF_USER=... MVSMF_PASS=... sh capture/data.sh
```
