#!/bin/bash
# Assemble and sign Hostflip.app (layout and identity constants: ChannelIdentity.swift).
#
# Usage: CODESIGN_IDENTITY="Developer ID Application: … (TEAMID)" scripts/build-app.sh
# Without CODESIGN_IDENTITY the bundle is ad-hoc signed: that verifies the
# packaging structure, but carries no Team ID, so the XPC mutual verification
# fails closed (see docs/signed-build-verification.md) and the app does not
# launch at all — hardened-runtime library validation rejects the embedded
# Sparkle.framework without a matching Team ID.
set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${CODESIGN_IDENTITY:--}"
BIN="$(swift build -c release --show-bin-path)"
APP="build/Hostflip.app"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons" \
    "$APP/Contents/Frameworks" "$APP/Contents/Helpers"
cp "$BIN/HostflipApp" "$APP/Contents/MacOS/Hostflip"
cp "$BIN/hostflipd" "$APP/Contents/MacOS/hostflipd"
# The CLI lives in Helpers/, never MacOS/: APFS is case-insensitive by default,
# so `hostflip` next to `Hostflip` would collide (ADR 0009).
cp "$BIN/hostflip" "$APP/Contents/Helpers/hostflip"
cp Packaging/HostflipApp-Info.plist "$APP/Contents/Info.plist"
cp Packaging/Hostflip.icns "$APP/Contents/Resources/Hostflip.icns"
cp Packaging/com.heronapp.hostflip.daemon.plist "$APP/Contents/Library/LaunchDaemons/"
# SwiftPM places the Sparkle binary artifact next to the built products; the app
# links it via @rpath, which only resolves once Contents/Frameworks is on the path.
ditto "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Hostflip"

# A real certificate adds a secure timestamp (hard requirement for notarization);
# ad-hoc signatures do not support timestamps.
TIMESTAMP_FLAG=""
if [ "$IDENTITY" != "-" ]; then TIMESTAMP_FLAG="--timestamp"; fi

# Re-sign Sparkle inside-out with our identity (the prebuilt framework carries
# Sparkle's), per https://sparkle-project.org/documentation/sandboxing/ — no --deep.
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --options runtime $TIMESTAMP_FLAG \
    --sign "$IDENTITY" "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
codesign --force --options runtime $TIMESTAMP_FLAG --preserve-metadata=entitlements \
    --sign "$IDENTITY" "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
codesign --force --options runtime $TIMESTAMP_FLAG \
    --sign "$IDENTITY" "$FRAMEWORK/Versions/B/Autoupdate"
codesign --force --options runtime $TIMESTAMP_FLAG \
    --sign "$IDENTITY" "$FRAMEWORK/Versions/B/Updater.app"
codesign --force --options runtime $TIMESTAMP_FLAG --sign "$IDENTITY" "$FRAMEWORK"

# Sign the embedded daemon and CLI first (displaced nested code), then the whole
# bundle. Neither is a bundle, so their signing identifiers must be set explicitly;
# each executable carries its own identity (ADR 0009) and the daemon accepts either
# the app's or the CLI's as its peer.
codesign --force --options runtime $TIMESTAMP_FLAG \
    --identifier com.heronapp.hostflip.daemon \
    --sign "$IDENTITY" "$APP/Contents/MacOS/hostflipd"
codesign --force --options runtime $TIMESTAMP_FLAG \
    --identifier com.heronapp.hostflip.cli \
    --sign "$IDENTITY" "$APP/Contents/Helpers/hostflip"
codesign --force --options runtime $TIMESTAMP_FLAG --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "Built ${APP} (signing identity: ${IDENTITY})"
