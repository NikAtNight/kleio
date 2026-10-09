# Kleio development

[Back to the README](../README.md) · [User guide](user-guide.md)

Use an Apple silicon Mac running macOS 15 or later and Xcode with the Swift 6 toolchain. The app and tests use Swift 5 language mode in `Package.swift`.

On a fresh checkout, resolve dependencies first:

```sh
swift package resolve
```

## Build and verify

```sh
swift test --disable-automatic-resolution
swift build -c release --disable-automatic-resolution
```

To package and verify the app:

```sh
./scripts/make-app.sh
open build/Kleio.app
```

That script creates `build/Kleio.app`. Its `--install` option quits the existing app normally, backs up the old Scribe or Kleio app, and installs `/Applications/Kleio.app`. It stops if the app cannot finish saving. Add `--prewarm` to exercise the selected transcription model after packaging.

The package records its version, build number, source revision, and whether the checkout was modified. `KLEIO_VERSION` and `KLEIO_BUILD_VERSION` can override the version numbers. `./scripts/verify-app.sh build/Kleio.app` checks signing, metadata, architecture, resources, and resource reads by the actual executable after relocation. It does not run a model or open the library.

This is a development build. The generated Hub accessor still has a checkout fallback for GPT-2/T5 tokenizer defaults; the relocated resource check does not validate that accessor. Current Whisper models supply their own complete tokenizer configuration. Clean-Mac model execution, Developer ID signing, notarization, and an update channel remain release prerequisites.

Grant Microphone and System Audio Recording access when recording. Video uses the native screen-sharing picker and the corresponding macOS permission flow.

The automated tests cover domain behavior and generated media. Real meeting accuracy, app/process behavior, permission flows, Bluetooth transitions, and long video sessions still need native acceptance testing. See [the validation checklist](meeting-recorder-validation.md) and [implementation evidence](flows/meeting-recording.md).

The packaging script uses the local `Talix Dev Signing` identity if available, or ad hoc development signing otherwise. App icon generation is documented in [Resources](../Resources/README.md).

## Storage and implementation

- SwiftUI and AppKit, built as a Swift Package executable.
- Core Audio process taps select app/helper processes. ScreenCaptureKit and AVAssetWriter handle optional video. `RecordingClock` and `TimelineAudioWriter` keep both audio sources aligned and preserve interruptions as silence.
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) runs Whisper models; [FluidAudio](https://github.com/FluidInference/FluidAudio) runs Parakeet models and supplies Core ML speaker models. FluidAudio is pinned to its 0.17 minor because it ships breaking changes in minor releases. Speaker analysis never downloads models implicitly. Parakeet models live in `~/Library/Application Support/Scribe/models/FluidAudio/`.
- Each library document lives in `~/Library/Application Support/Scribe/library/<uuid>/`, with `document.json` and its media files. Optional manifest fields preserve compatibility with older documents.
- The Kleio rename preserves the `app.talix.scribe` bundle identifier, existing preferences, and Scribe storage paths. The Swift module remains `Scribe`; the executable and visible app name are `Kleio`.
- Saved people are local names, independent of the legacy voice-profile store. Original media and raw transcription remain available through speaker corrections.
- `Kleio --transcribe <file> [model]` runs headless transcription.
- `Kleio --benchmark-speakers <audio> <reference.json> <report.json>` compares local speaker intervals with annotated audio. It refuses to replace an existing report. See [the benchmark format and measured limits](meeting-recorder-validation.md#local-speaker-inference-smoke-check).
