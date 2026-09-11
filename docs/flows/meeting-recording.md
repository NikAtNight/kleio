# Meeting recording and speaker review

Owner: main implementation agent. Requirement source: the September 10, 2026 user conversation and `docs/local-recording-review.html`.

## Intended behavior

- Native Mac application with an iOS-inspired interface, app and browser shortcuts, and optional window/display video.
- Capture the selected app's audio plus the preferred microphone. Browser capture includes all audible tabs. Never silently widen a failed app target to all system audio.
- The microphone always belongs to the user. Detect remote speaker groups locally; saved names are optional. One-other-person mode bypasses count inference.
- Rename using saved people, merge remote labels, combine all remote labels, and undo. Preserve words, timestamps, microphone attribution, original detection results, and saved global voice profiles.
- Record audio and optional video on a shared timeline. Surface failures, protect active recordings from deletion, and finalize before transcription.
- Preserve old library documents. No cloud transcription, browser extension, account requirement, or automatic screen recording.

## Implementation lanes and boundaries

- Main agent owns `Models.swift`, the dashboard, app wiring, settings, and this flow record.
- Capture worker owns recording/session/storage/playback implementation and focused tests in its isolated worktree. Exposes app selection and optional native screen selection to the dashboard.
- Speaker worker owns `Transcriber`, `SpeakerDiarizer`, `TranscriptionQueue`, and related tests. Uses word timestamps, document speaker options, and visible analysis state.
- Transcript worker owns `TranscriptView`, speaker editing domain logic, saved people, and focused tests. Provides `ScribeDocument.normalizeSpeakerIdentities()` for assigning stable identities from source and existing labels.

Shared document additions are optional Codable fields for backward compatibility. `DocumentSpeaker` separates a stable identifier from its display name. `TranscriptWord` preserves word timing. `VideoTrack` records a file's session offset and duration. Audio track offsets default to zero when absent.

## Acceptance checks chosen before implementation

1. A one-to-one meeting produces the fixed microphone identity and one remote identity, irrespective of remote voice changes. Test the transcription/assignment boundary with synthetic transcript fixtures.
2. A speaker change inside an ASR segment becomes correctly attributed turns without losing words. Test timed word-to-speaker alignment and uncertain overlaps.
3. Naming and merging a remote label updates every affected segment, supports undo, and preserves microphone assignments, times, wording, and saved profiles. Test document editing operations and real temporary persistence.
4. Old documents decode. Recording write/manifest failure is observable. Deleting an active recording cannot remove its files. Test library and recording lifecycle boundaries using temporary storage.
5. App target selection survives process restarts and never falls back to global capture. Test target resolution with supplied process data; real app capture is a separate hardware check.
6. Video selection, pause/resume, finalization, playback and transcript seeking use one timeline. Test media composition with generated fixtures; permission and device transitions need a signed native app and explicit source selection.

Use `swift test --disable-automatic-resolution --filter <suite>` per slice, then `swift test --disable-automatic-resolution` and a release build for integration. The initial 65-test baseline passed during review.

## Current implementation and evidence

Implemented in the native app on September 10, 2026. The existing library format and application foundation were extended.

| Boundary | Files and reuse |
| --- | --- |
| App setup | `ContentView.swift`, `AppShortcutStore.swift`, `SettingsView.swift`, and `Theme.swift`; the dashboard and capture code share `RecordingApplication`. |
| Capture timing | `RecordingClock.swift` supplies audio, video, and session time. `TimelineAudioWriter` is reused by the microphone and app-audio capture paths. |
| Video | `ScreenRecorder.swift` owns native selection/capture. `TimelineVideoWriter` separates encoding from screen hardware so generated movies can verify timing. |
| Lifecycle and recovery | `RecordingSession.swift`, `LibraryStore.swift`, `RecordingView.swift`, `MenuBarView.swift`, `DictationController.swift`, and `ScribeApp.swift`; pending saves block conflicting operations and can be retried. |
| Playback | `PlaybackController.swift` composes audio and optional video on one player. |
| Speaker analysis | `SpeakerAnalysis.swift` is reused for initial processing and speaker-only retry. `SpeakerDiarizer.swift` handles local models and word alignment; `Transcriber.swift` retains word timing. |
| Corrections | `SpeakerEditing.swift` owns normalization, merging, naming, assignment, and undo snapshots. `SavedPeopleStore.swift` persists names independently. `TranscriptView.swift` exposes those operations. |
| Compatibility | Optional additions in `Models.swift` retain old-document decoding and recording recovery provenance. |

