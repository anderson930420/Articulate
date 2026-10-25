#!/bin/bash
# Installs Articulate, or updates it to the newest release, from GitHub Releases. No Xcode needed.
# The repository is private, so the download goes through the GitHub CLI signed in on this Mac
# (brew install gh, then gh auth login). Run it without cloning anything:
#   gh api -H "Accept: application/vnd.github.raw" repos/anderson930420/Articulate/contents/install.sh | bash
# Files downloaded by gh aren't quarantined, so macOS opens the app without the "unidentified developer" stop.
set -euo pipefail

REPO="${ARTICULATE_REPO:-anderson930420/Articulate}"
APP="$HOME/Applications/Articulate.app"

if ! command -v gh >/dev/null 2>&1; then
    echo "Needs the GitHub CLI: brew install gh, then gh auth login." >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TAG="$(gh release view --repo "$REPO" --json tagName -q .tagName)"
echo "== Downloading Articulate $TAG"
gh release download "$TAG" --repo "$REPO" --pattern 'Articulate-*.zip' --dir "$TMP"
ditto -x -k "$TMP"/Articulate-*.zip "$TMP/unpacked"
codesign --verify --deep --strict "$TMP/unpacked/Articulate.app"

if [ -d "$APP" ]; then
    CURRENT="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "?")"
    echo "== Replacing version $CURRENT"
fi
# Quit the running copy (and Murmur, the app's old name) so the files can be replaced.
osascript -e 'tell application id "local.articulate.dictation" to quit' >/dev/null 2>&1 || true
osascript -e 'tell application id "local.murmur.dictation" to quit' >/dev/null 2>&1 || true
for _ in $(seq 1 50); do pgrep -x Articulate >/dev/null || pgrep -x Murmur >/dev/null || break; sleep 0.1; done

mkdir -p "$HOME/Applications"
# The old copy goes to the Trash rather than being deleted.
if [ -d "$APP" ]; then mv "$APP" "$HOME/.Trash/Articulate-$(date +%Y%m%d-%H%M%S).app"; fi
mv "$TMP/unpacked/Articulate.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
open "$APP" || { sleep 2; open "$APP"; }
echo "Articulate $TAG is installed in ~/Applications and running."
echo "The first time (or after the app was renamed from Murmur), grant its permissions in the setup window."
