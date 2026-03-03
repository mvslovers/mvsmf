
# mvsMF

**mvsMF** is a implementation of the z/OSMF REST API for the classic MVS 3.8j. The project provides essential functionality of z/OSMF, focusing on key endpoints for dataset and job handling. This allows users to use modern clients such as the Zowe Explorer for Visual Studio Code (or JetBrains IDEs) and Zowe CLI to interact with their host datasets, submit jobs, and view job outputs on MVS 3.8j.

This project is implemented as a **CGI module** for Mike Rayborn's HTTPD server and relies on his **CRENT370 libraries** for efficient system interaction. A huge thanks goes to Mike Rayborn for his invaluable contributions to the MVS community.

## Features

- **Dataset Handling**: Access, create, update, and delete datasets.
- **Job Management**: Submit jobs, check their status, and retrieve their output.

## Installation

> **Note**: This project is currently a **Work in Progress** and is not intended for production use.

### Prerequisites

- MVS 3.8j system
- Mike Rayborn's HTTPD version >= 3.3.0 installed and configured

### Steps

1. Transfer the provided **XMIT file** to your MVS system.
2. Restore the XMIT file to create the necessary load module:

   ```bash
   RECEIVE INDATASET('your.xmit.dataset') 
   ```

3. Copy the the load module from the received dataset into the `LINKLIB` dataset used by your HTTPD server.
4. Update your HTTPD configuration file to include the following entry:

   ```bash
   cgi.MVSMF="/zosmf/*"
   ```

5. Restart the HTTPD server.

## Building mvsMF

### Prerequisites

- An MVS 3.8j system reachable via IP (TK4-, TK5, MVSCE, or similar)
- `curl` and `jq` installed on the build host
- The [c2asm370](https://github.com/mvslovers/c2asm370) cross-compiler

### Quick Start

```bash
git clone --recursive https://github.com/mvslovers/mvsmf.git
cd mvsmf
make bootstrap
make
```

`make bootstrap` sets up the build environment automatically:

1. Creates `.env` from `.env.example` if missing
2. Validates required configuration variables
3. Checks that `curl`, `jq`, and `c2asm370` are available
4. Initializes git submodules if needed
5. Creates a Docker network for container communication (if Docker is available)
6. Verifies connectivity and authentication to the MVS system
7. Allocates required datasets on MVS if they don't exist
8. Generates `compile_commands.json` for clangd

After bootstrap, edit `.env` with your MVS connection details if the defaults
don't match your setup.

### Make Targets

| Target | Description |
|--------|-------------|
| `make` | Cross-compile all C sources and assemble on MVS |
| `make link` | Link-edit all modules into a load module on MVS |
| `make install` | Copy load module into the target LINKLIB on MVS |
| `make package` | TRANSMIT load library to XMIT format and download it |
| `make bootstrap` | Set up the build environment (idempotent) |
| `make bootstrap PLAN=1` | Dry run — show what bootstrap would do without side effects |
| `make doctor` | Read-only diagnostics — check environment health |
| `make compiledb` | Regenerate `compile_commands.json` for clangd |
| `make run-mvs` | Start the MVS build container (see below) |
| `make stop-mvs` | Stop the MVS build container |
| `make clean` | Remove generated `.s`, `.o`, and JCL files |

### Configuration

All build configuration lives in `.env` (never committed). Copy `.env.example`
to get started — `make bootstrap` does this automatically.

Key variables:

| Variable | Description |
|----------|-------------|
| `MVSMF_HOST` | IP or hostname of the MVS system |
| `MVSMF_PORT` | mvsMF API port |
| `MVSMF_USER` | MVS userid |
| `MVSMF_PASS` | MVS password |
| `MVSMF_ASM_PUNCH` | Object deck PDS |
| `MVSMF_ASM_SYSLMOD` | NCAL library PDS |
| `MVSMF_LINK_LOAD` | Load library PDS |

See `.env.example` for the full list of variables.

## Development Environment

You can build mvsMF against any reachable MVS system — just configure `.env`
accordingly. For convenience, two Docker images are provided:

### MVS Build Container (`mvsce-builder`)

A headless MVSCE system with Hercules, ready for cross-compilation. Use this
when you don't have access to a dedicated MVS system.

```bash
make run-mvs       # creates or starts the container
make stop-mvs      # stops it
```

The container runs on the `mvs-net` Docker network. Set `MVSMF_HOST=mvs`
in your `.env` to connect to it (this is the default in `.env.example`).

### Development Container (`mvs-dev`)

A full development environment with `c2asm370`, `curl`, `jq`, `git`, `zowe`,
and Docker CLI pre-installed. Useful if you don't want to set up the toolchain
locally.

```bash
docker run -it --rm \
  -v "$(pwd)":/home/dev/workspace \
  -v /var/run/docker.sock:/var/run/docker.sock \
  ghcr.io/mvslovers/mvs-dev
```

From inside the dev container you can run `make run-mvs` to start the MVS
build container and `make bootstrap` to set up the build environment. Both
commands automatically create the Docker network and join the dev container
to it, so that `mvs` is reachable by name.

## Usage

Once installed, you can use tools like [Zowe CLI](https://docs.zowe.org/stable/user-guide/cli-installcli.html) or IDE plugins like Zowe Explorer to connect to your MVS 3.8j instance. You'll be able to:

- List datasets
- Submit and monitor jobs
- Retrieve and view job outputs

## Acknowledgments

This project wouldn't have been possible without the incredible work and support of **Mike Rayborn**. His HTTPD server and CRENT370 libraries are at the core of this implementation. A huge thank you for your contributions to the MVS community!

## Contributing

Contributions are welcome! If you're interested in helping with development, testing, or documentation, feel free to open an issue or submit a pull request.

## License

This project is licensed under the [MIT License](LICENSE)
---

**Disclaimer**: This project is still under active development and is not ready for production use. Use it at your own risk and report any issues or feedback to help improve it.
