#!/bin/zsh --no-rcs

# --- Configuration ---

# Safely determine the currently logged-in console user on macOS
CONSOLE_USER=$(stat -f %Su /dev/console)

# Check if a user was found
if [[ -z "$CONSOLE_USER" ]]; then
    echo "❌ Error: Could not determine the currently logged-in user. Exiting."
    exit 1
fi

# Directory to temporarily store the logs
TARGET_DIR="/tmp/fleetlogs"

# Source files explicitly listed.
SOURCE_FILES=(
    "/private/var/log/orbit/orbit.stdout.log"
    "/private/var/log/orbit/orbit.stderr.log"
    "/Users/${CONSOLE_USER}/Library/Logs/Fleet/fleet-desktop.log"
)

# Destination directory for the final zip file
DEST_PATH="/Users/Shared"

# --- Script Logic ---

# 1. Create the target directory
echo "1. Creating temporary directory: $TARGET_DIR"
mkdir -p "$TARGET_DIR"

# 2. Copy the source files to the target directory
echo "2. Copying logs for user '$CONSOLE_USER' to $TARGET_DIR"
cp -f "${SOURCE_FILES[@]}" "$TARGET_DIR"

# Check if the copy operation failed (e.g., if files were not found)
if [[ $? -ne 0 ]]; then
    echo "⚠️ Warning: One or more files may not have been found or copied successfully."
fi

# 3. Change permissions on the copied files to 777
echo "3. Changing permissions on copied files to 777"
chmod 777 "$TARGET_DIR"/*

# 4. Generate a timestamp for the zip file name
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
ZIP_FILE_NAME="FleetLogs${TIMESTAMP}.zip"
ZIP_FILE_PATH="${DEST_PATH}/${ZIP_FILE_NAME}"

# 5. Zip the contents of the temporary directory (not the directory itself)
echo "5. Creating zip archive: $ZIP_FILE_PATH"

# Store the current directory to return to later
CURRENT_DIR=$(pwd)

# Change directory to the target directory
cd "$TARGET_DIR" || { echo "❌ Error: Cannot change directory to $TARGET_DIR. Exiting." ; exit 1; }

# Create the zip file containing only the files inside this directory (*), 
# saving it directly to the final destination path.
# -q (quiet), -r (recursive - safe for files), * (all contents)
zip -q -r "$ZIP_FILE_PATH" *

# Change back to the original directory
cd "$CURRENT_DIR"

# 6. Clean up the temporary directory
echo "6. Cleaning up temporary directory: $TARGET_DIR"
rm -rf "$TARGET_DIR"

echo "---"
echo "✅ Script complete. Archive created at: $ZIP_FILE_PATH"

exit 0