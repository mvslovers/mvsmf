
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

If you'd like to build mvsMF from source, follow these steps:

1. Clone the repository:

   ```bash
   git clone --recursive https://github.com/mvslovers/mvsmf.git
   cd mvsmf
   ```

2. Make sure you have a cross-compilation environment for MVS 3.8j. You'll need:
   - CRENT370 libraries by Mike Rayborn - see <https://github.com/mvslovers/crent370>
   - A suitable C compiler configured for MVS 3.8j

3. Update any project path and project dataset in the Makefile

4. Compile the CGI module using the provided Makefile:

   ```bash
   make
   ```

5. Follow the installation steps to transfer the load module to your MVS system.

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
