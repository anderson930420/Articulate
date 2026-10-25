#!/bin/bash
# Installs Articulate, or updates it to the newest release, from GitHub Releases. No Xcode needed.
# A public release downloads directly:
#   curl -fsSL https://raw.githubusercontent.com/anderson930420/Articulate/main/install.sh | bash
# A private repository goes through the GitHub CLI signed in on this Mac (https://cli.github.com, then gh auth login):
#   gh api -H "Accept: application/vnd.github.raw" repos/anderson930420/Articulate/contents/install.sh | bash
set -euo pipefail

REPO="${ARTICULATE_REPO:-anderson930420/Articulate}"
APP="$HOME/Applications/Articulate.app"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# A public release first (no tools needed), then the GitHub CLI for a private repository.
LATEST="$(curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null || true)"
URL="$(printf '%s' "$LATEST" | grep -o '"browser_download_url": *"[^"]*/Articulate-[^"]*\.zip"' | head -1 | sed 's/.*"\(https[^"]*\)"$/\1/')"
if [ -n "$URL" ]; then
    TAG="$(printf '%s' "$LATEST" | grep -o '"tag_name": *"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
    echo "== Downloading Articulate $TAG"
    curl -fL --progress-bar -o "$TMP/Articulate.zip" "$URL"
elif command -v gh >/dev/null 2>&1; then
    TAG="$(gh release view --repo "$REPO" --json tagName -q .tagName)"
    echo "== Downloading Articulate $TAG (private repository, through the GitHub CLI)"
    gh release download "$TAG" --repo "$REPO" --pattern 'Articulate-*.zip' --output "$TMP/Articulate.zip"
else
    echo "The release isn't public: install the GitHub CLI (https://cli.github.com, no Homebrew needed), run gh auth login, and try again." >&2
    exit 1
fi
ditto -x -k "$TMP/Articulate.zip" "$TMP/unpacked"
codesign --verify --deep --strict "$TMP/unpacked/Articulate.app"

if [ -d "$APP" ]; then
    CURRENT="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "?")"
    echo "== Replacing version $CURRENT"
    # Permissions carry over only when the new copy meets the installed one's designated requirement (same certificate).
    REQ="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
    if [ -z "$REQ" ] || ! codesign --verify -R "=$REQ" "$TMP/unpacked/Articulate.app" 2>/dev/null; then
        echo "   Signed with a different certificate than the installed copy: grant Microphone and Accessibility again in the setup window."
    fi
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
