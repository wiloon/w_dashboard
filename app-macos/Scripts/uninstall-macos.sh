#!/usr/bin/env bash
# Remove the ~/Applications install and the login-item LaunchAgent.
set -euo pipefail

LABEL="dev.wdashboard.app"
INSTALLED_APP="$HOME/Applications/WDashboard.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST" && echo "Removed $PLIST"

# Stop a running instance, if any.
pkill -f "$INSTALLED_APP/Contents/MacOS/WDashboard" 2>/dev/null || true

rm -rf "$INSTALLED_APP" && echo "Removed $INSTALLED_APP"
echo "Uninstalled."
