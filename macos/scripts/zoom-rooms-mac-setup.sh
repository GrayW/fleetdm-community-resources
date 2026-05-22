#!/bin/bash
# zoom-rooms-mac-setup.sh
#
# First-boot setup script for an unattended (DEP/ADE-enrolled) Zoom Rooms
# Mac mini kiosk. Intended for use as a Fleet `setup_experience` macos_script
# (https://fleetdm.com/docs/configuration/yaml-files#macos-setup-experience)
# but works equally well as a Jamf "Run at enrollment" policy script or any
# other zero-touch enrollment workflow that runs commands as root once,
# AFTER the Zoom Rooms PKG has installed and BEFORE handing the device off
# to the login window.
#
# What this script does, in order:
#   1. Sets HostName/LocalHostName/ComputerName from a serial-number map
#      you maintain inline (see ROOM_MAP below).
#   2. Enables Apple Remote Management (ARD) ACLs for all local users.
#      Note: on macOS 12.1+ ARD also needs TCC ScreenCapture/PostEvent
#      rights, which only the MDM EnableRemoteDesktop command can grant.
#      Run that from your MDM after enrollment; this kickstart writes
#      the ACL bits that complement it.
#   3. (macOS Tahoe 26.5+) Enables `pmset autorestartatconnect` so the
#      kiosk powers itself back on when power is restored after an outage.
#   4. Installs a system LaunchAgent at
#      /Library/LaunchAgents/us.zoom.ZoomPresence.plist so ZoomPresence.app
#      starts automatically at every GUI login (the Zoom Rooms PKG does
#      not register a login item itself).
#   5. Sets the timezone, enables NTP, and turns on the auto-timezone
#      keys (timed + locationd preference dances) so a kiosk that ever
#      sees Wi-Fi can self-correct.
#   6. Creates a visible local kiosk admin user (default name: `zoomroom`)
#      via the mkuser one-shot launcher at https://run.mkuser.sh. The
#      account is set to auto-login, skip Setup Assistant, and *not*
#      grant a secure token (so FileVault never wants its password —
#      which matters because the password is plaintext in this script).
#   7. Sets Dark Mode for the new kiosk user by writing directly to
#      ~/Library/Preferences/.GlobalPreferences.plist (cfprefsd has no
#      session for a freshly-created user, so `defaults write -g` would
#      fail with "Could not write domain Apple Global Domain").
#   8. Schedules a self-deleting LaunchDaemon to fire `/sbin/reboot`
#      ~15 seconds after this script exits. On macOS Tahoe 26 SePOS
#      firmware, auto-login is disabled on the very first boot — a
#      reboot with kcpassword + autoLoginUser already on disk is the
#      only way to bootstrap unattended auto-login. The 15s delay
#      gives Fleet's orbit / Jamf's policy framework / etc. time to
#      ACK the script's success back to the MDM before the host reboots.
#
# ============================================================================
# *** YOU MUST EDIT THE CONFIG BLOCK BELOW BEFORE DEPLOYING ***
# ============================================================================
#
# In particular:
#   - ROOM_MAP: replace the example serials/names with your fleet's actual
#     hosts. Anything not in the map gets a "Zoom Room Mac (<serial>)"
#     fallback name and TZ_DEFAULT.
#   - KIOSK_PASSWORD: change from the example. This password ends up in
#     macOS's kcpassword for auto-login, which is "encoded" with a well-
#     known XOR key — treat it as plaintext. Pick something you're OK
#     with anyone who can pop /etc/kcpassword being able to read, and
#     scope the account's privileges accordingly (we keep it admin only
#     so on-site IT can use it as a break-glass; demote to standard if
#     that's not a requirement for you).
#   - KIOSK_ICON_URL + KIOSK_ICON_SHA256: optional. If you set both, the
#     image is downloaded, SHA-256 verified, and used as the user picture.
#     If KIOSK_ICON_URL is empty, the user is created without a custom
#     picture.
#   - TZ_DEFAULT: the IANA timezone for kiosks that aren't matched by a
#     more specific case in the TZ_MAP block.
#
# ============================================================================
# Tested on: macOS Tahoe 26.x on Mac mini M4 (Mac16,10) under Fleet's
# setup_experience macos_script in mid-2026. Should work unchanged on
# Sequoia 15.x, with the caveat that the `pmset autorestartatconnect`
# call will harmlessly no-op on Macs older than 2024.
#
# License: MIT
# ============================================================================

