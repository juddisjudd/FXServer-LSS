#!/bin/bash
# fxserver-setup.sh
#
# This script automates the setup of FXServer (FiveM) on Linux.
# Supports both vanilla and recipe-based installations.
# Uses gum for interactive prompts and handles MariaDB setup.

set -e

# Function to check if a command exists
check_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: '$1' is not installed. Please install it and try again." >&2
    exit 1
  fi
}

# Check for prerequisites
for cmd in curl jq wget tar git xz yq; do
  check_cmd "$cmd"
done

# Check for gum; if missing and on Debian/Ubuntu, auto-install it
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

# Function to setup MariaDB
setup_mariadb() {
  local server_type=$1
  
  echo "Checking MariaDB installation..."
  
  # Generate secure random passwords
  DB_USER_PASSWORD=$(openssl rand -base64 16)
  
  # Set database name based on server type
  if [ "$server_type" = "ox_core" ]; then
    DB_NAME="overextended"
    DB_USER="overextended"
  else
    DB_NAME=$(gum input --placeholder "Enter database name (e.g., fxserver)" --value "fxserver")
    DB_USER=$(gum input --placeholder "Enter database user (e.g., fxserver)" --value "fxserver")
  fi
  
  # Check if MariaDB is already installed
  if ! dpkg -l | grep -q mariadb-server; then
    echo "Installing MariaDB..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y mariadb-server
    
    # Generate root password for fresh install
    DB_ROOT_PASSWORD=$(openssl rand -base64 16)
    
    # Start MariaDB service if not running
    sudo systemctl start mariadb
    sudo systemctl enable mariadb
    
    # Wait for MariaDB to be ready
    echo "Waiting for MariaDB to be ready..."
    for i in {1..30}; do
      if sudo mysqladmin ping &>/dev/null; then
        break
      fi
      sleep 1
    done
    
    # Set root password for fresh installation
    sudo mysql -e "
      SET PASSWORD FOR 'root'@'localhost' = PASSWORD('$DB_ROOT_PASSWORD');
      FLUSH PRIVILEGES;
    "
    
    # Secure the installation
    sudo mysql -uroot -p"$DB_ROOT_PASSWORD" -e "
      DELETE FROM mysql.user WHERE User='';
      DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
      DROP DATABASE IF EXISTS test;
      DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
      FLUSH PRIVILEGES;
    "
  else
    echo "MariaDB is already installed."
    # For existing installation, prompt for root password
    while true; do
      DB_ROOT_PASSWORD=$(gum input --password --placeholder "Enter existing MariaDB root password")
      if mysql -uroot -p"$DB_ROOT_PASSWORD" -e "SELECT 1" &>/dev/null; then
        break
      else
        echo "Invalid password. Please try again."
      fi
    done
  fi
  
  # Create database and user for FXServer
  mysql -uroot -p"$DB_ROOT_PASSWORD" -e "
    CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
    CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_USER_PASSWORD';
    GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
    FLUSH PRIVILEGES;
  "
  
  # Export variables to be used by other parts of the script
  export DB_NAME DB_USER DB_USER_PASSWORD
  
  # Verify database access
  if ! mysql -u"$DB_USER" -p"$DB_USER_PASSWORD" -e "USE \`$DB_NAME\`" &>/dev/null; then
    echo "Error: Unable to access database with created credentials. Please check MariaDB logs."
    exit 1
  fi
  
  # Display the credentials to the user
  echo
  gum style \
    --border double \
    --align center \
    --width 50 \
    --margin "1" \
    --padding "1" \
    "$(gum style --foreground 212 '📝 Database Credentials 📝')\n\n" \
    "$(gum style --foreground 255 "Database Name: ")$(gum style --bold "$DB_NAME")\n" \
    "$(gum style --foreground 255 "Database User: ")$(gum style --bold "$DB_USER")\n" \
    "$(gum style --foreground 255 "Database Password: ")$(gum style --bold "$DB_USER_PASSWORD")\n" \
    "$(gum style --foreground 255 "Root Password: ")$(gum style --bold "$DB_ROOT_PASSWORD")"
  
  echo
  gum style --foreground 203 "⚠️  IMPORTANT: Please copy these credentials and store them securely before continuing!"
  echo
  
  # Wait for user confirmation
  gum confirm "Have you saved these credentials?" || { 
    echo "Please make sure to save the credentials before proceeding."; 
    exit 1; 
  }
}

