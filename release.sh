#!/bin/bash
# Publishes a release: ./release.sh 0.3.0
# Sets the version, builds and signs Articulate.app, zips it, tags the commit and uploads the zip to GitHub
# Releases, where install.sh picks it up on any Mac (no Xcode needed there).
# Needs: a clean working tree, the GitHub CLI signed in (gh auth login), and the local signing identity from
# ./setup-signing.sh, so every release keeps the same signature and macOS keeps the user's permissions.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: ./release.sh <version>   e.g. ./release.sh 0.3.0" >&2
    exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
    echo "Commit or stash your changes first; a release is built from a commit." >&2
    exit 1
fi
if git rev-parse "v$VERSION" >/dev/null 2>&1; then
    echo "v$VERSION already exists." >&2
    exit 1
fi
if ! security find-identity -p codesigning 2>/dev/null | grep -qE '"(Articulate|Murmur) Local Signing"'; then
    echo "No local signing identity: run ./setup-signing.sh first, or every update would ask for permissions again." >&2
    exit 1
fi

# The version shown in the app's menu; the build number only ever goes up.
PLIST=Resources/Info.plist
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST") + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST"

./build.sh
mkdir -p dist
ZIP="dist/Articulate-$VERSION.zip"
rm -f "$ZIP"
# ditto keeps the bundle's signature and extended attributes intact (zip -r can break the signature).
ditto -c -k --sequesterRsrc --keepParent build/Articulate.app "$ZIP"

git add "$PLIST"
git commit -q -m "Release $VERSION"
git tag "v$VERSION"
git push -q origin HEAD "v$VERSION"
gh release create "v$VERSION" "$ZIP" --title "Articulate $VERSION" --generate-notes
echo "Released v$VERSION. On any Mac, install or update with the command in README › 安裝與更新."