Verification completed:

- `swift test --disable-automatic-resolution`: **108 tests passed**, zero failures. The review baseline was 65 tests. New checks cover real generated CAF samples, encoded H.264 timestamps, failed final saves, partial recovery, speaker edits/undo, local model guards, and old manifests.
- `swift build -c release --disable-automatic-resolution`: passed. Remaining warnings concern FluidAudio's unhandled benchmark documentation and cached module debug information. No authored-source warnings remain.
- Native window captures reviewed for the dashboard in light/dark mode, video setup at 940 pixels wide, and transcript review at normal and smaller widths. Fixtures contained generated audio and synthetic text. The temporary rendering harness was removed after verification.
- Generated speech was transcribed successfully by the installed Whisper Small English model, first using the executable and then the packaged app. This verifies the local ASR path, not multi-person accuracy.
- Independent read-only review found silence-buffer initialization, app-helper scope, failed final-save recovery, partial-track recovery, and dictation lifecycle issues. These were fixed and rechecked with no outstanding finding in that review scope.
- `git diff --check`: passed.

Review artifacts are in `build/meeting-recorder-review/`: an ad-hoc signed `Scribe.app`, native preview images, and validation logs. Code-signature verification passed. This is a development build for this checkout; clean-machine distribution and notarization were not validated. SwiftPM resource accessors retain build-path fallbacks.

The user authorized replacing `/Applications/Scribe.app`. The replacement was signed with the existing development identity, verified, and launched. The previous application remains in `build/app-backups/20260910-194221/Scribe.app`. Existing recordings were preserved.

User review of the installed dashboard and transcript view found crowded controls, heavy transcript cards, and too little reading space. Native rendering checks established that the views render; the intended visual refinement remains unfinished.

At the first build, real Zoom/Teams/Meet/Slack recordings, speaker-model downloads or actual diarization inference, microphone clock/device transitions, permission flows, long sessions, and abrupt-crash movie recovery had not been run. The refinement results below supersede those gaps where stated. No private meeting audio was used. Use [the native acceptance checklist](../meeting-recorder-validation.md) for the remaining checks.

## Corrections and model limits

Saved-person creation is an explicit checkbox. Choosing or renaming a document speaker does not change saved voice fingerprints. Existing voice-profile names can seed the independent name list without moving embeddings.

The microphone remains fixed. One-other-person mode bypasses both diarization models and yields one remote label. Community-1 uses a supplied count as a clustering constraint. Sortformer requires a declared two to four remote participants and can still produce false splits within its four output groups. Uncertain and unanalyzed audio are review labels, excluded from the dashboard's participant count.

Speaker retry preserves corrected text and speaker assignments, including edits made while analysis was running. Interrupted analysis is recoverable without retranscribing. A partial recovered transcript names omitted sources in a persistent warning. Failed final saves preserve media and a pending manifest, protect the document from deletion, and expose Retry save.

## Kleio refinement and validation

The user authorized parallel refinement after committing the first build as `4fe4ff0`, then chose the standalone name Kleio. Main owns integration and this record. The transcript, speaker-validation, and capture-validation lanes used separate worktrees at that commit.

