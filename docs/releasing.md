# Releasing Kleio

[Back to the developer guide](development.md)

`scripts/release.sh` turns a clean checkout into a `Kleio.dmg` that opens on other Macs without Gatekeeper warnings. It signs with Developer ID and the hardened runtime, notarizes the app, staples it, then does the same for the disk image.

## One-time setup

1. A **Developer ID Application** certificate with its private key must be in the login keychain. Check with `security find-identity -v -p codesigning`.
2. Save notarization credentials in the keychain under the profile name `kleio-notary`:

   ```sh
   xcrun notarytool store-credentials kleio-notary \
     --apple-id <developer account email> --team-id <team ID from the certificate name>
   ```

   It prompts for an app-specific password. Create one at [account.apple.com](https://account.apple.com) under Sign-In and Security. An App Store Connect API key works too (`--key`, `--key-id`, `--issuer`). Set `KLEIO_NOTARY_PROFILE` to use a different profile name.

## Cut a release

1. Set `CFBundleShortVersionString` in `Resources/Info.plist`, or pass `KLEIO_VERSION`. The build number is the commit count.
2. Commit everything. The script refuses a modified checkout.
3. Run `./scripts/release.sh`. Each notarization usually takes a few minutes.

The output goes to `build/release/Kleio-<version>-<build>/`: `Kleio.dmg` and its SHA-256. If Apple rejects a submission, the script keeps the notary response and log in that folder. The script ends with the Gatekeeper checks (`spctl`) and stapler validation, and then prints the `gh release create` command to publish.

Before publishing, open the DMG on another Mac (or a fresh user account) and check that Kleio launches, asks for microphone, system audio, and calendar access, and records a short call.

## Entitlements

The hardened runtime blocks the microphone and calendars unless the app declares them, so `Resources/Kleio.entitlements` declares those two. System audio taps, screen capture, and Accessibility rely on the macOS privacy prompts and need no entitlement. Add an entitlement there before shipping a feature that uses another protected resource, such as the camera or Apple Events.

## Notes

- A release build is signed by a different identity than local `make-app.sh` builds, so installing it on a development Mac makes macOS ask for permissions again.
- The app is Apple silicon only.
- There is no auto-update yet. Users download new versions by hand.