set -euo pipefail

# --------------------------------------------------------------------------
# CONFIG — edit these before deploying.
# --------------------------------------------------------------------------

# Kiosk user account. The password is recoverable from /etc/kcpassword
# (XOR'd with a well-known key) once auto-login is on — pick accordingly.
KIOSK_USERNAME="zoomroom"
KIOSK_FULLNAME="Zoom Room"
KIOSK_PASSWORD="CHANGE_ME_BEFORE_DEPLOY"

# Optional kiosk user picture. Set both URL and SHA256 (lower-case hex)
# to pin against tampering. Leave URL empty to skip the custom picture.
KIOSK_ICON_URL=""
KIOSK_ICON_SHA256=""

# IANA timezone used for any host not matched in the TZ_MAP below.
TZ_DEFAULT="America/New_York"

# ROOM_MAP — keyed by hardware serial.
#
# Format: each entry sets two variables for the matched host:
#   LOCATION   short slug (used in the hostname, e.g. "atl1"), also the
#              key into TZ_MAP below
#   FRIENDLY   human-readable name for ComputerName (shown in the login
#              window and in Apple Remote Desktop)
#
# Hostnames are generated as: zoom-room-mac-<location>-<serial>
# Anything not matched falls through to the "unknown" / fallback case.
#
# When a Mac physically moves to a new site, update its row here in the
# same commit as any per-room MDM profiles, then re-push setup_experience.
room_map_lookup() {
  case "$1" in
    # --- Example entries — REPLACE with your own fleet ---
    EXAMPLE001) echo "atl1|ATL1 - Conference Room A" ;;
    EXAMPLE002) echo "atl1|ATL1 - Conference Room B" ;;
    EXAMPLE003) echo "nyc1|NYC1 - Boardroom" ;;
    *) echo "" ;;
  esac
}

# TZ_MAP — IANA timezone per LOCATION slug. Fall through uses TZ_DEFAULT.
tz_map_lookup() {
  case "$1" in
    atl1|nyc1|nyc2) echo "America/New_York" ;;
    sfo1|lax1)      echo "America/Los_Angeles" ;;
    *) echo "" ;;
  esac
}

# --------------------------------------------------------------------------
# Implementation — you should not need to edit below this line.
# --------------------------------------------------------------------------

log() {
  echo "[zoom-rooms-mac-setup] $*"
}

# 1. Hostnames -------------------------------------------------------------
#
# macOS has three names:
#   HostName       — shell prompt, SSH, network identity
#   LocalHostName  — Bonjour .local (file sharing, AirDrop, ARD discovery)
#   ComputerName   — login window, Sharing prefs, Apple Remote Desktop UI
#
# We set the first two to a slug for unambiguous machine identity
# (zoom-room-mac-<location>-<serial>) and the third to a human-readable
# room name so ARD operators can pick out rooms at a glance.
SERIAL="$(system_profiler SPHardwareDataType | awk -F': ' '/Serial Number/ {print $2}' | tr -d ' ')"
LOCATION="unknown"
FRIENDLY=""
if [[ -z "$SERIAL" ]]; then
  log "ERROR: could not determine serial number; leaving hostnames unchanged."
else
  entry="$(room_map_lookup "$SERIAL")"
  if [[ -n "$entry" ]]; then
    LOCATION="${entry%%|*}"
    FRIENDLY="${entry#*|}"
  else
    log "WARN: serial '$SERIAL' not in ROOM_MAP; using fallback names."
    FRIENDLY="Zoom Room Mac ($SERIAL)"
  fi

  SLUG_HOSTNAME="zoom-room-mac-${LOCATION}-${SERIAL}"
  log "Setting HostName/LocalHostName to '$SLUG_HOSTNAME'."
  scutil --set HostName "$SLUG_HOSTNAME"
  scutil --set LocalHostName "$SLUG_HOSTNAME"
  log "Setting ComputerName (ARD/login-window) to '$FRIENDLY'."
  scutil --set ComputerName "$FRIENDLY"
