#!/bin/bash
# fxserver-setup.sh
#
# This script automates the setup of a vanilla FXServer (FiveM) on Linux.
# It uses gum to prompt for configuration values and automatically downloads
# the latest FXServer build using the "latest_download" URL from FiveM's changelog.
#
# It also checks for prerequisites and auto-installs gum on Debian/Ubuntu.
#
# Usage: ./fxserver-setup.sh

set -e

# Function to check if a command exists; if not, exit with an error.
check_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: '$1' is not installed. Please install it and try again." >&2
    exit 1
  fi
}

# Check for prerequisites that we assume are available
for cmd in curl jq wget tar git xz; do
  check_cmd "$cmd"
done

# Check for gum; if missing and on Debian/Ubuntu, auto-install it.
if ! command -v gum >/dev/null 2>&1; then
  if [ -f /etc/debian_version ]; then
    echo "gum is not installed. Installing gum on Debian/Ubuntu..."
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/charm.gpg
    echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list
    sudo apt update && sudo apt install -y gum
  else
    echo "gum is not installed. Please install gum from https://github.com/charmbracelet/gum" >&2
    exit 1
  fi
fi

# Retrieve the latest FXServer build URL from FiveM's changelog API
JSON_URL="https://changelogs-live.fivem.net/api/changelog/versions/linux/server"
BUILD_URL=$(curl -s "$JSON_URL" | jq -r '.latest_download')
if [ -z "$BUILD_URL" ] || [ "$BUILD_URL" = "null" ]; then
  echo "Could not retrieve the latest FXServer download URL."
  exit 1
fi

# Prompt for configuration values using gum
SERVER_DIR=$(gum input --placeholder "Enter FXServer base directory (e.g., ~/FXServer)" --value "$HOME/FXServer")
LICENSE_KEY=$(gum input --placeholder "Enter your FXServer license key")
TXADMIN=$(gum confirm "Do you want to run txAdmin for server administration?" && echo "yes" || echo "no")

# Confirm settings with the user
gum confirm "Proceed with installation using the following settings?

Server Directory: $SERVER_DIR
Download URL:     $BUILD_URL
License Key:      $LICENSE_KEY
Run txAdmin:      $TXADMIN

Is that correct?" || { echo "Installation aborted."; exit 1; }

# Create necessary directories for server binaries and data
echo "Creating directories..."
mkdir -p "$SERVER_DIR/server" "$SERVER_DIR/server-data"

# Download the FXServer build using the latest_download URL
echo "Downloading FXServer build..."
cd "$SERVER_DIR/server" || exit 1
wget "$BUILD_URL" -O fx.tar.xz

# Extract the downloaded build
echo "Extracting FXServer build..."
tar xf fx.tar.xz

# Clone the cfx-server-data repository
echo "Cloning cfx-server-data repository..."
git clone https://github.com/citizenfx/cfx-server-data.git "$SERVER_DIR/server-data"

# Create a server.cfg file in the server-data folder with basic settings
CFG_FILE="$SERVER_DIR/server-data/server.cfg"
echo "Creating server.cfg..."
cat > "$CFG_FILE" <<EOF
# Network endpoints – adjust IP if needed.
endpoint_add_tcp "0.0.0.0:30120"
endpoint_add_udp "0.0.0.0:30120"

# Default resources to start
ensure mapmanager
ensure chat
ensure spawnmanager
ensure sessionmanager
ensure basic-gamemode
ensure hardcap
ensure rconlog

sv_scriptHookAllowed 0

# Server tags and locale
sets tags "default"
sets locale "en-US"

# Server hostname and project details
sv_hostname "FXServer, but unconfigured"
sets sv_projectName "My FXServer Project"
sets sv_projectDesc "Default FXServer requiring configuration"

# OneSync and player slot limit
set onesync on
sv_maxclients 48

# Steam Web API key (if using Steam auth)
set steam_webApiKey ""

# License key for your server
sv_licenseKey "${LICENSE_KEY}"
EOF

