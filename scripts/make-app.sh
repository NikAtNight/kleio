#!/bin/bash
# Builds Scribe in release mode and packages it as a proper .app bundle so
# macOS TCC permissions (Microphone, System Audio Recording) attach to
# Scribe itself instead of your terminal.
set -euo pipefail

cd "$(dirname "$0")/.."

echo "Building (release)…"
swift build -c release

APP="build/Scribe.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Scribe "$APP/Contents/MacOS/Scribe"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# App icon — rendered on demand; re-run scripts/make-icon.sh to redesign.
if [ ! -f Resources/AppIcon.icns ]; then
    ./scripts/make-icon.sh
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign with the stable self-signed identity so TCC grants survive rebuilds.
SIGN_ID="Talix Dev Signing"
if security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
    codesign --force --sign "$SIGN_ID" --identifier app.talix.scribe "$APP"
else
    echo "warning: '$SIGN_ID' identity not found — ad-hoc signing with pinned requirement"
    codesign --force --sign - \
        --identifier app.talix.scribe \
        -r='designated => identifier "app.talix.scribe"' \
        "$APP"
fi

# CoreML specializes the Whisper model once per binary (takes minutes).
# Pay that cost here, against the signed binary, so the installed app's
# first transcription is instant. Skipped gracefully if no model is
# downloaded yet.
echo "Pre-warming CoreML model cache (can take a few minutes on a new binary)…"
WARM_AIFF="$(mktemp -t scribe-warm).aiff"
if say -o "$WARM_AIFF" "warm up" 2>/dev/null &&
   "$APP/Contents/MacOS/Scribe" --transcribe "$WARM_AIFF" >/dev/null 2>&1; then
    echo "Model cache warm."
else
    echo "warning: pre-warm skipped/failed — first in-app transcription will be slow"
fi
rm -f "$WARM_AIFF"

# Keep the dev copy out of LaunchServices so Spotlight/Dock/open always
# resolve the /Applications install — two registered copies of the same
# bundle id let macOS launch a second instance side by side.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -u "$(pwd)/$APP" >/dev/null 2>&1 || true

echo
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    echo "Installing to /Applications…"
    pkill -f 'Scribe.app/Contents/MacOS/Scribe' 2>/dev/null || true
    sleep 1
    rm -rf /Applications/Scribe.app
    cp -R "$APP" /Applications/
    open /Applications/Scribe.app
    echo "Installed and relaunched /Applications/Scribe.app"
else
    echo "Install + relaunch: ./scripts/make-app.sh --install"
    echo "On first launch, grant Microphone and System Audio Recording when prompted."
fi
