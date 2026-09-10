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

Not run: real Zoom/Teams/Meet/Slack recordings, speaker-model downloads or actual diarization inference, microphone clock/device transitions, permission flows, long sessions, and abrupt-crash movie recovery. No private meeting audio was used. Use [the native acceptance checklist](../meeting-recorder-validation.md) for these checks.

## Corrections and model limits

Saved-person creation is an explicit checkbox. Choosing or renaming a document speaker does not change saved voice fingerprints. Existing voice-profile names can seed the independent name list without moving embeddings.

The microphone remains fixed. One-other-person mode bypasses both diarization models and yields one remote label. Community-1 uses a supplied count as a clustering constraint. Sortformer requires a declared two to four remote participants and can still produce false splits within its four output groups. Uncertain and unanalyzed audio are review labels, excluded from the dashboard's participant count.

Speaker retry preserves corrected text and speaker assignments, including edits made while analysis was running. Interrupted analysis is recoverable without retranscribing. A partial recovered transcript names omitted sources in a persistent warning. Failed final saves preserve media and a pending manifest, protect the document from deletion, and expose Retry save.
