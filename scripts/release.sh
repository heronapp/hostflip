#!/bin/bash
# Repeatable local release pipeline (verification log: docs/release-verification.md):
#   guards (version, clean tree, certificate) → clean build + signing (scripts/build-app.sh)
#   → signature acceptance gate → notarization #1 + staple (app) → DMG signing
#   + notarization #2 + staple → Gatekeeper acceptance → GitHub Release
#   (uploaded as a draft, published only once everything is ready).
#
# Usage:
#   scripts/release.sh               full release (creates the GitHub Release at the end)
#   scripts/release.sh --no-publish  rehearsal: produce the fully verified DMG, never touch GitHub
#
# One-time setup (credentials go only into the local keychain; the pipeline then
# refers to them by profile name and never prints secrets):
#   xcrun notarytool store-credentials hostflip-notary \
#       --apple-id <AppleID> --team-id EA9SPTEHTA
# An existing profile for the same Team can be used via NOTARY_PROFILE=<name>.
set -euo pipefail
cd "$(dirname "$0")/.."

PUBLISH=1
if [ "${1:-}" = "--no-publish" ]; then
    PUBLISH=0
elif [ -n "${1:-}" ]; then
    echo "error: unknown argument: $1 (only --no-publish is supported)" >&2; exit 1
fi

TEAM_ID=EA9SPTEHTA
NOTARY_PROFILE="${NOTARY_PROFILE:-hostflip-notary}"
PLIST=Packaging/HostflipApp-Info.plist
DIST=build/dist

# Sparkle command-line tools (generate_appcast), pinned and cached per version.
# The EdDSA key lives in the release machine's Keychain under the dedicated
# account "hostflip" (created once with: generate_keys --account hostflip).
SPARKLE_VERSION=2.9.5
SPARKLE_SHA256=015336b601493e05c237964954bff6191370003d94edefe663724c88840d73cc
SPARKLE_TOOLS="${SPARKLE_TOOLS:-$HOME/Library/Caches/hostflip/sparkle-tools-$SPARKLE_VERSION}"

echo "==> Pre-release guards"
# Full dirty check including untracked files: they never enter the artifact, but
# they blur which commit the artifact corresponds to.
[ -z "$(git status --porcelain)" ] || \
    { echo "error: git tree is not clean (a release requires a fully clean tree, untracked included)" >&2; exit 1; }

IDENTITY="$(security find-identity -v -p codesigning | \
    grep -o "\"Developer ID Application: .*($TEAM_ID)\"" | tr -d '"' | head -1 || true)"
[ -n "$IDENTITY" ] || \
    { echo "error: no \"Developer ID Application\" certificate for Team $TEAM_ID in the Keychain" >&2; exit 1; }

VER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST")"
echo "$VER" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || \
    { echo "error: version \"${VER}\" is not an X.Y.Z semantic version" >&2; exit 1; }
echo "$BUILD" | grep -Eq '^[1-9][0-9]*$' || \
    { echo "error: build version \"${BUILD}\" is not a positive integer" >&2; exit 1; }
# Dual version source (see ADR 0003): the plist and HostflipBuild.version must agree.
grep -qF "public static let version = \"$VER\"" Sources/HostflipXPC/ChannelIdentity.swift || \
    { echo "error: HostflipBuild.version disagrees with $VER in $PLIST (the two locations must be updated together)" >&2; exit 1; }
# Release notes are embedded into the Sparkle update dialog; failing here, before the build
# investment, keeps "write the notes" a hard part of every release instead of a skipped nicety.
NOTES="Packaging/ReleaseNotes/$VER.html"
[ -f "$NOTES" ] || \
    { echo "error: missing $NOTES (write the user-facing notes for $VER before releasing)" >&2; exit 1; }

# Compare against the highest released tag on the remote: both the semantic
# version and the build version must strictly increase.
REMOTE_TAGS="$(git ls-remote --tags origin 'refs/tags/v*' | \
    awk -F/ '{print $NF}' | grep -v '\^{}$' || true)"
if echo "$REMOTE_TAGS" | grep -qx "v$VER"; then
    echo "error: tag v$VER already exists on origin" >&2; exit 1