# Prompt for MariaDB installation/configuration
if gum confirm "Would you like to configure MariaDB for your FXServer?"; then
    # Check if MariaDB is already installed
    if ! command -v mysql >/dev/null 2>&1; then
        echo "MariaDB is not installed. Installing MariaDB..."
        if [ -f /etc/debian_version ]; then
            # Install MariaDB on Debian/Ubuntu
            sudo apt update
            sudo apt install -y mariadb-server
        else
            echo "Please install MariaDB manually for your distribution"
            exit 1
        fi
        
        # Run secure installation for fresh installs
        echo "Running secure installation for MariaDB..."
        sudo mysql_secure_installation
        
        # Wait briefly after secure installation
        sleep 2
    else
        echo "MariaDB is already installed."
    fi

    # Prompt for database configuration
    DB_NAME=$(gum input --placeholder "Enter database name (e.g., fxserver)")
    DB_USER=$(gum input --placeholder "Enter database user (e.g., fxserver)")
    DB_PASS=$(gum input --placeholder "Enter database password" --password)

    # Check if database already exists
    DB_EXISTS=$(sudo mysql -e "SHOW DATABASES LIKE '${DB_NAME}';" | grep -o "${DB_NAME}")
    USER_EXISTS=$(sudo mysql -e "SELECT User FROM mysql.user WHERE User='${DB_USER}';" | grep -o "${DB_USER}")
    
    if [ "${DB_EXISTS}" = "${DB_NAME}" ]; then
        echo "Database '${DB_NAME}' already exists."
        if gum confirm "Would you like to recreate the database? (This will delete all existing data)"; then
            echo "Dropping and recreating database..."
            sudo mysql -e "DROP DATABASE ${DB_NAME};"
            sudo mysql -e "CREATE DATABASE ${DB_NAME};"
        fi
    else
        echo "Creating database..."
        sudo mysql -e "CREATE DATABASE ${DB_NAME};"
    fi

    if [ "${USER_EXISTS}" = "${DB_USER}" ]; then
        echo "User '${DB_USER}' already exists."
        if gum confirm "Would you like to reset the user's password?"; then
            echo "Updating user password..."
            sudo mysql -e "ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
        fi
    else
        echo "Creating database user..."
        sudo mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';"
        sudo mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';"
        sudo mysql -e "FLUSH PRIVILEGES;"
    fi

    # Add database configuration to server.cfg if it doesn't already exist
    if ! grep -q "mysql_connection_string" "$CFG_FILE"; then
        echo "Adding database configuration to server.cfg..."
        cat >> "$CFG_FILE" <<EOF

# Database configuration
set mysql_connection_string "mysql://${DB_USER}:${DB_PASS}@localhost/${DB_NAME}?charset=utf8mb4"
EOF
    else
        echo "Database configuration already exists in server.cfg"
        if gum confirm "Would you like to update the database configuration?"; then
            sed -i '/mysql_connection_string/c\set mysql_connection_string "mysql://${DB_USER}:${DB_PASS}@localhost/${DB_NAME}?charset=utf8mb4"' "$CFG_FILE"
        fi
    fi

    echo "MariaDB configuration complete!"
    sleep 2
fi

# Print txAdmin note if enabled
if [ "$TXADMIN" = "yes" ]; then
  echo "Note: TXAdmin is enabled. The server will start with txAdmin support (+set txAdminPort 40121)."
fi

# Ask about starting the server
if gum confirm "Installation complete. Do you want to start the FXServer now?"; then
  echo "Starting FXServer..."
  cd "$SERVER_DIR/server-data" || exit 1
  if [ "$TXADMIN" = "yes" ]; then
    # Launch in screen (txAdmin requires monitor mode; do not use +exec)
    screen -dmS FXServer "$SERVER_DIR/server/run.sh" +set serverProfile FXServer +set txAdminPort 40121
  else
    # Launch normally with server.cfg loaded
    bash "$SERVER_DIR/server/run.sh" +exec server.cfg
  fi
else
  echo "Setup complete. To start your server later, run:"
  if [ "$TXADMIN" = "yes" ]; then
    echo "cd \"$SERVER_DIR/server-data\" && screen -dmS FXServer \"$SERVER_DIR/server/run.sh\" +set serverProfile FXServer +set txAdminPort 40121"
  else
    echo "cd \"$SERVER_DIR/server-data\" && bash \"$SERVER_DIR/server/run.sh\" +exec server.cfg"
  fi
fi