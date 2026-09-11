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

## Transcript turn order correction

Requirement source: the user's September 10 report that a microphone sentence appears before a remote reply even when part of that sentence was spoken afterward, and playback then scrolls upward. Main owns this correction.

Observed causes:

- Legacy recordings store whole recognizer segments without word timing. Sorting those chunks by their start cannot place an intervening reply inside a microphone chunk.
- Playback previously selected the last segment containing the current time. After a short reply ended, an older, longer microphone segment became active again and triggered upward scrolling.
- Speaker heading grouping only hides repeated headings. It does not merge or reorder text.

The queue now applies track offsets, preserves the raw transcript, and calls `TranscriptTiming.chronologicalTurns` before saving display segments. Complete word alignment trims decoder silence padding. Speech from another audio source wholly inside a word gap splits the surrounding segment into separate turns. Continuous overlapping speech remains overlapping. Missing, invalid, or edited word alignment leaves the segment intact. Original word timings, source and speaker identity survive, and the first piece keeps its segment ID. `SpeakerDiarizer` reuses the word alignment and splitting code. The persisted order is shared by transcript reading, full text and exports.

`TranscriptView` uses `TranscriptTiming.activeSegmentID` to choose the latest-started segment, then checks whether that segment is still active. It never falls back to an older enclosing segment. Explicit backward seeking still works.

Acceptance evidence:

- PASS: `swift test --disable-automatic-resolution`, 141 tests with zero failures. `TranscriptTimingTests` covers microphone/app-audio replies, repeated pauses, short replies, overlapping interruptions, equal starts, legacy and corrected text, invalid timing, punctuation, stable identities, and backward seeking. Its persistence/export check exercises reopening a temporary library and TXT/SRT/VTT/CSV ordering. `TranscriptionApplicationTests` covers the queue's first transcription, legacy raw preservation, later re-transcription, and concurrent edits.
- PASS: a local diagnostic sampled the selected legacy recording's full saved timeline every 100 ms. The old selector moved backward 22 times; the new selector moved backward zero times across 347 segments. This verifies selection from saved timing, not the accuracy of those timestamps against every spoken word.
- LIMITED: local transcription of a 90-second excerpt supplied word timing but did not reliably retain short replies. It was not used to replace the historical transcript. Exact repair of that transcript's sentence boundaries remains unverified; the playback correction works with its existing data.

Evidence is under ignored `build/kleio-timing-review/`. Personal audio and transcript diagnostics stay local and are excluded from source control. The diagnostic test was moved out of the test target after running. Permanent regression fixtures contain synthetic text only. This section refers to the uncommitted timing changes after `ff3008e` on macOS with Swift 6.3.3; it does not supersede the recording and model-accuracy limits above.

- PASS: final `./scripts/make-app.sh --install`, release build, code-signature verification, and installed executable comparison. `/Applications/Kleio.app` was replaced and launched; the previous app is in `build/app-backups/install.rc058a/Kleio.app`. All five recording manifests remained byte-for-byte unchanged.
- REVIEW: independent read-only review requested queue-level preservation coverage, now included. A concern about interruptions beginning before the microphone pause was resolved with an explicit regression: the resumed microphone phrase belongs after the reply, while the initial overlap stays intact. Grouping the entire remote recognizer chunk would reintroduce the original ordering problem.

## Recording error and recovery view

Requirement source: the user's September 10 screenshot of a generic transcription failure with a retry button that cannot repair missing audio. Main owns implementation; an independent read-only review checked recovery behavior and remaining release gaps.

