#!/bin/bash
# Assemble and sign Hostflip.app (layout and identity constants: ChannelIdentity.swift).
#
# Usage: CODESIGN_IDENTITY="Developer ID Application: … (TEAMID)" scripts/build-app.sh
# Without CODESIGN_IDENTITY the bundle is ad-hoc signed: that verifies the
# packaging structure, but carries no Team ID, so the XPC mutual verification
# fails closed (see docs/signed-build-verification.md).
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${CODESIGN_IDENTITY:--}"
BIN="$(swift build -c release --show-bin-path)"
APP="build/Hostflip.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
cp "$BIN/Hostflip" "$APP/Contents/MacOS/Hostflip"
cp "$BIN/hostflipd" "$APP/Contents/MacOS/hostflipd"
cp Packaging/HostflipApp-Info.plist "$APP/Contents/Info.plist"
cp Packaging/Hostflip.icns "$APP/Contents/Resources/Hostflip.icns"
cp Packaging/com.heronapp.hostflip.daemon.plist "$APP/Contents/Library/LaunchDaemons/"

# A real certificate adds a secure timestamp (hard requirement for notarization);
# ad-hoc signatures do not support timestamps.
TIMESTAMP_FLAG=""
if [ "$IDENTITY" != "-" ]; then TIMESTAMP_FLAG="--timestamp"; fi

# Sign the embedded daemon first (displaced nested code), then the whole bundle.
# The daemon is not a bundle, so its signing identifier must be set explicitly.
codesign --force --options runtime $TIMESTAMP_FLAG \
    --identifier com.heronapp.hostflip.daemon \
    --sign "$IDENTITY" "$APP/Contents/MacOS/hostflipd"
codesign --force --options runtime $TIMESTAMP_FLAG --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "Built ${APP} (signing identity: ${IDENTITY})"
