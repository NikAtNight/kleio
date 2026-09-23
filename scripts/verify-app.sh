#!/bin/bash
# Verify a packaged Kleio app after relocating it away from the checkout.
set -euo pipefail

if [ "$#" -ne 1 ] || [ ! -d "$1" ]; then
    echo "Usage: $0 /path/to/Kleio.app" >&2
    exit 1
fi

APP="$(cd "$(dirname "$1")" && pwd -P)/$(basename "$1")"
PLIST="$APP/Contents/Info.plist"
EXECUTABLE="$APP/Contents/MacOS/Kleio"

fail() {
    echo "Package verification failed: $*" >&2
    exit 1
}

[ -f "$PLIST" ] || fail "Contents/Info.plist is missing"
[ -x "$EXECUTABLE" ] || fail "Contents/MacOS/Kleio is missing or is not executable"
[ -f "$APP/Contents/Resources/AppIcon.icns" ] || fail "AppIcon.icns is missing"
plutil -lint "$PLIST" >/dev/null || fail "Info.plist is invalid"

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
SOURCE_REVISION="$(/usr/libexec/PlistBuddy -c 'Print :KleioSourceRevision' "$PLIST")"
SOURCE_TREE_STATE="$(/usr/libexec/PlistBuddy -c 'Print :KleioSourceTreeState' "$PLIST")"

[ "$BUNDLE_ID" = "app.talix.scribe" ] || fail "unexpected bundle identifier $BUNDLE_ID"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || fail "invalid marketing version $VERSION"
[[ "$BUILD_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail "invalid build version $BUILD_VERSION"
[[ "$SOURCE_REVISION" =~ ^[0-9a-f]{12}$|^unknown$ ]] || fail "invalid source revision $SOURCE_REVISION"
[[ "$SOURCE_TREE_STATE" =~ ^(clean|modified)$ ]] || fail "invalid source tree state $SOURCE_TREE_STATE"

codesign --verify --deep --strict "$APP" || fail "code signature is invalid"
if [ -n "${KLEIO_EXPECTED_SIGNING_IDENTITY:-}" ]; then
    SIGNATURE_DETAILS="$(codesign -dv --verbose=4 "$APP" 2>&1)"
    /usr/bin/grep -Fq "Authority=$KLEIO_EXPECTED_SIGNING_IDENTITY" <<< "$SIGNATURE_DETAILS" \
        || fail "expected signing identity $KLEIO_EXPECTED_SIGNING_IDENTITY was not used"
fi
ARCHITECTURES="$(lipo -archs "$EXECUTABLE")"
case " $ARCHITECTURES " in
    *" arm64 "*) ;;
    *) fail "arm64 executable slice is missing" ;;
esac

REFERENCED_BUNDLES="$(strings "$EXECUTABLE" | /usr/bin/grep -E '^[A-Za-z0-9][A-Za-z0-9._+-]*\.bundle$' | sort -u || true)"
[ -n "$REFERENCED_BUNDLES" ] || fail "the executable has no SwiftPM resource bundle references"
while IFS= read -r bundle_name; do
    [ -d "$APP/Contents/Resources/$bundle_name" ] || fail "$bundle_name is missing from Contents/Resources"
done <<< "$REFERENCED_BUNDLES"

# SwiftPM writes resource bundles flat or, on newer toolchains, under Contents/Resources.
HUB_BUNDLE="$APP/Contents/Resources/swift-transformers_Hub.bundle"
# SwiftPM writes resource bundles flat or under Contents/Resources depending on the toolchain.
[ -d "$HUB_BUNDLE/Contents/Resources" ] && HUB_BUNDLE="$HUB_BUNDLE/Contents/Resources"
[ -f "$HUB_BUNDLE/gpt2_tokenizer_config.json" ] || fail "Hub fallback tokenizer configuration is missing"
[ -f "$HUB_BUNDLE/t5_tokenizer_config.json" ] || fail "Hub fallback tokenizer configuration is incomplete"

VERIFY_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/kleio-package-verify.XXXXXX")"
cleanup_verify_root() {
    case "$VERIFY_ROOT" in
        "${TMPDIR:-/tmp}"/kleio-package-verify.*) /bin/rm -rf -- "$VERIFY_ROOT" ;;
    esac
}
trap cleanup_verify_root EXIT

RELOCATED_APP="$VERIFY_ROOT/Relocated/Kleio.app"
mkdir -p "$(dirname "$RELOCATED_APP")"
ditto "$APP" "$RELOCATED_APP"
codesign --verify --deep --strict "$RELOCATED_APP" || fail "signature did not survive relocation"

# Run the real executable before any model, preferences, or library is opened.
"$RELOCATED_APP/Contents/MacOS/Kleio" --package-self-check

echo "Verified relocated Kleio.app $VERSION ($BUILD_VERSION), $SOURCE_REVISION $SOURCE_TREE_STATE"
if strings "$EXECUTABLE" \
    | /usr/bin/grep -E '^/.*\.build/.*/swift-transformers_Hub\.bundle$' >/dev/null; then
    echo "Warning: Hub's generated GPT-2/T5 fallback still refers to its build checkout." >&2
fi
