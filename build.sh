#!/bin/bash
# Builds build/MacVolume.app. Pass "install" to also copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/MacVolume"

APP="build/MacVolume.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/MacVolume"
cp Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature by default; set SIGN_IDENTITY to a real identity to keep
# privacy permissions across rebuilds.
codesign --force --sign "${SIGN_IDENTITY:--}" --identifier com.local.MacVolume "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
    pkill -x MacVolume 2>/dev/null || true
    rm -rf /Applications/MacVolume.app
    cp -R "$APP" /Applications/MacVolume.app
    open /Applications/MacVolume.app
    echo "Installed and launched /Applications/MacVolume.app"
fi