fi
PREV_TAG="$(echo "$REMOTE_TAGS" | sort -V | tail -1)"
if [ -n "$PREV_TAG" ]; then
    PREV_VER="${PREV_TAG#v}"
    [ "$(printf '%s\n%s\n' "$PREV_VER" "$VER" | sort -V | tail -1)" = "$VER" ] || \
        { echo "error: version $VER is not higher than the released $PREV_VER" >&2; exit 1; }
    git fetch --quiet origin "refs/tags/$PREV_TAG:refs/tags/$PREV_TAG"
    PREV_PLIST="$(mktemp)"
    git show "$PREV_TAG:$PLIST" > "$PREV_PLIST"
    PREV_BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PREV_PLIST")"
    rm -f "$PREV_PLIST"
    [ "$BUILD" -gt "$PREV_BUILD" ] || \
        { echo "error: build version $BUILD is not higher than $PREV_BUILD of $PREV_TAG" >&2; exit 1; }
fi

if [ "$PUBLISH" -eq 1 ]; then
    # Publishing must run in a clone of the public repository: releases and tags
    # belong to the public repo.
    git remote get-url origin | grep -Eq "heronapp/hostflip(\.git)?$" || \
        { echo "error: publishing must run in a public-repo clone (origin = heronapp/hostflip)" >&2; exit 1; }
    # The release tag points at the local HEAD: it must already be pushed to
    # origin/main, or the tag and the artifact would disagree.
    [ "$(git rev-parse HEAD)" = "$(git ls-remote origin refs/heads/main | cut -f1)" ] || \
        { echo "error: local HEAD does not match origin/main (push first, then release)" >&2; exit 1; }
fi

echo "==> Sparkle tools (generate_appcast $SPARKLE_VERSION)"
if [ ! -x "$SPARKLE_TOOLS/bin/generate_appcast" ]; then
    SPARKLE_TMP="$(mktemp -d)"
    curl -fsSL -o "$SPARKLE_TMP/sparkle.tar.xz" \
        "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
    echo "$SPARKLE_SHA256  $SPARKLE_TMP/sparkle.tar.xz" | shasum -a 256 -c - >/dev/null || \
        { echo "error: Sparkle tools download does not match the pinned sha256" >&2; exit 1; }
    mkdir -p "$SPARKLE_TOOLS"
    tar -xJf "$SPARKLE_TMP/sparkle.tar.xz" -C "$SPARKLE_TOOLS"
    rm -rf "$SPARKLE_TMP"
fi
# The dedicated key must exist before the pipeline invests in a build.
security find-generic-password -a hostflip -s "https://sparkle-project.org" >/dev/null 2>&1 || \
    { echo "error: no Sparkle EdDSA key for account \"hostflip\" in the Keychain (one-time: generate_keys --account hostflip)" >&2; exit 1; }

echo "==> Clean build + signing (${IDENTITY})"
swift package clean
CODESIGN_IDENTITY="$IDENTITY" scripts/build-app.sh
APP=build/Hostflip.app

echo "==> Signature acceptance gate (per object, every check is a hard failure)"
codesign --verify --deep --strict "$APP"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
for T in "$APP/Contents/MacOS/Hostflip" "$APP/Contents/MacOS/hostflipd" \
    "$APP/Contents/Helpers/hostflip" \
    "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc" \
    "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" \
    "$FRAMEWORK/Versions/B/Autoupdate" \
    "$FRAMEWORK/Versions/B/Updater.app" \
    "$FRAMEWORK" \
    "$APP"; do
    INFO="$(codesign -dvv "$T" 2>&1)" || \
        { printf '%s\n' "$INFO" >&2; echo "error: codesign -dvv failed: $T" >&2; exit 1; }
    echo "$INFO" | grep -q "TeamIdentifier=$TEAM_ID" || \
        { echo "error: TeamIdentifier mismatch: $T" >&2; exit 1; }
    echo "$INFO" | grep -q "Timestamp=" || \
        { echo "error: missing secure timestamp: $T" >&2; exit 1; }
    echo "$INFO" | grep -Eq "flags=.*runtime" || \
        { echo "error: missing hardened runtime flag: $T" >&2; exit 1; }
done
# Capture into a variable before grep: piping codesign straight into grep -q can
# make codesign take a SIGPIPE when grep exits early — a false failure under pipefail.
DAEMON_INFO="$(codesign -dvv "$APP/Contents/MacOS/hostflipd" 2>&1)"
echo "$DAEMON_INFO" | grep -q "Identifier=com.heronapp.hostflip.daemon" || \
    { echo "error: daemon signing identifier is not com.heronapp.hostflip.daemon" >&2; exit 1; }
