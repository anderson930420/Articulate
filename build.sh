#!/bin/bash
# Builds Articulate.app. With --install, copies it to ~/Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Articulate"

APP=build/Articulate.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Articulate"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# The setup window installs the extra recognizer from these (same files setup-tea.sh uses).
mkdir -p "$APP/Contents/Resources/ASR"
cp Tools/asr_server.py Tools/prepare_asr_model.py "$APP/Contents/Resources/ASR/"

rm -rf build/AppIcon.iconset
"$BIN" --render-icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# macOS ties privacy permissions (Accessibility, Microphone) to the signature. With the local identity
# from ./setup-signing.sh they survive rebuilds; with an ad-hoc signature they must be granted again.
# "Murmur Local Signing": the identity setup-signing.sh created before the app was renamed.
IDENTITY="$(security find-identity -p codesigning 2>/dev/null | awk '/"(Articulate|Murmur) Local Signing"/ {print $2; exit}')"
if [ -n "$IDENTITY" ]; then
    codesign --force --sign "$IDENTITY" --identifier local.articulate.dictation "$APP"
else
    echo "warning: no \"Articulate Local Signing\" identity (run ./setup-signing.sh); using an ad-hoc signature"
    codesign --force --sign - --identifier local.articulate.dictation "$APP"
fi
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    pkill -x Articulate 2>/dev/null || true
    # Opening while the old copy is still quitting fails with LaunchServices error -600.
    for _ in $(seq 1 50); do pgrep -x Articulate >/dev/null || break; sleep 0.1; done
    # Keep the installed speech-model server in step with Tools/ (it is copied there by setup-tea.sh).
    ASR="$HOME/Library/Application Support/Articulate/ASR"
    if [ -d "$ASR" ]; then cp Tools/asr_server.py "$ASR/asr_server.py"; fi
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/Articulate.app"
    cp -R "$APP" "$HOME/Applications/Articulate.app"
    # LaunchServices sometimes refuses (-600) right after the old copy quit; try again once.
    open "$HOME/Applications/Articulate.app" || { sleep 2; open "$HOME/Applications/Articulate.app"; }
    echo "Installed to ~/Applications/Articulate.app and launched"
fi