- `ContentView.swift` now has a narrower sidebar without waveform thumbnails, a compact microphone/count options popover, a persistent video switch, app tiles, and a grouped recent-recordings list. The native sidebar keeps Home accessible when the library is empty.
- `TranscriptView.swift` groups consecutive speaker headings visually while retaining every original segment and timestamp. Reading text is 16 points, cards are removed, and People starts closed. Below 880 points of detail width, People opens as a popover. Search hits retain individual speaker headings. `TranscriptReadingLayoutTests` exercises identity, source, and note boundaries.
- The visible name and SwiftPM product are Kleio. The Scribe module, `app.talix.scribe` identifier, preferences, and storage paths stay unchanged to retain existing data and permissions. `scripts/make-app.sh` packages Kleio, verifies signing, stages installation, requests normal termination, and backs up replaced apps. It refuses to replace unrelated apps or continue while the existing app is still saving.
- `SpeakerBenchmark` is a diagnostic CLI used by the public-fixture checks. It uses the existing `SpeakerDiarizer` and `SpeakerAnalysis` paths, refuses existing report paths, and reports interval coverage with explicit scoring limits. It does not upload audio or infer identity accuracy from a correct count.
- `RecordingClock.captureSlices` retains all active portions of buffers crossing pause/resume boundaries. `TimelineAudioWriter` uses those slices for both microphone and app audio. Video finalization retains its first completed duration, and one-second movie fragments reduce the amount at risk before an abrupt exit.
- Restart recovery publishes a stopped or failed-analysis state even when the recovery manifest cannot be written. Existing media and the on-disk crash marker remain available, and the write error stays visible.

Measured checks:

- PASS: Community-1 detected two groups in the public annotated two-speaker fixture and one in exclusive single-speaker excerpts. It still misassigned short speech. A constructed two-real-plus-one-synthetic fixture produced three groups. These are smoke checks, not accuracy claims about actual meetings. See [source links, timings, scoring definitions, and limits](../meeting-recorder-validation.md#local-speaker-inference-smoke-check).
- PASS: native capture of only a generated test window, with no audio capture. Decoding verified pre-pause blue frames, resumed green frames, and no red frames displayed during pause. Existing screen authorization was sufficient; no permission changes or picker interactions occurred.
- PASS: generated audio/video playback composition, pause boundaries, exact sample values, repeated finalization, and failed recovery persistence. A subprocess exiting without finalizing a two-second generated movie left 1.1 seconds and 30 frames decodable with one-second fragments. The old five-second interval left that short movie unreadable.
- PASS: read-only app process resolution found Slack, Teams, and Zen processes and reported a stopped Safari unavailable. This does not establish which audio a live meeting provides through those process taps.

Remaining manual acceptance: actual Zoom/Teams/Meet/Slack audio, microphone identity with speakerphone echo, window/display picker interaction, device and Bluetooth transitions, sleep/wake, long sessions, and held-out natural multi-person calls. Completed movie fragments can recover; the final open fragment and every disk failure are not guaranteed recoverable. Clean-machine packaging and notarization remain unverified.

Integration evidence after the refinement:

- PASS: `swift test --disable-automatic-resolution`, 124 tests with zero failures. This excludes the temporary native rendering helper, which was removed after its final successful run.
- PASS: `./scripts/make-app.sh`, including a release build of the Kleio product and code-signature verification. Existing dependency/debug-cache warnings remain; no authored-source warning was reported.
- PASS: native window captures in light/dark appearances, a 940-point window with video setup visible, transcript reading, and native People/error-details popover interactions using generated fixtures. App launch and real meeting acceptance are separate checks.
- PASS: packaged Kleio transcribed locally generated speech and detected two groups from the public annotated fixture.
- PASS: fresh read-only review of UI, branding, report output safety, packaging, and capture changes. No concrete findings remain.
- PASS: `git diff --check`, `bash -n scripts/make-app.sh`, and `plutil -lint Resources/Info.plist`.

Evidence is retained under ignored `build/kleio-review/`, with native previews, speaker/capture fixtures and reports, and build/test logs. The first rebuild is commit `4fe4ff0`; refinement evidence refers to the changes since that commit.

Installed `/Applications/Kleio.app` after checking that all five existing documents were ready. The old app is backed up at `build/app-backups/install.Bsyypg/Scribe.app`. Code-signature verification passed, the installed executable matches the tested package, the app opened a window, and all five pre-existing document manifests remained byte-for-byte unchanged.
