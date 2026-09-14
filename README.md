
# mvsMF

**mvsMF** is an implementation of the z/OSMF REST API for the classic **MVS 3.8j**.
It lets modern clients — the **Zowe Explorer** for VS Code and JetBrains IDEs, and
the **Zowe CLI** — work with datasets, PDS members, jobs, USS files and the system
console on a classic MVS host through the standard z/OSMF endpoints.

mvsMF runs as a **CGI module** under the **httpd** web server and is built on the
**libc370** C runtime (the maintained successor to CRENT370). A huge thanks goes
to **Mike Rayborn**, whose HTTPD server and original CRENT370 libraries this work
builds on.

## Features

- **Datasets** — list, read, write, create, delete (sequential and partitioned)
- **PDS members** — list, read, write, delete
- **Jobs** — submit (inline JCL or dataset), status, spool files, spool records, purge
- **USS files** — list, read, write, create, delete
- **Console services** — issue operator commands, collect responses, detect
  unsolicited messages, read the hardcopy log

See **[docs/endpoints/](docs/endpoints/README.md)** for the full endpoint
reference and **[docs/examples.md](docs/examples.md)** for copy‑paste curl & Zowe
CLI examples for every endpoint. **[docs/messages.md](docs/messages.md)** lists
every console message mvsMF can write.

## Installation