`DocumentDetailView` now uses `RecordingProblemView` for failed and recovered recordings. The view retains the recording title, date, duration, and navigation. It shows the state of each audio source, a specific explanation, and actions appropriate to the files present. Raw error text and filenames are in a collapsed details disclosure. A saved transcript remains accessible after a failed retry. This follows [Apple's guidance on useful error messages and actions](https://developer.apple.com/design/human-interface-guidelines/alerts).

`RecordingAudioAvailability` is shared by this view and `TranscriptionQueue`. It distinguishes available, missing, empty, and unreadable audio by opening each file and reading its first buffer. This check does not guarantee the rest of a file will decode. Check again reruns inspection after files are restored; it does not alter media.

Transcribing only the available sources requires an explicit action such as **Transcribe microphone only**. Ordinary retries, including recovered recordings, reject missing sources. Partial processing retains source references and publishes a warning with the completed transcript. It does not invent a crash-recovery timestamp. A failed retry or an edit made during processing leaves the prior transcript's warning intact. Pending recording saves block enqueueing.

Acceptance evidence for the uncommitted changes after `ff3008e`:

- PASS: `swift test --disable-automatic-resolution`, 145 tests with zero failures. Recovery tests cover missing, empty, corrupt, restored, and available files, explicit partial processing, and refusal when no usable audio remains. Transcript application tests cover warning changes and concurrent edits.
- PASS: five native rendering fixtures cover light/dark appearances, a narrow window, missing or partially available sources, ordinary retry, and recovered audio. These establish rendering, not button interaction or live capture.
- PASS: a synthetic microphone recording ran through the real queue and the cached Small English model. Ordinary retry failed without replacing saved text or its warning; explicit partial processing succeeded, retained source metadata and the original transcript, and identified omitted app audio. No private recording was reprocessed.
- PASS: `git diff --check` and debug build. Existing cached-module warnings remain.

Local evidence is under ignored `build/kleio-error-review/`. The temporary native rendering and model-dependent queue tests were moved out of the permanent test target after verification. Remaining release work is prioritized in [the acceptance checklist](../meeting-recorder-validation.md#remaining-release-work).

- PASS: `./scripts/make-app.sh --install` completed the release build, signed and installed `/Applications/Kleio.app`, and launched it. The installed executable and icon match the tested package; strict code-signature verification passed. All five existing recording manifests remained byte-for-byte unchanged. The previous app is preserved in `build/app-backups/install.D09bBM/Kleio.app`. Clean-machine distribution remains unverified.

## Summary generation correction

Requirement source: the user's September 10 report that a generated summary repeated a passage and misrepresented the conversation. Main owns implementation and local acceptance. An independent read-only review inspected model selection, provider behavior, stale writes, and tests.

Observed cause: the selected summary provider was local Ollama using s1-mini, which is a transcript normalizer rather than a general instruction model. The [publisher's model card](https://huggingface.co/superwhisper/s1-mini) documents that restriction. The old summary request supplied no system instruction, guessed a 150,000-character input limit, ignored Ollama's completion reason, and saved any nonempty output. Source inspection also found recorded narration in the selected transcript; summarization must not turn that material into participants' commitments.

The corrected flow runs from `TranscriptView.summarize` through `SummaryService.summarize` and the chosen provider, then `applyingSummary` and `LibraryStore.update`:

- AI Settings marks s1-mini as dictation-only, and SummaryService rejects it before inference. Dictation Settings and `TranscriptCleaner` retain their existing model selection and control-line behavior.
- Provider, model, key, and formatting prompt are captured for the entire job. Local generation stays on localhost; no provider fallback or automatic download is introduced.
- Ollama's `/api/show` supplies the model's declared context limit, capped at 32,768 for a summary request. Missing metadata fails before inference. The request explicitly sets `num_ctx` and reserves 768 output tokens. Apple Intelligence uses its documented 4,096-token context. Byte budgets reserve instructions, output, and message framing; long sources split at line boundaries where possible and retain every character.
- `generateSummary` processes excerpts sequentially, then condenses their notes until the final summary fits. Intermediate notes use grounding instructions without the final formatting contract. Failure or non-shrinking output stops the operation. The prompt distinguishes commitments from suggestions, past actions, stories, and recorded media.
- Provider finish reasons, empty output, excessive size, and repeated 12-word passages are checked before saving. These checks do not prove semantic accuracy. The same output check collapses invalid old summaries behind a disclosure with a regeneration explanation.
- `sourceText` supplies metadata, speaker labels, transcript text, and notes for both generation and stale-write checks. It excludes prior generated summaries. `applyingSummary` refuses a changed source or another saved summary. Deleted recordings and failed library writes report an error instead of pretending the result was saved.

Acceptance evidence for the uncommitted changes after `ff3008e`:

- PASS: `swift test --disable-automatic-resolution`, 156 tests with zero failures. Focused summary tests cover task eligibility, context metadata, truncated output, lossless Unicode chunking, inclusion of the final source passage, final synthesis, intermediate failure, empty input, large prompts, source metadata, and concurrent edits. Existing dictation-cleanup checks pass.
- PASS: native light/dark summary rendering, including the collapsed invalid-output state. These fixtures use synthetic text and establish rendering, not model accuracy.
- PASS, execution only: cached Gemma 3 4B ran both a synthetic meeting and the selected local transcript through the updated pipeline, including bounded multi-part processing and a full-source request with a declared larger context.
- FAIL, semantic acceptance: Gemma 3 4B still invented decisions and treated narrative events as action items. The candidate outputs were not saved to the user's library and this model was not selected automatically.
- NOT RUN: Apple Intelligence generation, which is disabled on this Mac, cloud-provider requests, and a larger local model. The user chose to finish the app fix without a model download. No model was downloaded, no summary provider was changed, and the failed candidate outputs remain local diagnostics. Summary accuracy remains unresolved for the installed models tested here.

Evidence, synthetic fixtures, and private local diagnostics are under ignored `build/kleio-summary-review/`. Temporary model and rendering tests were moved out of the permanent target after running. References: [Ollama generate API](https://docs.ollama.com/api/generate), [Apple context limits](https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window), and [OpenAI completion limits](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create). OpenAI's output bound uses `max_completion_tokens`; no cloud key or private transcript was sent during verification.

- PASS: final focused summary and dictation-cleanup run, 20 tests with zero failures. `./scripts/make-app.sh --install` built, signed, installed, and launched the update. The installed executable matches the package and strict signature verification passed. All five recording manifests remain byte-for-byte unchanged, including their summaries. Provider/model preferences are unchanged. The previous app is preserved in `build/app-backups/install.lYNiAt/Kleio.app`.
## Reliability follow-up, September 10

Owner: the integrating agent. Requirement: fix the architecture review findings in parallel, with natural Zoom, Teams, Meet, and Slack evaluation deferred until the user has representative recordings. No new model downloads or cloud integration. Workers used isolated worktrees; main reviewed and integrated their changes without replacing earlier uncommitted work.

Implemented boundaries:

- `TranscriptionQueue` owns each decoding and speaker-analysis job through persistence. Every phase saves before continuing or exporting. A failed write retains the completed result for Retry Save without running the model again. Cancellation targets the selected document, including queued work. Deleted documents are never recreated by late results. Quit cancels queued inference, drains active work, and tries retained saves before permitting exit.
- `DocumentEditing` applies transcript, title, note, replacement, and speaker edits to the latest document. Views clear their draft or display success only after persistence. Failed speaker undo restores its undo entry for retry without replacing later text edits.
- `LibraryStore` owns each pending recording's final document and retry disposition. `RecordingSession` uses that state for retry, deletion protection, and quit. The internal `RecordingCaptureDriving` boundary lets lifecycle tests control startup, callback failure, and asynchronous video finalization without opening real devices. Manual and automatic startup share the 1 GB disk preflight. Cancelling native startup stops video only after startup settles.
- `SummaryJobs` belongs to the app, survives navigation, prevents duplicate jobs, and retains valid results for save retry. Pending saves remain visible while browsing other recordings. Persistence marks a retained summary out of date when its transcript, notes, title, or speaker labels change. Regeneration clears that marker only after validating its source. Markdown and HTML exports label stale summaries. Historical summaries have no source fingerprint and are not retroactively classified.
- `LibraryBackup` copies media, manifests, saved people, voice profiles, and allowlisted preferences. It excludes downloaded models and credentials. SHA-256 inventories detect changed or incomplete copies, and inspection validates recording references and runtime metadata. Restore stages a verified copy, preserves the previous library, and records each transaction in a journal before replacing data. Startup completes or rolls back an interrupted restore before opening stores. `LibraryBackupJobs` owns Settings operations and normal quit waits for them; hashing runs away from the UI thread.
- Packaging records version, build number, revision, and modified-checkout state. The verifier checks signatures, metadata, architecture, dependency resources, and direct resource reads by the relocated real executable before any library or model opens. It does not validate the upstream Hub generated accessor or run a model. GPT-2/T5 fallback lookup still requires an upstream or deliberate private dependency fix. Developer ID signing and notarization remain release work.

Acceptance evidence:

- PASS: `swift test --disable-automatic-resolution`, 212 permanent tests with zero failures. The temporary native rendering helper was moved out of the test target after its own successful run. It includes controlled queue/summary completion in both orders, simultaneous retained saves, edit and undo failures, queued cancellation, deletion, partial-audio consent, startup cancellation, failed final saves, and a second library's refusal to take an unsaved recording.
- PASS: backup round-trip, changed-file rejection, hash-consistent invalid metadata rejection, model and credential preservation, and scheduled restore. Separate child processes exit before and after the restore commit; the next launch restores the prior library or finishes committed cleanup as appropriate. Repeated recovery preserves the result.
- PASS: native light/dark summary rendering and a pending-save fixture using synthetic text. The previews establish rendering, not complete UI interaction or model accuracy.
- PASS: independent reviews of job continuation, editing, capture ownership, backup recovery, and app integration. Findings led to added coverage for startup ordering, two-library ownership, stale summaries, restore cleanup, and backup work during quit.

Local evidence is under ignored `build/kleio-reliability-review/` and `build/reliability-*.log`. Synthetic capture-driver media is placeholder data used only to test orchestration. Existing generated-audio/video suites test actual file timing and composition separately. No private recording was reprocessed, no summary model was changed, and no model was downloaded.

Not run: natural-call evaluation, live device or Bluetooth failure, sleep/wake, long sessions, a physically constrained volume, clean-Mac model execution, and public notarized distribution. Summary factual accuracy remains unresolved for the previously tested installed model. The user will supply real meetings for the next evaluation round.

- PASS: the final backup job tests cover normal quit while copying or scheduling, duplicate starts, failed work that finishes before quit reaches it, and cancelled restore confirmation. Both final validation passes run outside the UI actor.
- PASS: `./scripts/make-app.sh --install`, including release compilation, strict signature verification, and direct resource reads by the relocated executable. `/Applications/Kleio.app` was replaced and is running. The installed executable matches `build/Kleio.app`; its own `--package-self-check` passes. Version is 1.0.0, build 39.1, revision ff3008ec8862, modified checkout. Existing dependency and cached-module warnings remain.
- PASS: all 18 library and people-store files remained byte-for-byte unchanged after installation, including the five recording manifests and media. Summary and transcription model selections also remained unchanged. The previous app is retained at `build/app-backups/install.lUCzdQ/Kleio.app`.
- PASS: `git diff --check`, `bash -n scripts/make-app.sh scripts/verify-app.sh`, and `plutil -lint Resources/Info.plist`. No commit, push, dependency upgrade, model execution, model download, or cloud request was part of this reliability follow-up. The complete local source diff is retained at `build/kleio-reliability-review/changes.patch`.
