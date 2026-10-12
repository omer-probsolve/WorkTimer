#!/bin/bash
# Builds and installs Work Timer into /Applications, then launches it.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Work Timer"
APP="dist/$APP_NAME.app"
TARGET="/Applications/$APP_NAME.app"

./build.sh

echo "==> Stopping any running instance"
osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
pkill -x "WorkTimer" >/dev/null 2>&1 || true
sleep 1

echo "==> Installing to $TARGET"
rm -rf "$TARGET"
cp -R "$APP" "$TARGET"

# Clear the quarantine flag so Gatekeeper doesn't block a locally built app.
xattr -dr com.apple.quarantine "$TARGET" >/dev/null 2>&1 || true

echo "==> Launching"
open "$TARGET"

cat <<'TXT'

Installed. Look for the clock icon in the menu bar.

  • ⌃⌥T  show / hide the Work Timer window
  • ⌃⌥S  start / stop the timer
  • Shortcuts, idle timeout and auto-tracking live in the Settings tab.
TXT
