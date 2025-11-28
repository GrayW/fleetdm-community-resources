#!/bin/zsh --no-rcs

verify_pkg_signature() {
  local pkg_path="$1"
  local expected_team_id="T4SK8ZXCXG"
  local expected_name="Mac Admins Open Source"

  # Get signing info
  local spctl_output
  spctl_output=$(spctl -a -vv -t install "$pkg_path" 2>&1)

  # Check for team ID and developer name
  if [[ "$spctl_output" == *"origin=Developer ID Installer: $expected_name ($expected_team_id)"* ]]; then
    echo "Signature verified: $expected_name ($expected_team_id)"
    return 0
  else
    echo "ERROR: Package signature verification failed!"
    echo "$spctl_output"
    return 1
  fi
}

curl https://raw.githubusercontent.com/waderobson/s3-auth/master/middleware_s3.py -o /usr/local/munki/middleware_s3.py --create-dirs

touch /Users/Shared/.com.googlecode.munki.checkandinstallatstartup

# Download and install the latest Munki release
MUNKI_PKG_URL=$(curl -s https://api.github.com/repos/munki/munki/releases/latest \
  | grep "browser_download_url" \
  | grep ".pkg" \
  | cut -d '"' -f 4 | head -n 1)

if [[ -n "$MUNKI_PKG_URL" ]]; then
  TMP_PKG="/tmp/munki-latest.pkg"
  echo "Downloading Munki from $MUNKI_PKG_URL"
  curl -L "$MUNKI_PKG_URL" -o "$TMP_PKG"

  echo "Verifying package signature..."
  if verify_pkg_signature "$TMP_PKG"; then
    echo "Installing Munki..."
    sudo installer -pkg "$TMP_PKG" -target /
    rm "$TMP_PKG"
  else
    echo "Aborting installation due to failed signature verification."
    rm "$TMP_PKG"
    exit 1
  fi
else
  echo "Failed to find Munki .pkg download URL."
  exit 1
fi

# Download and install the latest Munki middleware
MIDDLEWARE_PKG_URL=$(curl -s https://api.github.com/repos/munki/S3Middleware/releases/latest \
  | grep "browser_download_url" \
  | grep ".pkg" \
  | cut -d '"' -f 4 | head -n 1)

if [[ -n "$MIDDLEWARE_PKG_URL" ]]; then
  TMP_PKG="/tmp/middleware-latest.pkg"
  echo "Downloading Munki middleware from $MIDDLEWARE_PKG_URL"
  curl -L "$MIDDLEWARE_PKG_URL" -o "$TMP_PKG"
  echo "Installing Munki middleware..."
  sudo installer -pkg "$TMP_PKG" -target /
  rm "$TMP_PKG"
else
  echo "Failed to find Munki middleware .pkg download URL."
  exit 1
fi