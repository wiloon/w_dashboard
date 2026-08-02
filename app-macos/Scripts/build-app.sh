#!/usr/bin/env bash
# Build a release binary and assemble a minimal WDashboard.app bundle.
# Counterpart to app-linux's .desktop entry (docs/task-spec.md T3.12).
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release --product WDashboardApp

APP_DIR="dist/WDashboard.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

BIN_PATH="$(swift build -c release --product WDashboardApp --show-bin-path)"
cp "$BIN_PATH/WDashboardApp" "$MACOS_DIR/WDashboard"
cp Resources/Info.plist "$APP_DIR/Contents/Info.plist"

echo "Built $APP_DIR"
echo "Run with: open $APP_DIR"