# Function to execute recipe tasks
execute_recipe_task() {
  local task="$1"
  local action=$(echo "$task" | yq e '.action' -)
  
  case "$action" in
    "download_github")
      local src=$(echo "$task" | yq e '.src' -)
      local ref=$(echo "$task" | yq e '.ref' -)
      local dest=$(echo "$task" | yq e '.dest' -)
      local subpath=$(echo "$task" | yq e '.subpath // ""' -)
      
      echo "Downloading from GitHub: $src"
      if [ -n "$subpath" ]; then
        svn export "https://github.com/$src/trunk/$subpath" "$dest"
      else
        git clone --depth 1 --branch "$ref" "https://github.com/$src.git" "$dest"
      fi
      ;;
      
    "download_file")
      local url=$(echo "$task" | yq e '.url' -)
      local path=$(echo "$task" | yq e '.path' -)
      
      echo "Downloading file: $url"
      wget "$url" -O "$path"
      ;;
      
    "unzip")
      local src=$(echo "$task" | yq e '.src' -)
      local dest=$(echo "$task" | yq e '.dest' -)
      
      echo "Extracting: $src to $dest"
      mkdir -p "$dest"
      unzip -q "$src" -d "$dest"
      ;;
      
    "move_path")
      local src=$(echo "$task" | yq e '.src' -)
      local dest=$(echo "$task" | yq e '.dest' -)
      
      echo "Moving: $src to $dest"
      mv "$src" "$dest"
      ;;
      
    "query_database")
      local file=$(echo "$task" | yq e '.file' -)
      
      echo "Executing SQL file: $file"
      mysql -u"$DB_USER" -p"$DB_USER_PASSWORD" "$DB_NAME" < "$file"
      ;;
      
    "replace_string")
      local file=$(echo "$task" | yq e '.file' -)
      local search=$(echo "$task" | yq e '.search // ""' -)
      local replace=$(echo "$task" | yq e '.replace // ""' -)
      local mode=$(echo "$task" | yq e '.mode // ""' -)
      
      if [ "$mode" = "all_vars" ]; then
        # Replace all variables in the format {{varName}}
        echo "Replacing variables in: $file"
        sed -i "s/{{serverName}}/$SERVER_NAME/g" "$file"
        sed -i "s/{{dbName}}/$DB_NAME/g" "$file"
        sed -i "s/{{dbUsername}}/$DB_USER/g" "$file"
        sed -i "s/{{dbPassword}}/$DB_USER_PASSWORD/g" "$file"
        sed -i "s/{{recipeName}}/ox_core/g" "$file"
        sed -i "s/{{recipeDescription}}/FXServer running ox_core/g" "$file"
        sed -i "s/{{maxClients}}/$MAX_CLIENTS/g" "$file"
      elif [ -n "$search" ] && [ -n "$replace" ]; then
        echo "Replacing string in: $file"
        sed -i "s|$search|$replace|g" "$file"
      fi
      ;;
      
    "remove_path")
      local path=$(echo "$task" | yq e '.path' -)
      
      echo "Removing: $path"
      rm -rf "$path"
      ;;
      
    *)
      echo "Unknown task action: $action"
      ;;
  esac
}

# Function to setup using recipe
setup_recipe() {
  local SERVER_DIR=$1
  local RECIPE_URL="https://raw.githubusercontent.com/overextended/txAdminRecipe/main/recipe.yaml"
  
  echo "Downloading recipe..."
  wget "$RECIPE_URL" -O "$SERVER_DIR/recipe.yaml"
  
  # Get recipe variables
  SERVER_NAME=$(gum input --placeholder "Enter server name" --value "My FX Server")
  MAX_CLIENTS=$(gum input --placeholder "Enter max clients" --value "48")
  
  # Create necessary directories
  mkdir -p "$SERVER_DIR/tmp"
  
  # Process each task in the recipe
  local tasks
  tasks=$(yq e '.tasks[]' "$SERVER_DIR/recipe.yaml")
  
  echo "$tasks" | while read -r task; do
    execute_recipe_task "$task"
  done
}

