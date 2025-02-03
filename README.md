# FXServer-LSS
This repository contains a shell script (`fxserver-setup.sh`) that automates the setup of a vanilla FXServer (FiveM) on Linux. The script uses gum for interactive prompts and automatically retrieves the latest FXServer build from FiveM’s changelog API. It also offers an option to enable txAdmin mode (running FXServer in a detached screen session) for advanced server management.

## Features
- **Interactive Setup:** Uses gum for user-friendly input prompts.
- **Automatic Build Retrieval:** Fetches the latest FXServer build URL from FiveM’s changelog API.
- **Automated Installation:** Downloads, extracts, and sets up the server binaries and server-data.
- **Configuration Generation:** Creates a default server.cfg file with your provided license key.
- **txAdmin Support:** Optionally launches FXServer in monitor mode (inside a detached screen session) with txAdmin options.
- **asy Startup:** Prompts you to start the server immediately or later, with instructions on how to attach to the screen session.

### Installation
1. Download the script:
```bash
curl -sSL https://raw.githubusercontent.com/juddisjudd/FXServer-LSS/refs/heads/main/fxserver-setup.sh -o fxserver-setup.sh
chmod +x fxserver-setup.sh
```
2. Run the script:
```bash
./fxserver-setup.sh
```

### Usage
**When you run the script, it will prompt you for the following configuration:**
- **FXServer Base Directory:** The directory where you want to install FXServer (e.g., `~/FXServer`).
- **License Key:** Your FXServer license key.
- **txAdmin Mode:** Whether you want to run txAdmin for server administration.

**After confirming your inputs, the script will:**
- Create the necessary directories.
- Download and extract the latest FXServer build.
- Clone the `cfx-server-data` repository.
- Generate a default `server.cfg` file (with your license key included).
- Optionally launch FXServer in a detached screen session (if txAdmin mode is enabled).

### Starting the Server
If you choose to start the server immediately, the script will run the server as follows:

**txAdmin Mode:** Launches with a command similar to:
```bash
screen -dmS FXServer "$SERVER_DIR/server/run.sh" +set serverProfile FXServer +set txAdminPort 40121
```
**Normal Mode:** Launches with:
```bash
bash "$SERVER_DIR/server/run.sh" +exec server.cfg
```

To view the server console when running in screen mode, attach with:
```bash
screen -r FXServer
```

### Troubleshooting
- **No Output on Start:** When using screen mode, the server runs in a detached session. Attach to the session with screen -r FXServer to view output.
- **txAdmin Issues:** txAdmin requires FXServer to be run in monitor mode. Ensure the server is started without the +exec parameter when txAdmin is enabled.
- **Prerequisite Failures:** If any commands (like curl, jq, or git) are missing, install them manually or verify that your package manager is working correctly.

### Acknowledgments
- [charmbracelet/gum](https://github.com/charmbracelet/gum) – for providing interactive shell components.