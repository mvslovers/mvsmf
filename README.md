
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
every console message mvsMF can write, and **[docs/jesspool.md](docs/jesspool.md)**
explains who may see, read and purge which job.

## Installation

> **Security note — what is authorized, and what is only authenticated.**
> Every endpoint requires a valid userid. The data set services check that
> userid against RACF/RAKF before every open. `restjobs` decides per job: a
> job of the caller's own userid is always allowed, a job of another owner
> needs a profile in the RAKF class `JESSPOOL` (READ to list and read, UPDATE
> to purge), and without profiles nobody sees the jobs of others, see
> [docs/jesspool.md](docs/jesspool.md) and
> [#440](https://github.com/mvslovers/mvsmf/issues/440). `restconsoles`
> and `/zosmf/test` are gated by mvsMF itself: both need READ on the RAKF
> resource `FACILITY MVSMF.CONSOLE`, and a user without it gets `500`
> (Authorization). **Define that profile and grant READ — until you do, both
> refuse every user**, administrators included; that is the upgrade behaviour
> of this version, see
> [Who may use the console service](docs/installation.md#who-may-use-the-console-service-and-zosmftest)
> ([#347](https://github.com/mvslovers/mvsmf/issues/347)). A user with READ can
> issue **any** operator command through `PUT /zosmf/restconsoles/consoles/{name}`
> — it goes out by SVC 34 from console 0, the master console, with the text
> unfiltered — and reading the whole Master Trace Table through
> `GET /zosmf/restconsoles/v1/log`; there is no per-command policy. The
> diagnostic endpoint `/zosmf/test` can issue commands too and is compiled in
> by default.
>
> On a system where not every userid is trusted at the operator console, build
> with `-DMVSMF_NO_TEST_ENDPOINT` to leave `/zosmf/test` unregistered.

### Prerequisites

- An MVS 3.8j system (TK4‑, TK5, MVSCE, or local Hercules)
- **httpd** ≥ `4.2.0` installed and configured. **This is a hard floor, not a
  recommendation:** mvsMF reaches the server through the HTTPX function vector
  and cannot test at run time whether an entry is there
  ([#363](https://github.com/mvslovers/mvsmf/issues/363)). The token login uses
  `http_new_session()`, added in 4.2.0; an older server has no entry at that
  offset, and the login abends the CGI. Below 4.0.1 it is worse:
  `http_realm`, which builds the `WWW-Authenticate` challenge, is missing too,
  and **every unauthenticated request abends the CGI with S0C4**. The client
  sees a truncated 401, and the console fills with `External program MVSMF
  failed with S0C4 ABEND`. On a server you did not install yourself, the
  startup message `HTTPD001I HTTPD <version> READY` names the level. From a
  client, `printf 'GET / HTTP/9.9\r\n\r\n' | nc <host> <port>` answers
  **505** on a recent build and 500 on a very old one. It cannot tell 4.2.0
  from 4.1.x.

  mvsMF is a separate load module with its own statically linked runtime, so
  relinking the server does nothing for mvsMF and the other way round: both
  sides want to be current.
- **`DD:HASPCKPT` and `DD:HASPACE1` in the httpd STC procedure** — only when
  `$DSNPRFX` is not `SYS1`, see below
- JES2 usermod **`SYZJ201`** — required for the jobs API to report `retcode`

#### The two JES2 DDs

mvsMF reads the JES2 checkpoint and spool through libc370's `jesopen()`. As a
CGI module dispatched into httpd's task by the LINK SVC, mvsMF has no
allocations of its own. Since libc370 2.24.0, which mvsMF 1.4.0 is built
against, `jesopen()` needs no DD statements: without `HASPCKPT` and
`HASPACE1` in the step it allocates `SYS1.HASPCKPT` itself (through the
catalog, else on the online volume whose VTOC has it) and `SYS1.HASPACE` on
the spool volume the checkpoint names. The job endpoints therefore work on a
host server whose procedure carries neither DD.

A DD in the host server's STC procedure still takes precedence, and it is
still **required when JES2 runs with another `$DSNPRFX`**, because the
allocation only looks for the `SYS1` names:

```jcl
//HASPCKPT DD  DISP=SHR,DSN=SYS1.HASPCKPT
//HASPACE1 DD  DISP=SHR,DSN=SYS1.HASPACE
```

Substitute your own names. When neither the DDs nor the `SYS1` data sets are
there, **every** job endpoint answers HTTP 500
(`REASON_INCORRECT_JES_VSAM_HANDLE`); the console message libc370 writes
names both possible causes. The data set services are unaffected.

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

mvsMF ships as an **SMP Release 4** install package (FMID `TZMF140`).
**[docs/installation.md](docs/installation.md)** is the guide — it covers the
two install jobs, authorization (SVC 244, or an APF entry), the STEPLIB
concatenation, and the route definitions. [docs/uninstall.md](docs/uninstall.md)
is the way back out.

The short version of the configuration, which is the part people get wrong:

```text
MOD=MVSMF /zosmf/info                    AUTH=NONE
MOD=MVSMF /zosmf/services/authenticate   AUTH=NONE
MOD=MVSMF /zosmf/restconsoles/*          AUTH=TOKEN RES=FACILITY:MVSMF.CONSOLE
MOD=MVSMF /zosmf/*                       AUTH=TOKEN
```

**Order matters — first match wins**, so the three specific routes must
precede the catch-all. The console route needs READ on the RAKF resource
`FACILITY MVSMF.CONSOLE`, and so does mvsMF's own check in the handler (without
the profile both refuse everybody), see
[Who may use the console service](docs/installation.md#who-may-use-the-console-service-and-zosmftest).
`AUTH=NONE` on the first two is not a hole: both endpoints resolve the
caller themselves and answer 401 without a credential. `/zosmf/info` is
authenticated like every other route (#324), and the token login has to reach
its handler even when the login fails, to produce the z/OSMF-shaped 401 body.

A route line naming no mode at all registers as `AUTH=NONE (public)` and reads
that way in `/.dsrv?target=MOD` — a poor thing for an audit to find, which is
why all four say what they mean. To narrow access, protect the catch-all with
a resource check rather than widening the prefix:

```text
MOD=MVSMF /zosmf/*  AUTH=TOKEN RES=FACILITY:MVSMF.ACCESS
```

These four lines are in `MVSMF.SAMPLIB(MVSMFPRM)`. httpd's own
`samplib(HTTPPRM0)` has the same four since
[httpd#338](https://github.com/mvslovers/httpd/pull/338), merged after the httpd
4.3.0 release; the 4.3.0 sample still has three. Keep the two in step.

For development, `mbt deploy` (see *Building* below) uploads and RECEIVEs the
load module directly into `MVSMF.DEV.LINKLIB` — no SMP, and no install package.

## Building mvsMF

mvsMF uses **[mbt](https://github.com/mvslovers/mbt) 3** (MVS Build Tools). The
whole build runs **on your host** with the **cc370** toolchain (`cc370`, `as370`,
`ar370`, `ld370`) — MVS is only touched by `mbt deploy` and `mbt test --mvs`.

### Prerequisites

- **mbt 3** on the `PATH` (see mbt's installation guide)
- The **[cc370](https://github.com/mvslovers/cc370)** host toolchain (a GCC 3.4.6 fork)
- An MVS 3.8j system reachable over IP (for `mbt deploy` / `mbt doctor`)

### Quick Start

```bash
git clone https://github.com/mvslovers/mvsmf.git
cd mvsmf
mbt deps                 # resolve + stage dependencies (httpd, ufsd, crypto370)
mbt build                # cross-compile + link the MVSMF load module (on the host)
mbt test                 # run the host unit tests
mbt deploy               # XMIT + upload + RECEIVE into MVSMF.DEV.LINKLIB (touches MVS)
```

### Commands

| Command | Description |
|--------|-------------|
| `mbt build` | Build the `MVSMF` load module (host only) |
| `mbt deps` | Resolve + stage declared dependencies and plugins into `.mbt/` |
| `mbt test` / `mbt test --mvs` | Run the unit tests on the host / on MVS |
| `mbt deploy` | Pack → XMIT → upload → RECEIVE, then replace the member in `MVSMF.DEV.LINKLIB` (touches MVS) |
| `mbt run restart -- HTTPD` | Compress `MVSMF.DEV.LINKLIB` and restart HTTPD, which activates a deploy (plugin `mvslovers/mbt-stc`) |
| `mbt doctor` | Check the toolchain + MVS connectivity |
| `mbt compiledb` | Generate `compile_commands.json` for clangd |
| `mbt package` | Build the release artifacts in `dist/` |
| `mbt clean` / `mbt distclean` | Remove build outputs / everything incl. staged deps |

`mbt` alone lists every command.

### Dependencies

Declared in `mbt.toml` and pinned in `mbt.lock` (committed):

| Dependency | Purpose |
|------------|---------|
| `mvslovers/httpd` | Web server + client library (the CGI host and `http_*` API) |
| `mvslovers/ufsd` | Unix‑like filesystem server (the USS endpoints) |
| `mvslovers/crypto370` | base64 |
| `libc370` | C runtime (the cc370 sysroot, `-lc`) |

`mbt deps` resolves them from their GitHub Releases and writes `mbt.lock`; it
never moves a pin on its own (`mbt deps --update` does). To develop against an
unreleased dependency, use a gitignored `.mbt/deps.local.toml` override.

### Configuration

`mbt.toml` defines the project. The MVS system mbt deploys to is a *target* in
`~/.mbt/targets.toml`, set up once per machine (`mbt target import .env --name
<name>` converts an existing `.env`).

The REST test suites run through mbt and take their connection from the same
target — its mvsMF URL and user, and a session token, never the password:

```bash
mbt run rest-tests                     # all suites
mbt run rest-tests -- curl-datasets    # one of them
```

The authorization tests need a second, ordinary userid. Give the target a
further user `test2` for them; without one, that section is skipped:

```toml
[target.<name>.mvsmf.users.test2]
user     = "USER2"
password = { keychain = "mbt/<name>-test2" }
```

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
