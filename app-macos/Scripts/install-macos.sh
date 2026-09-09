#!/usr/bin/env bash
# Deploy WDashboard.app into ~/Applications (so Spotlight / Raycast / Alfred index it)
# and register a per-user LaunchAgent so it starts at login.
# Fully scriptable: no GUI steps, no TCC permission prompts.
# Counterpart to app-linux's .desktop install (docs/task-spec.md T3.12).
set -euo pipefail

cd "$(dirname "$0")/.."

LABEL="dev.wdashboard.app"
APP_NAME="WDashboard.app"
INSTALL_DIR="$HOME/Applications"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# 1. Build the .app bundle.
./Scripts/build-app.sh

# 2. Copy into ~/Applications (replace any previous install).
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALLED_APP"
cp -R "dist/$APP_NAME" "$INSTALLED_APP"
echo "Installed $INSTALLED_APP"

# 3. Nudge Spotlight to index it now instead of whenever it gets around to it.
/usr/bin/mdimport "$INSTALLED_APP" || true

# 4. Write the LaunchAgent (start at login, do not restart if the user quits it).
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALLED_APP/Contents/MacOS/WDashboard</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLIST_EOF
echo "Wrote $PLIST"

# 5. (Re)load it into the current GUI session.
DOMAIN="gui/$(id -u)"
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$PLIST"
echo "LaunchAgent loaded — WDashboard will start at login."
echo
echo "Start it now with:  open \"$INSTALLED_APP\""
