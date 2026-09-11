#!/bin/bash
# Package Kleio with the existing signing identity and preserve replaced apps.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$REPO_ROOT"

INSTALL=false
PREWARM=false
for option in "$@"; do
    case "$option" in
        --install) INSTALL=true ;;
        --prewarm) PREWARM=true ;;
        *) echo "Usage: $0 [--install] [--prewarm]" >&2; exit 1 ;;
    esac
done

DEFAULT_MARKETING_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
MARKETING_VERSION="${KLEIO_VERSION:-$DEFAULT_MARKETING_VERSION}"
if [[ ! "$MARKETING_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    echo "KLEIO_VERSION must contain two or three numeric components." >&2
    exit 1
fi

SOURCE_REVISION="$(git rev-parse --short=12 HEAD 2>/dev/null || true)"
SOURCE_REVISION="${SOURCE_REVISION:-unknown}"
SOURCE_TREE_STATE="clean"
BUILD_SUFFIX=""
if [ -n "$(git status --porcelain 2>/dev/null || true)" ]; then
    SOURCE_TREE_STATE="modified"
    BUILD_SUFFIX=".1"
fi
DEFAULT_BUILD_VERSION="$(git rev-list --count HEAD 2>/dev/null || true)"
DEFAULT_BUILD_VERSION="${DEFAULT_BUILD_VERSION:-1}${BUILD_SUFFIX}"
BUILD_VERSION="${KLEIO_BUILD_VERSION:-$DEFAULT_BUILD_VERSION}"
if [[ ! "$BUILD_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    echo "KLEIO_BUILD_VERSION must contain one to three numeric components." >&2
    exit 1
fi

swift build -c release --disable-automatic-resolution --product Kleio
BUILD_BIN_DIR="$(swift build -c release --disable-automatic-resolution --show-bin-path)"
mkdir -p build/app-backups
PACKAGE_STAGE="$(mktemp -d build/.kleio-package.XXXXXX)"
STAGED_APP="$PACKAGE_STAGE/Kleio.app"
APP="build/Kleio.app"
cleanup_package_stage() {
    if [ -n "${PACKAGE_STAGE:-}" ] && [ -d "$PACKAGE_STAGE" ]; then
        /bin/rm -rf -- "$PACKAGE_STAGE"
    fi
}
trap cleanup_package_stage EXIT
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BUILD_BIN_DIR/Kleio" "$STAGED_APP/Contents/MacOS/Kleio"
cp Resources/Info.plist "$STAGED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$STAGED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" "$STAGED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :KleioSourceRevision $SOURCE_REVISION" "$STAGED_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :KleioSourceTreeState $SOURCE_TREE_STATE" "$STAGED_APP/Contents/Info.plist"

if [ ! -f Resources/AppIcon.icns ] || \
   [ Resources/KleioIcon.png -nt Resources/AppIcon.icns ] || \
   [ scripts/generate-icon.swift -nt Resources/AppIcon.icns ] || \
   [ scripts/make-icon.sh -nt Resources/AppIcon.icns ]; then
    ./scripts/make-icon.sh
fi
cp Resources/AppIcon.icns "$STAGED_APP/Contents/Resources/AppIcon.icns"
for resource in "$BUILD_BIN_DIR"/*.bundle; do
    [ -d "$resource" ] || continue
    ditto "$resource" "$STAGED_APP/Contents/Resources/$(basename "$resource")"
done

# Keep the identifier stable so existing permissions and preferences survive.
SIGN_ID="Talix Dev Signing"
AVAILABLE_IDENTITIES="$(security find-identity -v -p codesigning)"
EXPECTED_SIGNER=""
if /usr/bin/grep -Fq "\"$SIGN_ID\"" <<< "$AVAILABLE_IDENTITIES"; then
    codesign --force --sign "$SIGN_ID" --identifier app.talix.scribe "$STAGED_APP"
    EXPECTED_SIGNER="$SIGN_ID"
else
    echo "Signing identity unavailable; creating a development build."
    codesign --force --sign - --identifier app.talix.scribe \
        -r='designated => identifier "app.talix.scribe"' "$STAGED_APP"
fi
codesign --verify --deep --strict "$STAGED_APP"
KLEIO_EXPECTED_SIGNING_IDENTITY="$EXPECTED_SIGNER" ./scripts/verify-app.sh "$STAGED_APP"

if $PREWARM; then
    WARM_AIFF="$(mktemp -t kleio-warm).aiff"
    if say -o "$WARM_AIFF" "A local transcription test." && \
       "$STAGED_APP/Contents/MacOS/Kleio" --transcribe "$WARM_AIFF"; then
        echo "Model cache warmed."
    else
        echo "Model pre-warm failed; the application remains available."
    fi
    rm -f "$WARM_AIFF"
fi

if [ -e "$APP" ]; then
    PACKAGE_BACKUP="$(mktemp -d build/app-backups/package.XXXXXX)"
    mv "$APP" "$PACKAGE_BACKUP/Kleio.app"
fi
mv "$STAGED_APP" "$APP"
rmdir "$PACKAGE_STAGE"
trap - EXIT
echo "Built $APP ($MARKETING_VERSION, build $BUILD_VERSION, $SOURCE_REVISION $SOURCE_TREE_STATE)"

if $INSTALL; then
    for name in Scribe Kleio; do
        if [ -e "/Applications/$name.app" ]; then
            identifier="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "/Applications/$name.app/Contents/Info.plist")"
            if [ "$identifier" != "app.talix.scribe" ]; then
                echo "Refusing to replace unrelated /Applications/$name.app." >&2
                exit 1
            fi
        fi
    done
    INSTALL_STAGE="$(mktemp -d /Applications/.kleio-install.XXXXXX)"
    ditto "$APP" "$INSTALL_STAGE/Kleio.app"
    codesign --verify --deep --strict "$INSTALL_STAGE/Kleio.app"

    # Normal termination lets the application finalize media or refuse to quit.
    swift - <<'SWIFT'
import AppKit
let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "app.talix.scribe")
for app in apps {
    guard app.terminate() else {
        fputs("Kleio could not quit. Finish the current recording before installing.\n", stderr)
        exit(1)
    }
}
let deadline = Date().addingTimeInterval(20)
while apps.contains(where: { !$0.isTerminated }) && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
if apps.contains(where: { !$0.isTerminated }) {
    fputs("Kleio is still saving or has refused to quit. Installation stopped.\n", stderr)
    exit(1)
}
SWIFT

    INSTALL_BACKUP="$(mktemp -d "$(pwd)/build/app-backups/install.XXXXXX")"
    restore_previous_apps() {
        local result=$?
        if [ "$result" -ne 0 ]; then
            for name in Scribe Kleio; do
                if [ -e "$INSTALL_BACKUP/$name.app" ] && [ ! -e "/Applications/$name.app" ]; then
                    mv "$INSTALL_BACKUP/$name.app" "/Applications/$name.app"
                fi
            done
            echo "Installation failed. Previous apps are preserved in $INSTALL_BACKUP or /Applications." >&2
        fi
    }
    trap restore_previous_apps EXIT
    for name in Scribe Kleio; do
        if [ -e "/Applications/$name.app" ]; then
            mv "/Applications/$name.app" "$INSTALL_BACKUP/$name.app"
        fi
    done
    mv "$INSTALL_STAGE/Kleio.app" /Applications/Kleio.app
    trap - EXIT
    rmdir "$INSTALL_STAGE"
    open /Applications/Kleio.app
    echo "Installed /Applications/Kleio.app. Previous apps: $INSTALL_BACKUP"
fi

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREGISTER" -u "$(pwd)/$APP" >/dev/null 2>&1 || true