fi

# 2. Apple Remote Management (ARD) ACLs ------------------------------------
#
# This kickstart call configures the ACL flags (who can connect, with what
# privileges, menu extra, directory logins). It does NOT make first-connect
# work on its own — since macOS 12.1, Screen Sharing is gated behind TCC,
# and `kickstart -activate -on` does not write the TCC ScreenCapture /
# PostEvent rows for com.apple.screensharing.agent. Without those rows the
# first ARD connect fails with "Screen Sharing is not permitted… Disable
# and re-enable Screen Sharing or Remote Management in System Settings".
#
# The TCC rows are written by the MDM `EnableRemoteDesktop` command, which
# you should enqueue from your MDM immediately after DeviceConfigured.
# This kickstart and that MDM command are complementary: kickstart writes
# ACLs, the MDM command writes TCC. Both are required for unattended,
# first-connect-works enrollment.
#
# Reference: https://macops.ca/managing-screen-sharing-in-monterey-12.1/
log "Configuring Apple Remote Management ACLs (all users, all privileges)."
/System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
  -activate -configure -access -on \
  -allowAccessFor -allUsers \
  -privs -all \
  -clientopts \
    -setmenuextra -menuextra yes \
    -setdirlogins -dirlogins yes \
    -setreqperm -reqperm yes \
  -restart -agent -menu

# 3. Auto-power-on when power is applied (Tahoe 26.5+) ---------------------
#
# `pmset autorestartatconnect` mirrors the "Start up when power is
# connected" toggle in Energy Settings → Always. On hardware that
# supports it (Mac mini 2024+, iMac 2024+, Mac Studio 2025+), this
# makes the kiosk boot itself after a power blip or outage.
#
# `|| true` because older Macs reject the flag and we don't want
# setup_experience to fail if a non-2024 model ever enrolls.
log "Enabling auto-restart when power is applied (Tahoe 26.5+ pmset key)."
/usr/bin/pmset autorestartatconnect 1 || true

# 4. ZoomPresence.app system LaunchAgent -----------------------------------
#
# The ZoomRooms.pkg installer drops the app at /Applications/ZoomPresence.app
# (legacy bundle name; the Zoom Rooms catalog title is user-facing) but does
# NOT register a LaunchAgent or login item. The bundled
# /Library/LaunchDaemons/us.zoom.rooms.daemon.plist is just the privileged
# helper for system-level work — it doesn't launch the GUI app.
#
# Without an explicit launcher, the kiosk auto-logs in to a Finder desktop
# and ZoomPresence.app never starts. The standard macadmin solution is a
# system-wide LaunchAgent in /Library/LaunchAgents/. launchd loads it in
# every GUI session, runs the binary as the logged-in user, restarts on
# crash, and survives in-place Zoom updates since we point at the bundle
# path.
#
# KeepAlive uses the {SuccessfulExit:false} dict form so launchd only
# restarts ZoomPresence on a crash (non-zero exit). A graceful Cmd-Q exits
# 0 and sticks — important so an IT operator can quit the app remotely
# without launchd respawning it under them mid-debug. Reboot / auto-login
# still relaunches via RunAtLoad. ProcessType:Interactive tells launchd
# this is a GUI app so it gets the right session affinity.
log "Installing /Library/LaunchAgents/us.zoom.ZoomPresence.plist."
/bin/cat > /Library/LaunchAgents/us.zoom.ZoomPresence.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>us.zoom.ZoomPresence</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/ZoomPresence.app/Contents/MacOS/ZoomPresence</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>StandardOutPath</key>
    <string>/tmp/zoompresence.stdout.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/zoompresence.stderr.log</string>
</dict>
</plist>
PLIST
/bin/chmod 644 /Library/LaunchAgents/us.zoom.ZoomPresence.plist
/usr/sbin/chown root:wheel /Library/LaunchAgents/us.zoom.ZoomPresence.plist

