# Kleio

A native macOS meeting recorder with local transcription and speaker review. Requires macOS 15 or later. Recording, transcription, and speaker detection run on the Mac; models need a one-time download.

## Recording and review

- **App shortcuts:** capture a selected app's audio plus your microphone. Add Zoom, Teams, Slack, a browser, or another installed app. Browser capture includes all audible tabs. A failed app target never switches to all system audio.
- **Optional native video:** turn video on, then choose a window or display with the macOS picker. ScreenCaptureKit writes H.264 video alongside separate microphone and app audio. Audio, video, notes, pause/resume, and transcript seeking share a timeline.
- **Fixed microphone identity:** your microphone is always you. Set your display name and input device in Settings. Choose **One other person** to assign all remote speech to one person without running a speaker model.
- **Native mute-sync test mode:** opt in through Home → microphone options → Follow meeting mute. Candidate native readers can gate microphone saving from meeting controls, with Accessibility access. Unreadable state pauses microphone saving while remote audio continues. This stays off by default, requires an app shortcut, and is not yet verified in live calls. Background browser tabs may be unreadable. See [the acceptance matrix](docs/meeting-recorder-validation.md#native-mute-sync-test-mode).
- **Local speaker grouping:** Community-1 is the default, with automatic counting or a supplied participant count. Sortformer v2.1 is an experimental alternative for a declared two to four remote participants. Its count setting checks eligibility; it does not force an exact number of groups. Download speaker models in Settings → Models.
- **Speaker correction:** click a remote name to rename it or choose a saved person. Use the ellipsis or context menu to merge labels, or combine all remote labels with **Only one other person**. Undo restores assignments without replacing transcript edits. Corrections never train or rename global voice profiles.
- **Separate analysis state:** speaker analysis can fail while the transcript remains available. Retry speaker analysis without retranscribing or replacing your corrections. Uncertain audio is labelled for review.
- **Recoverable media:** audio is written progressively to CAF, with an atomic document manifest saved before capture begins. Video uses a fragmented MOV and is finalized before transcription or normal quit. Capture and save errors are visible. Recovery depends on the media actually saved; it is not a guarantee against every crash or disk failure.
- **Save retry:** completed transcription, speaker analysis, and summary results remain in memory if saving fails. Retry Save uses the retained result. Pending saves block normal quit, and editing drafts stay open after a failed write.
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

Summaries require a general-purpose instruction model. The s1-mini model is reserved for dictation cleanup. Long transcripts are processed in bounded parts without discarding the end; repeated, empty, oversized, or incomplete responses are rejected. These checks detect generation failures, not factual accuracy. Review summaries against the transcript before relying on decisions or action items. Generation continues when navigating to another recording. Later transcript, note, title, or speaker-name changes mark the saved summary out of date.

## Back up and restore

Settings → General includes **Back Up Library** and **Restore Backup**. A `.kleiobackup` folder contains recording media, manifests, transcripts, summaries, notes, saved people, voice profiles, and selected local preferences. Downloaded models and credentials are excluded. Finish active recording, processing, and pending saves before starting a backup.

Restore verifies file hashes and recording metadata before changing the library. It runs on the next launch and preserves the previous library in `~/Library/Application Support/Scribe/Backups/`. Keep the selected backup in place until that launch finishes. An interrupted restore is recovered before the app opens its library. Copy the backup to another drive for protection from drive failure.

## Build and verify

```sh
swift test --disable-automatic-resolution
swift build -c release --disable-automatic-resolution
```

To package and verify the app:

```sh
./scripts/make-app.sh
```

That script creates `build/Kleio.app`. Its `--install` option quits the existing app normally, backs up the old Scribe or Kleio app, and installs `/Applications/Kleio.app`. It stops if the app cannot finish saving. Add `--prewarm` to exercise the selected transcription model after packaging.

The package records its version, build number, source revision, and whether the checkout was modified. `KLEIO_VERSION` and `KLEIO_BUILD_VERSION` can override the version numbers. `./scripts/verify-app.sh build/Kleio.app` checks signing, metadata, architecture, resources, and resource reads by the actual executable after relocation. It does not run a model or open the library.

This is a development build. The generated Hub accessor still has a checkout fallback for GPT-2/T5 tokenizer defaults; the relocated resource check does not validate that accessor. Current Whisper models supply their own complete tokenizer configuration. Clean-Mac model execution, Developer ID signing, notarization, and an update channel remain release prerequisites.

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