> **Security note — what is authorized, and what is only authenticated.**
> Every endpoint requires a valid userid. The data set services check that
> userid against RACF/RAKF before every open; `restjobs` and `restconsoles` do
> not — for them, authentication is the *only* gate there is. On jobs that means
> a client can widen `owner=` to `*` and read or purge another user's spool
> output ([#345](https://github.com/mvslovers/mvsmf/issues/345); MVS 3.8j
> security products have no JESSPOOL class to delegate that to). On consoles it
> means more: any user who can log in can issue **any** operator command through
> `PUT /zosmf/restconsoles/consoles/{name}` — it goes out by SVC 34 from console
> 0, the master console, with the text unfiltered — and can read the whole
> Master Trace Table through `GET /zosmf/restconsoles/v1/log`. The diagnostic
> endpoint `/zosmf/test?fn=cmd` is the same power through a second door and is
> compiled in by default. There is no per-command policy yet
> ([#347](https://github.com/mvslovers/mvsmf/issues/347)).
>
> On a system where not every userid is trusted at the operator console:
> register the prefixes you want instead of `/zosmf/*` — httpd matches a route
> per `MOD=` line, so several lines can name the same module — and build with
> `-DMVSMF_NO_TEST_ENDPOINT` to leave `/zosmf/test` unregistered.

### Prerequisites

- An MVS 3.8j system (TK4‑, TK5, MVSCE, or local Hercules)
- **httpd** ≥ `4.0.2` installed and configured. **4.0.1 is a hard floor, not a
  recommendation:** mvsMF reaches the server through the HTTPX function vector,
  and the `http_realm` entry it uses to build the `WWW-Authenticate` challenge
  is the last member of that vector, added in 4.0.1. On an older server the
  call reads past the end of the table and **every unauthenticated request
  abends the CGI with S0C4** — the client sees a truncated 401 and the console
  fills with `External program MVSMF failed with S0C4 ABEND`
  ([#363](https://github.com/mvslovers/mvsmf/issues/363)). A quick check on a
  server you did not install yourself: `printf 'GET / HTTP/9.9\r\n\r\n' | nc
  <host> <port>` answers **505** on a current build and 500 on one that predates
  it.

  4.0.2 on top of that floor is the release that carries the libc370 1.0.4 stdio
  fixes into the server. mvsMF is a separate load module with its own statically
  linked runtime, so relinking one does nothing for the other: both sides want
  to be current.
- **`DD:HASPCKPT` and `DD:HASPACE1` in the httpd STC procedure** — see below
- JES2 usermod **`SYZJ201`** — required for the jobs API to report `retcode`

#### The two JES2 DDs

mvsMF reads the JES2 checkpoint and spool through libc370's `jesopen()`, which
opens them **by ddname**. As a CGI module dispatched into httpd's task by the
LINK SVC, mvsMF has no allocations of its own — the two DDs have to be in the
**host server's** STC procedure:

```jcl
//HASPCKPT DD  DISP=SHR,DSN=SYS1.HASPCKPT
//HASPACE1 DD  DISP=SHR,DSN=SYS1.HASPACE
```

Substitute your own names if `$DSNPRFX` is not `SYS1`. Without them **every**
job endpoint answers HTTP 500 (`REASON_INCORRECT_JES_VSAM_HANDLE`) and writes
two console lines per request — and nothing on either side of the boundary
points at the cause, which is what made mvslovers/httpd#256 expensive to
diagnose. The data set services are unaffected.

#### The `SYZJ201` usermod

Stock MVS 3.8j records no job completion code where JES2 can be asked for it.
`SYZJ201` (source member `SYZYGY1A`, `COPY`ed into `HASPSSSM`) closes that gap:
at job termination it takes the highest step completion code and stores it in
`JCTCNVRC`, stamped with a `0x77` marker. That field is what mvsMF decodes into
`"CC 0000"`, `"ABEND S806"` and friends.

Without it, **`retcode` is `null` for every job**, however the job ended.
Clients that poll for a completion code — `zowe jobs submit --wait-for-output`,
Zowe Explorer's job monitor — never see one.

It ships in [`usermods/SYZJ2001.jcl`](https://github.com/MVS-sysgen/sysgen/blob/main/usermods/SYZJ2001.jcl)
of the MVS-sysgen project, which installs **two** SYSMODs: `SYZJ201` is the one
mvsMF needs, and `SYZJ202` (`SYZYGY1B` into `HASPPRPU`) only adds the
`- MAX COND CODE nnnn` text to the `$HASP395` job-log line. Installing both is
the normal case.

**The SMF exit `IEFACTRT` is *not* required**, and the one you are most likely
to have cannot help even if you assume it is. `SYZYGY1A` reads `JCTJSTAT`,
`JCTACODE` and the SCT chain directly and never touches `SCTNSMSG`, so nothing
in an SMF exit feeds it. Two `IEFACTRT` variants are in circulation:

- **`JLM0001`** — what MVS/CE installs (`++MOD(IEFACTRT)` against FMID
  `EBB1102`, no JES2 change). It is a **reporting exit only**: it references no
  `JCT`, no `SCT`, no `JCTCNVRC`, and writes nothing back anywhere. All it
  produces is the `IEFACTRT` job-log line and the step-statistics block.
- **CBT tape 887** — passes codes back to JES2 through `SCTNSMSG`/`JMRUCOM`.
  That is an *alternative* route to a completion code, not a companion to
  `SYZJ201`, and mvsMF reads neither of the fields it sets.

**Do not read the job-log line as evidence.** `IEFACTRT` prints the step's
return code — `/00012/` — from its own parameter list, whether or not the value
ever reaches the JCT. A job without `NOTIFY` shows `/00012/` in the log and
still answers `"retcode": null`; the line is the exit reporting, not the system
recording.

Check whether the usermod is applied:

```jcl
//LIST    EXEC SMPAPP
//SMPCNTL  DD  *
  LIST CDS SYSMOD(SYZJ201) .
/*
```

`TYPE = USERMOD` with `STATUS = REC  APP` means it is installed. RC 04 and an
empty list means it is not.

**One caveat survives the usermod:** it runs only for jobs whose card carries
`NOTIFY`, because `HASPSSSM` gates the whole block on it. mvsMF therefore adds
`NOTIFY=$MVSMF` to any card submitted through `PUT /zosmf/restjobs/jobs` that
has none — a placeholder userid deliberately, because a *defined* notify target
consumes a `SYS1.BRODCAST` mail record per job, and 84 of those piled up in a
single afternoon of running this project's test suite. A job that reaches JES2 by some other route still reports `null`.
See [Job Status → Limitations](docs/endpoints/jobs/status.md#limitations).

### Install

mvsMF ships as an **SMP Release 4** install package (FMID `TZMF110`).
**[docs/installation.md](docs/installation.md)** is the guide — it covers the
two install jobs, the APF entry the library needs, the STEPLIB concatenation,
and the route definitions. [docs/uninstall.md](docs/uninstall.md) is the way
back out.

The short version of the configuration, which is the part people get wrong:

```text
MOD=MVSMF /zosmf/info                    AUTH=NONE
MOD=MVSMF /zosmf/services/authenticate   AUTH=NONE
MOD=MVSMF /zosmf/*                       AUTH=TOKEN
```

**Order matters — first match wins**, so the two specific routes must precede
the catch-all. `AUTH=NONE` on them is not a hole: both endpoints resolve the
caller themselves and answer 401 without a credential. `/zosmf/info` is
authenticated like every other route (#324), and the token login has to reach
its handler even when the login fails, to produce the z/OSMF-shaped 401 body.

A route line naming no mode at all registers as `AUTH=NONE (public)` and reads
that way in `/.dsrv?target=MOD` — a poor thing for an audit to find, which is
why all three say what they mean. To narrow access, protect the catch-all with
a resource check rather than widening the prefix:

```text
MOD=MVSMF /zosmf/*  AUTH=TOKEN RES=FACILITY:MVSMF.ACCESS
```

These three lines are the same ones in httpd's own `samplib(HTTPPRM0)` and in
`MVSMF.SAMPLIB(MVSMFPRM)`; keep them in step.

For development, `make deploy` (see *Building* below) uploads and RECEIVEs the
load library directly — no SMP, and no install package.

## Building mvsMF

mvsMF uses **[mbt](https://github.com/mvslovers/mbt) v2** (MVS Build Tools). The
whole build runs **on your host** with the **cc370** toolchain (`cc370`, `as370`,
`ar370`, `ld370`) — MVS is only touched by `make deploy`.

### Prerequisites

- The **[cc370](https://github.com/mvslovers/cc370)** host toolchain (a GCC 3.4.6 fork)
- **Python 3.12+**
- An MVS 3.8j system reachable over IP (for `make deploy` / `make doctor`)

### Quick Start

```bash
git clone --recursive https://github.com/mvslovers/mvsmf.git
cd mvsmf
cp .env.example .env     # edit with your MVS connection details
make deps                # resolve + stage dependencies (httpd, ufsd)
make                     # cross-compile + link the MVSMF load module (on the host)
make deploy              # XMIT + upload + RECEIVE into the httpd LINKLIB (touches MVS)
```

### Make Targets

| Target | Description |
|--------|-------------|
| `make` | Build the `MVSMF` load module (host only) |
| `make deps` | Resolve + stage declared dependencies into `.mbt/deps` |
| `make deploy` | Pack → XMIT → upload → RECEIVE into the LINKLIB (touches MVS) |
| `make test` / `make test-mvs` | Build (and run on MVS) the test suites |
| `make doctor` | Check the toolchain + MVS connectivity |
| `make compiledb` | Generate `compile_commands.json` for clangd |
| `make package` | Build the release artifacts in `dist/` |
| `make clean` / `make distclean` | Remove build outputs / everything incl. staged deps |
| `make help` | List all targets |

### Dependencies

Declared in `project.toml` and pinned in `mbt.lock` (committed):

| Dependency | Purpose |
|------------|---------|
| `mvslovers/httpd` | Web server + client library (the CGI host and `http_*` API) |
| `mvslovers/ufsd` | Unix‑like filesystem server (the USS endpoints) |
| `libc370` | C runtime (the cc370 sysroot, `-lc`) |

`make deps` resolves `httpd`/`ufsd` from their GitHub Releases and writes
`mbt.lock`. To develop against an unreleased dependency, use a gitignored
`.mbt/deps.local.toml` override.

### Configuration

`project.toml` defines the project; local MVS connection settings go in `.env`
(never committed — copy `.env.example`).

| Variable | Description |
|----------|-------------|
| `MBT_MVS_HOST` | IP or hostname of the MVS system |
| `MBT_MVS_PORT` | mvsMF API port |
| `MBT_MVS_USER` / `MBT_MVS_PASS` | MVS userid / password |
| `MBT_MVS_HLQ` | HLQ for build/deploy datasets |
| `MBT_MVS_DEPS_HLQ` | HLQ for staged dependency datasets |
| `MBT_JES_JOBCLASS` / `MBT_JES_MSGCLASS` | JES job / message class for deploy jobs |

See `.env.example` for the full list.

## Usage

Point [Zowe CLI](https://docs.zowe.org/) or an IDE plugin (Zowe Explorer) at your
MVS 3.8j host — note that mvsMF speaks **plain HTTP** (`--protocol http`). You can
then list and edit datasets and PDS members, submit and monitor jobs, browse USS
files, and issue console commands or read the hardcopy log.

Ready‑to‑run curl and Zowe commands for every endpoint are in
**[docs/examples.md](docs/examples.md)**.

## Acknowledgments

This project builds on the incredible work of **Mike Rayborn** — his HTTPD server
and the original CRENT370 libraries (continued as **libc370**) are at the core of
this implementation. A huge thank you for your contributions to the MVS community!

## Contributing

Contributions are welcome! If you're interested in helping with development,
testing, or documentation, feel free to open an issue or submit a pull request.

## License

This project is licensed under the [MIT License](LICENSE)

---

**Disclaimer**: This project is still under active development and is not ready for production use. Use it at your own risk and report any issues or feedback to help improve it.