# 5. Timezone, NTP, automatic-TZ preference, Location Services -------------
#
# Goal: zero-touch enrollment that lands on the right TZ now and self-
# corrects later if a kiosk ever moves. Constraints:
#
# - Setup Assistant picks an initial TZ from the DEP profile's region
#   key (US → America/Los_Angeles), which is wrong for most fleets.
# - macOS 14+ removed the documented `defaults write` for "Set time
#   zone automatically." The community-converged sequence is:
#     TMAutomaticTimeZoneEnabled + TMAutomaticTimeOnlyEnabled, with
#     the plists chown'd to _timed:_timed (timed silently ignores
#     root-owned plists).
# - Auto-TZ resolution still requires locationd to obtain a fix.
#   Apple's geo backend is Skyhook Wi-Fi BSSID lookup; ethernet-only
#   Macs with no Wi-Fi never get a fix during DEP.
#
# So we do BOTH: hardcode the IANA name as a deterministic baseline
# AND enable the auto-TZ keys with the chown gotcha so timed will
# self-correct on the rare chance a kiosk later sees Wi-Fi.
TZ_NAME="$(tz_map_lookup "${LOCATION:-unknown}")"
if [[ -z "$TZ_NAME" ]]; then
  TZ_NAME="$TZ_DEFAULT"
fi
log "Setting time zone baseline to '$TZ_NAME' and enabling network time (NTP)."
/usr/sbin/systemsetup -settimezone "$TZ_NAME" >/dev/null || true
/usr/sbin/systemsetup -setusingnetworktime on >/dev/null || true

# Flip the automatic-TZ keys. Both plists MUST end up owned by
# _timed:_timed — `defaults write` as root leaves them root:wheel
# and timed ignores them.
log "Enabling automatic time zone (will only resolve if Wi-Fi present)."
TIMED_DIR="/private/var/db/timed/Library/Preferences"
/usr/bin/defaults write "$TIMED_DIR/com.apple.timed" TMAutomaticTimeZoneEnabled -bool YES
/usr/bin/defaults write "$TIMED_DIR/com.apple.timed" TMAutomaticTimeOnlyEnabled -bool YES
/usr/bin/defaults write "$TIMED_DIR/com.apple.preferences.datetime" timezoneset -bool YES
/usr/sbin/chown -R _timed:_timed /private/var/db/timed

# Enable system Location Services. Required for timed to ever query
# locationd, and used by other features (Find My, room maps). The
# preference write needs the same chown dance — locationd ignores
# root-owned plists. Use the hardware UUID-suffixed ByHost path on
# macOS 13+.
log "Enabling system-wide Location Services."
HW_UUID="$(/usr/sbin/system_profiler SPHardwareDataType | awk -F': ' '/Hardware UUID/ {print $2}' | tr -d ' ')"
LOCATIOND_BYHOST="/var/db/locationd/Library/Preferences/ByHost/com.apple.locationd"
/usr/bin/defaults write "$LOCATIOND_BYHOST" LocationServicesEnabled -int 1
if [[ -n "$HW_UUID" ]]; then
  /usr/bin/defaults -currentHost write "$LOCATIOND_BYHOST.$HW_UUID" LocationServicesEnabled -int 1
fi
/usr/sbin/chown -R _locationd:_locationd /var/db/locationd
/bin/launchctl kickstart -k system/com.apple.locationd || true

