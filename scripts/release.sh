#!/bin/bash
# Build a Developer ID signed, notarized, and stapled Kleio.dmg for public download.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$REPO_ROOT"

PROFILE="${KLEIO_NOTARY_PROFILE:-kleio-notary}"

fail() {
    echo "Release failed: $*" >&2
    exit 1
}

[ -z "$(git status --porcelain)" ] || fail "commit or stash changes first. Releases are built from a clean checkout."
SIGN_HASH="$(security find-identity -v -p codesigning | awk '/"Developer ID Application: / {print $2; exit}')"
[ -n "$SIGN_HASH" ] || fail "no Developer ID Application certificate with a private key is in the keychain."
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || fail "notary profile $PROFILE is missing or rejected. See docs/releasing.md."

KLEIO_RELEASE_IDENTITY="$SIGN_HASH" ./scripts/make-app.sh
APP="build/Kleio.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
OUT="build/release/Kleio-$VERSION-$BUILD_VERSION"
[ ! -e "$OUT" ] || fail "$OUT already exists. Bump the version or move the old release aside."
mkdir -p "$OUT"

# Waits for Apple's verdict and keeps the log next to the release when it's rejected.
notarize() {
    local file="$1" result="$OUT/notary-$(basename "$1").json"
    xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --output-format json > "$result" || true
    local status id
    status="$(plutil -extract status raw "$result" 2>/dev/null || echo unknown)"
    if [ "$status" != "Accepted" ]; then
        id="$(plutil -extract id raw "$result" 2>/dev/null || true)"
        if [ -n "$id" ]; then
            xcrun notarytool log "$id" --keychain-profile "$PROFILE" "$OUT/notary-log.json" || true
        fi
        fail "notarization of $(basename "$file") returned $status. Details: $result and $OUT/notary-log.json"
    fi
}

# Staple the app first so it opens offline after it's copied out of the disk image.
ditto -c -k --keepParent "$APP" "$OUT/Kleio-app.zip"
notarize "$OUT/Kleio-app.zip"
rm -f "$OUT/Kleio-app.zip"
xcrun stapler staple "$APP"

DMG_ROOT="$OUT/dmg-root"
mkdir -p "$DMG_ROOT"
ditto "$APP" "$DMG_ROOT/Kleio.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname Kleio -srcfolder "$DMG_ROOT" -format UDZO -o "$OUT/Kleio.dmg" >/dev/null
/bin/rm -rf -- "$DMG_ROOT"
codesign --sign "$SIGN_HASH" --timestamp "$OUT/Kleio.dmg"
notarize "$OUT/Kleio.dmg"
xcrun stapler staple "$OUT/Kleio.dmg"

# Gatekeeper's own checks, as a downloaded copy would see them.
spctl --assess --type execute --verbose=2 "$APP"
spctl --assess --type open --context context:primary-signature --verbose=2 "$OUT/Kleio.dmg"
xcrun stapler validate "$APP"
xcrun stapler validate "$OUT/Kleio.dmg"
(cd "$OUT" && shasum -a 256 Kleio.dmg > Kleio.dmg.sha256)

echo "Release ready: $OUT/Kleio.dmg ($VERSION, build $BUILD_VERSION)"
echo "Publish it with:"
echo "  gh release create v$VERSION $OUT/Kleio.dmg $OUT/Kleio.dmg.sha256 --title \"Kleio $VERSION\" --generate-notes"
