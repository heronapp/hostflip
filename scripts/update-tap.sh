#!/bin/bash
# Update the Homebrew tap cask (version + sha256) after a release.
# Called at the end of scripts/release.sh; if the tap push fails it can be
# re-run on its own:
#   scripts/update-tap.sh <version> <path to DMG>
set -euo pipefail

VER="${1:?usage: update-tap.sh <version> <path to DMG>}"
DMG="${2:?usage: update-tap.sh <version> <path to DMG>}"
TAP_REPO="${TAP_REPO:-heronapp/homebrew-tap}"

SHA256="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
TAP_DIR="$(mktemp -d)"
trap 'rm -rf "$TAP_DIR"' EXIT
gh repo clone "$TAP_REPO" "$TAP_DIR" -- --quiet --depth 1

CASK="$TAP_DIR/Casks/hostflip.rb"
[ -f "$CASK" ] || { echo "error: $TAP_REPO is missing Casks/hostflip.rb" >&2; exit 1; }
sed -i '' \
    -e "s|^  version \".*\"$|  version \"$VER\"|" \
    -e "s|^  sha256 \".*\"$|  sha256 \"$SHA256\"|" "$CASK"
grep -q "version \"$VER\"" "$CASK" || { echo "error: cask version rewrite failed" >&2; exit 1; }
grep -q "sha256 \"$SHA256\"" "$CASK" || { echo "error: cask sha256 rewrite failed" >&2; exit 1; }
# The app self-updates via Sparkle; tell brew so `brew upgrade --greedy` semantics apply.
if ! grep -q "^  auto_updates true$" "$CASK"; then
    sed -i '' "s|^  sha256 \"$SHA256\"$|  sha256 \"$SHA256\"\n\n  auto_updates true|" "$CASK"
    grep -q "^  auto_updates true$" "$CASK" || { echo "error: cask auto_updates insert failed" >&2; exit 1; }
fi

# Commit as the GitHub noreply identity, so the machine's global git config
# email never leaks into the public tap.
LOGIN="$(gh api user --jq .login)"
EMAIL="$(gh api user --jq '"\(.id)+\(.login)@users.noreply.github.com"')"
git -C "$TAP_DIR" -c user.name="$LOGIN" -c user.email="$EMAIL" commit -qam "hostflip $VER"
git -C "$TAP_DIR" push -q
echo "==> tap updated: $TAP_REPO hostflip $VER (sha256 $SHA256)"