# 6. Create the kiosk admin via mkuser -------------------------------------
#
# We install / run mkuser via its official one-shot launcher
# (https://run.mkuser.sh). The launcher downloads the latest signed
# mkuser zip into a temp dir, verifies SHA512 + Apple code signature
# before running, runs it with our args, and deletes the temp dir
# after — nothing is left installed.
#
# Important mkuser flag choice: --skip-setup-assistant firstBootOnly.
#   - `firstBootOnly` writes /private/var/db/.AppleSetupDone AND issues
#     `launchctl asuser <_mbsetupuser_uid> launchctl reboot logout` to
#     kick `_mbsetupuser` out of the live SA session. Without this,
#     after our script finishes the device still shows the SA "Create
#     a Mac Account" pane (because SA was already running when mkuser
#     created our accounts underneath it).
#   - We considered `firstLoginOnly` and `both`, but `firstBootOnly` is
#     what actually flushes SA without leaving cruft.
#
# --prevent-secure-token-on-big-sur-and-newer means this account will
# NOT be FileVault-unlockable. That's what we want for a kiosk whose
# password is embedded in this script and ends up in kcpassword. If
# you want a FileVault-enabled account, drop that flag (and don't
# embed the password in plaintext anywhere on-disk).

# Optional: stage the kiosk user picture, SHA256-verified.
ICON_PATH=""
if [[ -n "$KIOSK_ICON_URL" ]]; then
  if [[ -z "$KIOSK_ICON_SHA256" ]]; then
    log "ERROR: KIOSK_ICON_URL is set but KIOSK_ICON_SHA256 is empty. Refusing to download unpinned content."
    exit 1
  fi
  ICON_PATH="/tmp/zoom-room-icon.png"
  log "Downloading kiosk user picture from $KIOSK_ICON_URL."
  /usr/bin/curl -sSfL -o "$ICON_PATH" "$KIOSK_ICON_URL"
  actual_icon_sha="$(/usr/bin/shasum -a 256 "$ICON_PATH" | /usr/bin/awk '{print $1}')"
  if [[ "$actual_icon_sha" != "$KIOSK_ICON_SHA256" ]]; then
    log "ERROR: icon SHA256 mismatch (expected $KIOSK_ICON_SHA256, got $actual_icon_sha). Aborting."
    exit 1
  fi
  log "Icon SHA256 verified."
fi

# Skip mkuser if the user already exists (idempotent for re-runs after
# a partial failure). mkuser returns exit code 26 in that case which
# would otherwise abort the script via `set -e`.
if /usr/bin/dscl . -read "/Users/$KIOSK_USERNAME" RecordName >/dev/null 2>&1; then
  log "$KIOSK_USERNAME already exists; skipping mkuser invocation."
