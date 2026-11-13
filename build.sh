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

# Signing: a fixed identity keeps macOS privacy permissions across rebuilds.
# Order: $SIGN_IDENTITY, then a keychain certificate named "MacVolume Signing"
# (see README), then an ad-hoc signature.
IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]] && security find-certificate -c "MacVolume Signing" >/dev/null 2>&1; then
    IDENTITY="MacVolume Signing"
fi
codesign --force --sign "${IDENTITY:--}" --identifier com.local.MacVolume "$APP"
echo "Built $APP (signed with: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "install" ]]; then
    # Quit a running copy and wait for it to exit, or the relaunch below can fail.
    pkill -x MacVolume 2>/dev/null || true
    for _ in {1..50}; do
        pgrep -x MacVolume >/dev/null || break
        sleep 0.1
    done
    rm -rf /Applications/MacVolume.app
    cp -R "$APP" /Applications/MacVolume.app
    open /Applications/MacVolume.app
    echo "Installed and launched /Applications/MacVolume.app"
fi