# Retrieve the latest FXServer build URL
JSON_URL="https://changelogs-live.fivem.net/api/changelog/versions/linux/server"
BUILD_URL=$(curl -s "$JSON_URL" | jq -r '.latest_download')
if [ -z "$BUILD_URL" ] || [ "$BUILD_URL" = "null" ]; then
  echo "Could not retrieve the latest FXServer download URL."
  exit 1
fi

# Prompt for server type
SERVER_TYPE=$(gum choose "vanilla" "ox_core")

# Prompt for configuration values
SERVER_DIR=$(gum input --placeholder "Enter FXServer base directory (e.g., ~/FXServer)" --value "$HOME/FXServer")
LICENSE_KEY=$(gum input --placeholder "Enter your FXServer license key")

# If ox_core selected, force txAdmin
if [ "$SERVER_TYPE" = "ox_core" ]; then
  TXADMIN="yes"
else
  TXADMIN=$(gum confirm "Do you want to run txAdmin for server administration?" && echo "yes" || echo "no")
fi

# Confirm settings with user
gum confirm "Proceed with installation using the following settings?

Server Type:      $SERVER_TYPE
Server Directory: $SERVER_DIR
Download URL:     $BUILD_URL
License Key:      $LICENSE_KEY
Run txAdmin:      $TXADMIN

Is that correct?" || { echo "Installation aborted."; exit 1; }

# Create base directory
mkdir -p "$SERVER_DIR"

# Setup MariaDB if requested
if gum confirm "Would you like to install and configure MariaDB for your server?"; then
  setup_mariadb "$SERVER_TYPE"
fi

# Download and extract FXServer
echo "Downloading FXServer build..."
mkdir -p "$SERVER_DIR/server"
cd "$SERVER_DIR/server" || exit 1
wget "$BUILD_URL" -O fx.tar.xz
echo "Extracting FXServer build..."
tar xf fx.tar.xz

# Setup server based on type
if [ "$SERVER_TYPE" = "ox_core" ]; then
  setup_recipe "$SERVER_DIR"
else
  # Vanilla setup
  echo "Setting up vanilla server..."
  mkdir -p "$SERVER_DIR/server-data"
  git clone https://github.com/citizenfx/cfx-server-data.git "$SERVER_DIR/server-data"
  
  # Create vanilla server.cfg
  cat > "$SERVER_DIR/server-data/server.cfg" <<EOF
endpoint_add_tcp "0.0.0.0:30120"
endpoint_add_udp "0.0.0.0:30120"

ensure mapmanager
ensure chat
ensure spawnmanager
ensure sessionmanager
ensure basic-gamemode
ensure hardcap
ensure rconlog

sv_scriptHookAllowed 0
sets tags "default"
sets locale "en-US"

sv_hostname "FXServer Vanilla"
sets sv_projectName "FXServer Vanilla"
sets sv_projectDesc "Default FXServer"

set onesync on
sv_maxclients 48
set steam_webApiKey ""
sv_licenseKey "$LICENSE_KEY"

# Database Configuration
set mysql_connection_string "user=$DB_USER;password=$DB_USER_PASSWORD;host=localhost;port=3306;database=$DB_NAME"
EOF
fi

# Cleanup
echo "Cleaning up temporary files..."
rm -rf "$SERVER_DIR/tmp"

# Start server
if gum confirm "Installation complete. Do you want to start the FXServer now?"; then
  echo "Starting FXServer..."
  cd "$SERVER_DIR/server-data" || exit 1
  if [ "$TXADMIN" = "yes" ]; then
    screen -dmS FXServer "$SERVER_DIR/server/run.sh" +set serverProfile FXServer +set txAdminPort 40121
  else
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