else
  log "Creating $KIOSK_USERNAME kiosk admin via mkuser (one-shot via run.mkuser.sh)."
  mkuser_args=(
    --account-name "$KIOSK_USERNAME"
    --full-name    "$KIOSK_FULLNAME"
    --password     "$KIOSK_PASSWORD"
    --administrator
    --automatic-login
    --skip-setup-assistant firstBootOnly
    --prevent-secure-token-on-big-sur-and-newer
    --do-not-confirm
    --suppress-status-messages
  )
  if [[ -n "$ICON_PATH" ]]; then
    mkuser_args+=(--picture "$ICON_PATH")
  fi
  /bin/sh <(/usr/bin/curl -sSfL https://run.mkuser.sh) "${mkuser_args[@]}"

  if ! /usr/bin/dscl . -read "/Users/$KIOSK_USERNAME" RecordName >/dev/null 2>&1; then
    log "ERROR: mkuser appeared to succeed but /Users/$KIOSK_USERNAME is not in directory services. Aborting."
    exit 1
  fi
  log "$KIOSK_USERNAME user created successfully."
fi

# Clean up the staged icon if we downloaded one.
[[ -n "$ICON_PATH" ]] && /bin/rm -f "$ICON_PATH"

# 7. Dark Mode for the kiosk user ------------------------------------------
#
# Write AppleInterfaceStyle to the user's .GlobalPreferences.plist
# directly. We can't use `sudo -u $KIOSK_USERNAME defaults write -g`
# because that needs cfprefsd to have a session for the user, which
# it doesn't have at this point in setup_experience (user was just
# created seconds ago). Writing the plist file directly sidesteps
# cfprefsd entirely.
log "Setting AppleInterfaceStyle = Dark for $KIOSK_USERNAME."
KIOSK_PREFS_DIR="/Users/$KIOSK_USERNAME/Library/Preferences"
/bin/mkdir -p "$KIOSK_PREFS_DIR"
/usr/bin/defaults write "$KIOSK_PREFS_DIR/.GlobalPreferences" AppleInterfaceStyle Dark
/usr/sbin/chown -R "$KIOSK_USERNAME":staff "/Users/$KIOSK_USERNAME/Library"

# 8. Background reboot to satisfy SePOS auto-login -------------------------
#
# On macOS Tahoe 26 SePOS firmware, auto-login is disabled on the very
# first boot until either (a) a human logs in interactively once, OR
# (b) the system reboots with kcpassword + autoLoginUser already on
# disk so UpdateBrain can finalise its auto-login bookkeeping. mkuser
# just wrote both, so a single reboot at this point lands the kiosk
# auto-logged-in on the next boot.
#
# We do this via a self-deleting LaunchDaemon, NOT a backgrounded
# `sh -c 'sleep && reboot' &`, because the latter doesn't survive
# Fleet orbit's process-group cleanup when this script exits. launchd-
# owned daemons survive that cleanup.
#
# The daemon: sleep 15, rm its own plist + script, then /sbin/reboot.
# Self-cleanup BEFORE reboot so launchd's next-boot scan doesn't
# re-fire the daemon on the second boot.
#
# The 15s gives orbit / Jamf / your MDM agent time to POST our script's
# exit-0 result back to the management API before the reboot kills the
# host. If we rebooted too fast, the MDM would miss the success ACK
# and could re-queue the script.
#
# IMPORTANT: this MUST be the last thing this script does. Anything
# after it could race the reboot.
log "Installing self-deleting LaunchDaemon to fire reboot in 15s (SePOS bootstrap)."

REBOOT_PLIST=/Library/LaunchDaemons/zoom-rooms-firstboot-reboot.plist
REBOOT_SCRIPT=/usr/local/libexec/zoom-rooms-firstboot-reboot.sh
REBOOT_LABEL=zoom-rooms-firstboot-reboot

/bin/mkdir -p /usr/local/libexec
/bin/cat > "$REBOOT_SCRIPT" <<'REBOOT_SH'
#!/bin/bash
# One-shot first-boot reboot to bootstrap SePOS auto-login.
# See zoom-rooms-mac-setup.sh for context.
set -u
LOG=/var/log/zoom-rooms-firstboot-reboot.log
exec >>"$LOG" 2>&1
echo "[$(date -u +%FT%TZ)] firstboot-reboot daemon fired"
/bin/sleep 15

# CRITICAL ORDER: delete plist + script FIRST so launchd's next-boot
# scan doesn't re-fire this daemon. Then call /sbin/reboot. Do NOT
# call `launchctl bootout` first — bootout has been observed killing
# the daemon's own process tree before the subsequent reboot call
# fires (the daemon's bash script IS the daemon process). Letting
# /sbin/reboot do the cleanup via natural process teardown is safer.
echo "[$(date -u +%FT%TZ)] removing daemon files before reboot"
/bin/rm -f /Library/LaunchDaemons/zoom-rooms-firstboot-reboot.plist \
           /usr/local/libexec/zoom-rooms-firstboot-reboot.sh
echo "[$(date -u +%FT%TZ)] calling /sbin/reboot"
/sbin/reboot
echo "[$(date -u +%FT%TZ)] reboot returned (should never get here)"
REBOOT_SH
/bin/chmod 755 "$REBOOT_SCRIPT"
/usr/sbin/chown root:wheel "$REBOOT_SCRIPT"

/bin/cat > "$REBOOT_PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$REBOOT_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$REBOOT_SCRIPT</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>/var/log/zoom-rooms-firstboot-reboot.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/zoom-rooms-firstboot-reboot.log</string>
</dict>
</plist>
PLIST_EOF
/bin/chmod 644 "$REBOOT_PLIST"
/usr/sbin/chown root:wheel "$REBOOT_PLIST"

# Bootstrap into launchd. RunAtLoad=true fires it immediately.
# launchd owns the daemon process after bootstrap; it survives this
# script's exit and the MDM agent's process-group cleanup.
/bin/launchctl bootstrap system "$REBOOT_PLIST"

log "Done."
