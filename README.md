
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

mvsMF uses [mbt](https://github.com/mvslovers/mbt) (MVS Build Tools) for
cross-compilation, assembly, and linking on MVS.

### Prerequisites

- An MVS 3.8j system reachable via IP (TK4-, TK5, MVSCE, or similar)
- The [c2asm370](https://github.com/mvslovers/c2asm370) cross-compiler
- Python 3.12+

### Quick Start

```bash
git clone --recursive https://github.com/mvslovers/mvsmf.git
cd mvsmf
cp .env.example .env    # edit with your MVS connection details
make bootstrap          # resolve dependencies, allocate datasets
make build              # cross-compile and assemble on MVS
make link               # link-edit into load module
make install            # copy to target LINKLIB on MVS
```

### Make Targets

| Target | Description |
|--------|-------------|
| `make bootstrap` | Resolve dependencies, allocate MVS datasets |
| `make build` | Cross-compile C sources and assemble on MVS |
| `make link` | Link-edit all modules into a load module on MVS |
| `make install` | Copy load module into the target LINKLIB on MVS |
| `make package` | TRANSMIT load library to XMIT format and download |
| `make compiledb` | Generate `compile_commands.json` for clangd |
| `make clean` | Remove generated `.s` and `.o` files |
| `make distclean` | Full clean including mbt cache and stamps |

### Configuration

Project structure is defined in `project.toml`. Local MVS connection
settings go in `.env` (never committed). Copy `.env.example` to get started.

Key variables:

| Variable | Description |
|----------|-------------|
| `MBT_MVS_HOST` | IP or hostname of the MVS system |
| `MBT_MVS_PORT` | mvsMF API port |
| `MBT_MVS_USER` | MVS userid |
| `MBT_MVS_PASS` | MVS password |

See `.env.example` for the full list.

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