CLI_INFO="$(codesign -dvv "$APP/Contents/Helpers/hostflip" 2>&1)"
echo "$CLI_INFO" | grep -q "Identifier=com.heronapp.hostflip.cli" || \
    { echo "error: cli signing identifier is not com.heronapp.hostflip.cli" >&2; exit 1; }

# notarytool --wait's exit code is not fully trustworthy; trust "status: Accepted"
# in its output instead (observed in practice).
notarize() { # $1=file to submit  $2=label
    local OUT
    OUT="$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" || true
    printf '%s\n' "$OUT"
    printf '%s\n' "$OUT" | grep -q "status: Accepted" || {
        echo "error: notarization was not accepted ($2). To investigate:" >&2
        echo "  xcrun notarytool log <id from the output above> --keychain-profile $NOTARY_PROFILE" >&2
        echo "  if the profile does not exist yet: see the one-time store-credentials step in this script's header" >&2
        exit 1
    }
}

NAME="Hostflip-$VER"
rm -rf "$DIST"
mkdir -p "$DIST"

echo "==> Notarization #1 (app) + staple"
APP_ZIP="build/$NAME-notarize.zip"
rm -f "$APP_ZIP"
ditto -c -k --keepParent "$APP" "$APP_ZIP"
notarize "$APP_ZIP" app
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute "$APP" || \
    { echo "error: Gatekeeper (execute) rejected Hostflip.app" >&2; exit 1; }

echo "==> DMG (sign + notarization #2 + staple)"
STAGE="build/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "$DIST/$NAME.dmg" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DIST/$NAME.dmg"
notarize "$DIST/$NAME.dmg" dmg
xcrun stapler staple "$DIST/$NAME.dmg"
xcrun stapler validate "$DIST/$NAME.dmg"
spctl --assess --type open --context context:primary-signature "$DIST/$NAME.dmg" || \
    { echo "error: Gatekeeper (open) rejected the DMG" >&2; exit 1; }

echo "==> Appcast (EdDSA-signed enclosure for the Sparkle feed)"
# generate_appcast picks up release notes from an HTML file named like the archive.
cp "$NOTES" "$DIST/$NAME.html"
"$SPARKLE_TOOLS/bin/generate_appcast" --account hostflip --embed-release-notes \
    --download-url-prefix "https://github.com/heronapp/hostflip/releases/download/v$VER/" \
    -o "$DIST/appcast.xml" "$DIST"
rm -f "$DIST/$NAME.html" # consumed into the appcast; keep $DIST holding release assets only
grep -q "<sparkle:shortVersionString>$VER</sparkle:shortVersionString>" "$DIST/appcast.xml" || \
    { echo "error: appcast.xml does not contain version $VER" >&2; exit 1; }
grep -q "sparkle:edSignature=" "$DIST/appcast.xml" || \
    { echo "error: appcast.xml enclosure carries no EdDSA signature" >&2; exit 1; }
grep -q "<description>" "$DIST/appcast.xml" || \
    { echo "error: appcast.xml carries no embedded release notes" >&2; exit 1; }

if [ "$PUBLISH" -eq 0 ]; then
    echo "==> Done (--no-publish, GitHub untouched): $DIST/$NAME.dmg"
    exit 0
fi

echo "==> GitHub Release (upload as draft, publish once ready)"
# Clean up a same-named draft left by a previous failed run (not externally
# visible), avoiding duplicate drafts and ambiguous tag resolution.
LEFTOVER_DRAFTS="$(gh release list --json tagName,isDraft \
    --jq "[.[] | select(.isDraft and .tagName == \"v$VER\")] | length")"
if [ "$LEFTOVER_DRAFTS" -gt 0 ]; then
    gh release delete "v$VER" --yes
fi
# While a draft, the release is externally invisible and creates no tag; any
# failure before publish leaves no public half-finished release behind.
# appcast.xml rides every release: SUFeedURL resolves it through the stable
# releases/latest/download redirect, so the newest release's copy is the feed.
gh release create "v$VER" "$DIST/$NAME.dmg" "$DIST/appcast.xml" \
    --draft --title "v$VER" --generate-notes --target "$(git rev-parse HEAD)"
gh release edit "v$VER" --draft=false

echo "==> Homebrew tap (version + sha256)"
scripts/update-tap.sh "$VER" "$DIST/$NAME.dmg"
echo "==> Done: v$VER published, artifact $DIST/$NAME.dmg"
