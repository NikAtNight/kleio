# Kleio

A native macOS meeting recorder with local transcription and speaker review. Requires macOS 15 or later. Recording, transcription, and speaker detection run on the Mac; models need a one-time download.

## Recording and review

- **App shortcuts:** capture a selected app's audio plus your microphone. Add Zoom, Teams, Slack, a browser, or another installed app. Browser capture includes all audible tabs. A failed app target never switches to all system audio.
- **Optional native video:** turn video on, then choose a window or display with the macOS picker. ScreenCaptureKit writes H.264 video alongside separate microphone and app audio. Audio, video, notes, pause/resume, and transcript seeking share a timeline.
- **Fixed microphone identity:** your microphone is always you. Set your display name and input device in Settings. Choose **One other person** to assign all remote speech to one person without running a speaker model.
- **Local speaker grouping:** Community-1 is the default, with automatic counting or a supplied participant count. Sortformer v2.1 is an experimental alternative for a declared two to four remote participants. Its count setting checks eligibility; it does not force an exact number of groups. Download speaker models in Settings → Models.
- **Speaker correction:** click a remote name to rename it or choose a saved person. Use the ellipsis or context menu to merge labels, or combine all remote labels with **Only one other person**. Undo restores assignments without replacing transcript edits. Corrections never train or rename global voice profiles.
- **Separate analysis state:** speaker analysis can fail while the transcript remains available. Retry speaker analysis without retranscribing or replacing your corrections. Uncertain audio is labelled for review.
- **Recoverable media:** audio is written progressively to CAF, with an atomic document manifest saved before capture begins. Video uses a fragmented MOV and is finalized before transcription or normal quit. Capture and save errors are visible. Recovery depends on the media actually saved; it is not a guarantee against every crash or disk failure.
- **Native interface:** grouped light/dark surfaces, saved app shortcuts, recent recordings, a people inspector, and recording controls that remain accessible while browsing.

## Other features

- Microphone-only voice memos and an explicit all-Mac-audio recording mode.
- Drag and drop, file import, batch transcription, and podcast participant tracks.
- Local Whisper models through WhisperKit, with download, selection, and deletion in Settings.
- Timestamped transcript editing, search/replace, waveform seeking, playback speed, and meeting notes.
- Export to TXT, Markdown, HTML, SRT, VTT, CSV, JSON, or the clipboard.
- Optional Calendar integration and automatic call recording with a visible countdown. See [the auto-record plan](docs/auto-record-plan.md).
- System-wide dictation with ⌥Space, optional local cleanup, and reusable replacement rules.
- Watch folders with automatic transcription and export.
- Optional summaries through Apple Intelligence or Ollama locally, or a cloud provider explicitly configured in Settings → AI.

## Build and verify

```sh
swift test --disable-automatic-resolution
swift build -c release --disable-automatic-resolution
```

To package the app using the existing signing and model pre-warming script:

```sh
./scripts/make-app.sh
```

That script creates `build/Kleio.app`. Its `--install` option quits the existing app normally, backs up the old Scribe or Kleio app, and installs `/Applications/Kleio.app`. It stops if the app cannot finish saving. Add `--prewarm` to exercise the selected transcription model after packaging.

This is a development build for this checkout. Bundled SwiftPM resources retain build-path fallbacks; clean-machine packaging and notarization still need validation.

Grant Microphone and System Audio Recording access when recording. Video uses the native screen-sharing picker and the corresponding macOS permission flow. Dictation insertion also needs Accessibility access; otherwise it copies the result to the clipboard.

The automated tests cover domain behavior and generated media. Real meeting accuracy, app/process behavior, permission flows, Bluetooth transitions, and long video sessions still need native acceptance testing. See [the validation checklist](docs/meeting-recorder-validation.md) and [implementation evidence](docs/flows/meeting-recording.md).

## Storage and implementation

- SwiftUI and AppKit, built as a Swift Package executable.
- Core Audio process taps select app/helper processes. ScreenCaptureKit and AVAssetWriter handle optional video. `RecordingClock` and `TimelineAudioWriter` keep both audio sources aligned and preserve interruptions as silence.
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) handles local transcription; [FluidAudio](https://github.com/FluidInference/FluidAudio) supplies Core ML speaker models. Speaker analysis never downloads models implicitly.
- Each library document lives in `~/Library/Application Support/Scribe/library/<uuid>/`, with `document.json` and its media files. Optional manifest fields preserve compatibility with older documents.
- The Kleio rename preserves the `app.talix.scribe` bundle identifier, existing preferences, and Scribe storage paths. The Swift module remains `Scribe`; the executable and visible app name are `Kleio`.
- Saved people are local names, independent of the legacy voice-profile store. Original media and raw transcription remain available through speaker corrections.
- `Kleio --transcribe <file> [model]` runs headless transcription.
- `Kleio --benchmark-speakers <audio> <reference.json> <report.json>` compares local speaker intervals with annotated audio. It refuses to replace an existing report. See [the benchmark format and measured limits](docs/meeting-recorder-validation.md#local-speaker-inference-smoke-check).
