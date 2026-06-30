
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

- **Datasets** — list, read, write, create, delete (sequential + volume-qualified)
- **PDS members** — list, read, write, delete
- **Jobs** — submit (inline JCL or dataset), status, spool files, spool records, purge
- **USS files** — list, read, write, create, delete
- **Console services** — issue operator commands, collect responses, detect
  unsolicited messages, read the hardcopy log

See **[docs/endpoints/](docs/endpoints/README.md)** for the full endpoint
reference and **[docs/examples.md](docs/examples.md)** for copy‑paste curl & Zowe
CLI examples for every endpoint.

## Installation

> **Note:** mvsMF is **Work in Progress** and not intended for production use.

### Prerequisites

- An MVS 3.8j system (TK4‑, TK5, MVSCE, or local Hercules)
- **httpd** ≥ `4.0.0-dev` installed and configured — the console services need
  the `cgictx` API introduced in the httpd 4.x line

### Install

The simplest path is `make deploy` (see *Building* below): it uploads and
RECEIVEs the load library into your httpd LINKLIB automatically. To install a
released XMIT manually:

1. Transfer the **XMIT** file to your MVS system and restore it:
   ```text
   RECEIVE INDATASET('your.xmit.dataset')
   ```
2. Copy the `MVSMF` load module into the `LINKLIB` your httpd server loads from.
3. Map the CGI in your httpd parmlib member:
   ```text
   MOD=MVSMF /zosmf/*
   ```
4. Restart the httpd server.

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
