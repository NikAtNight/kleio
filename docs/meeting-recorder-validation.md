# Meeting recorder validation

This checklist covers the native implementation. The interface concept in `local-recording-review.html` is a design reference, not capture evidence.

## Automated checks

Run from the repository root:

```sh
swift test --disable-automatic-resolution
swift build -c release --disable-automatic-resolution
```

The focused suites cover speaker correction and undo, transcript word alignment, explicit participant counts, app shortcut persistence, capture target resolution, recording clock behavior, storage failures, and media composition. They also exercise the real queue and summary-job owners with controlled inference, recording orchestration with a synthetic driver, and backup restore across a child-process exit. See `flows/meeting-recording.md` for the recorded results.

## Remaining release work

The redesign and automated fixes do not establish reliability on everyday calls. This order reflects the September 10 review and September 11 Teams capture investigation.

| Priority | Work | Completion evidence |
| --- | --- | --- |
| 1 | Validate real Zoom, Teams, Meet/browser, and Slack capture. Include first-run permissions, window/display selection, Bluetooth changes, sleep/wake, and a long call. | Both audio sources remain audible and correctly attributed; app capture excludes unrelated apps; optional video and transcript seeking stay aligned. |
| 1 | Verify native automatic mute syncing for meeting apps before relying on it. The opt-in test mode is off by default. The user declined a manual-mute workaround and browser extensions. | Test Teams, Slack, Zoom, and browser controls against saved microphone audio using the matrix below. Unknown state pauses microphone saving. No adapter is verified yet. |
| 2 | Measure transcription and speaker accuracy on a small set of labelled natural calls. Review short replies, overlap, false speaker splits, and legacy recordings without word timing. | Repeatable results on the same held-out calls, with model versions and scoring rules recorded. Preview any legacy timing repair before replacing saved text. |
| 3 | Validate native source-loss feedback and disk pressure on a constrained test volume. Local backup/restore and shared manual/automatic disk preflight are implemented and covered with temporary fixtures. | Exercise an actual writer failure without filling the personal machine's main disk. Restore a representative library on another disk and verify playback. Synthetic lifecycle checks do not establish hardware behavior. |
| 4 | Finish distribution. Version metadata, strict signing, and relocated executable resource checks are implemented. Developer ID signing, notarization, clean-Mac model execution, and an update channel remain. | Install and run offline on a clean Mac after model setup, then upgrade without losing its library. Resolve Hub's generated GPT-2/T5 resource accessor before relying on those fallback defaults. |
| Deferred | Revisit optional cloud-provider integration and migrate provider keys from preferences to Keychain. | The user deferred cloud work. Test any future credential migration with dummy values before enabling it. |

Source boundaries: `RecordingSession.swift`, `RecordingCaptureDriver.swift`, `LibraryStore.swift`, `LibraryBackup.swift`, `DocumentEditing.swift`, `SummaryJobs.swift`, `TranscriptionQueue.swift`, `SpeakerBenchmark.swift`, `SettingsView.swift`, `SummaryService.swift`, and the packaging scripts. RecordingSession checks for at least 1 GB available before manual or automatic startup. Unavailable capacity metadata does not block startup. Recovery from a short generated movie does not establish recovery from every interrupted meeting or disk failure.

## Native acceptance checks

Use a test call with consenting participants and no private screen content. Model downloads need a connection once; recording and inference should then work offline.

1. Add Zoom, Teams, Slack, and a browser shortcut. Restart Scribe and verify the shortcuts remain. Remove a shortcut and confirm it stays removed.
2. Start a call with one other person. Choose **One other person**, leave video off, and record speech from both sides. Verify the transcript has the fixed microphone identity and one remote identity, including brief replies and changes in tone.
3. Record three remote participants with automatic detection. Include short replies, similar voices, interruptions, and overlapping speech. Check the detected count and listen around every speaker change.
4. In a browser call, confirm remote audio is captured from the browser. Play a test sound in another tab to confirm browser-wide capture; sound from an unrelated application must be excluded when using an app shortcut.
5. Enable video and select a window, then repeat with a display. Confirm the selection shown by macOS matches the captured image. Cancel the picker and verify no recording starts.
6. Pause and resume. Briefly disconnect and reconnect a test microphone. Confirm audio, video, notes, transcript times, and seeking remain aligned. Confirm input loss is visible. Test Bluetooth output at both 24 and 48 kHz, and change its route during app-audio capture. A changed app-audio format must stop with the captured files retained. Confirm a device with unverified physical-input mapping is rejected before app audio is saved.
7. Stop capture. Confirm the recording finishes saving before analysis starts. Quit during a test recording and during finalization; reopen and inspect the saved media.
8. Rename a remote speaker using a saved person. Merge another label into it, merge all remote labels, and undo. Confirm text, timings, microphone attribution, notes, and saved voice profiles stay intact.
9. Retry speaker analysis after editing text and speaker labels. Confirm corrections remain. Simulate missing speaker models or an unavailable model and confirm a visible analysis failure with the transcript retained.
10. Use a temporary library on a constrained test volume to exercise write failures. Never fill the personal machine's main disk. Confirm save failures are visible and active recordings cannot be deleted.

## Compare speaker models

Community-1 remains the default. Sortformer is an experimental local alternative for a declared count of two to four remote participants. The supplied count constrains Community-1 clustering. For Sortformer, it checks the four-person limit and does not force an exact number of groups. One-person mode bypasses diarization. The microphone is separate and does not count toward that model limit.

Use the same unedited remote audio for each model. Keep a small set of manually labelled calls from Zoom, Teams, Meet/browser, and Slack. Record:

- Actual and detected remote participant count, including false splits and false merges.
- Correct speaker attribution on timed speech, with overlap scored separately.
- Missing short replies and words placed across a speaker boundary.
- Processing time, peak memory, and model version.

Do not compare benchmark percentages from different datasets or scoring rules. Do not claim that a model is more accurate for Scribe until the same recordings have been evaluated. A lower word error rate from Whisper or Parakeet does not establish better speaker grouping.

Primary model references: [Pyannote Community-1](https://huggingface.co/pyannote/speaker-diarization-community-1), [NVIDIA Sortformer v2.1](https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1), and the pinned FluidAudio documentation in `.build/checkouts/FluidAudio/Documentation/Diarization/`.

## Local speaker inference smoke check

On September 10, 2026, Community-1 ran through the application actor on a public, annotated 30-second recording. This is one smoke fixture, not a meeting-accuracy benchmark or a comparison against MacWhisper.

Environment: Apple M5 Pro, 64 GiB memory, macOS 26.6.2. FluidAudio remains pinned to 0.15.5. The [Community-1 Core ML assets](https://huggingface.co/FluidInference/speaker-diarization-coreml/tree/1ed7a662fdc7109e36d822db793ee6eebdaf8594) had 21,599,417 required bytes in repository metadata. The local cache occupies 21,776,918 bytes after loading. Download plus model preparation took 9.48 seconds. No paid service, private recording, capture permission, or global preference change was involved.

The [pyannote tutorial fixture and RTTM](https://github.com/pyannote/pyannote-audio/tree/2.1.1/tutorials/assets) contain two anonymized real speakers, 22.46 seconds of annotated speech, and 1.89 seconds where both reference speakers are active. The one-speaker derivative concatenates exclusive speaker91 excerpts at 14.8 to 17.8 and 22.0 to 27.5 seconds from that same recording. It is 8.5 seconds long. Those edited excerpts are not a natural continuous meeting.

| Input | Mode | Output groups | Analysis wall time |
| --- | --- | --- | --- |
| Original 30-second sample | Automatic, first inference | 2 | 4.04 s |
| Original 30-second sample | Automatic, warm rerun | 2 | 0.384 s |
| Original 30-second sample | Known count 2 | 2 | 0.380 s |
| 8.5-second one-speaker derivative | Automatic | 1 | 0.246 s |
| 8.5-second one-speaker derivative | Known count 1 | 1 by policy | 0.00033 s |

Analysis timing includes cached-model loading when the actor has not prepared it. The first run followed the download; later runs benefited from system compilation/cache state. The one-person result uses the application's bypass and performs no model inference or speech detection, so it has no accuracy metrics.

Both two-person runs produced the same assignments. Correct counting did not imply perfect attribution. Reference speaker91's exclusive speech overlapped the other speaker's main cluster for 0.869 seconds cumulatively. About 0.731 seconds came from the short reply at 7.55 to 8.35 seconds; the remainder came from other boundary errors. There was also 0.218 seconds of secondary-cluster overlap for reference speaker90, below the report's 0.25-second split/merge pairing threshold. The model left 0.098 seconds of annotated speech uncovered. Automatic analysis of the one-speaker derivative produced no extra group and left 0.028 seconds uncovered. No thresholds or model settings were tuned to this sample.

Scoring definitions:

- The report partitions the union of reference and detected interval boundaries, without rounding to frames.
- Reference speech duration is the union of annotated speaker activity. Unannotated silence is excluded from identity and missed-speech calculations. Extra detected activity during silence is not scored by this diagnostic.
- Missing speech means reference activity with no detected cluster active. During overlapping reference speech, one detected cluster is sufficient for this coverage check; it does not measure recovery of both voices.
- The identity overlap matrix uses only intervals with exactly one reference speaker. The 1.89 seconds of overlapping reference speech are reported separately and excluded from this matrix.
- There is no boundary collar. Timing errors close to reference boundaries contribute to the overlap values.
- A reference voice with at least 0.25 seconds in each of multiple clusters triggers the split indicator. A cluster with at least 0.25 seconds from each of multiple reference voices triggers the merge indicator. These flags can both trigger even when the overall group count is correct. They are diagnostic flags, not standard DER, JER, or a speaker-identification score.
- Clip-identity references get no speech-accuracy metrics, since whole clips can include silence.

Artifacts: `/tmp/scribe-speaker-validation/` contains the source audio/RTTM, JSON references, model metadata, run logs, and JSON reports. Audio SHA-256 is `c319b4abca767b124e41432d364fd7df006cb26bb79d09326c487d606a134e6e`; RTTM SHA-256 is `d78fe62c69d8e6dcbb42c26adfce83faccb374c5a1e6d987fe37f85f1c173c87`. Main can retain these under an ignored build artifact directory. No media or downloaded model is part of the patch.

## Reproduce with a local reference

After building, invoke:

```sh
./.build/debug/Kleio --benchmark-speakers /path/audio.wav /path/reference.json /path/report.json --count 2
```

Omit `--count` for automatic counting. `--count 1` exercises the application bypass. `--model sortformer` selects the existing optional backend and still requires its supported declared count. `--download-models` is the explicit optional model-download action; it never uploads audio. Without that flag, analysis only reads cached models.

Reference format:

```json
{
  "annotationKind": "speechActivity",
  "source": "Description or source URL for the annotations",
  "turns": [
    {"speaker": "A", "start": 0.5, "end": 2.0},
    {"speaker": "B", "start": 2.2, "end": 4.1}
  ]
}
```

Use `clipIdentity` instead of `speechActivity` when labels cover complete clips rather than annotated speech. The output intentionally omits accuracy metrics for those references. Names are arbitrary consistent labels, and intervals can overlap. The CLI rejects invalid intervals and refuses to replace existing output files, including aliases of the audio or reference files.

Tests use known interval fixtures to verify silence exclusion, overlap exclusion, split/merge counting, safe output paths, and the no-model single-person report. They do not establish long-call performance or model accuracy. Still untested: real conferencing compression, echoes, distant voices, device changes, more than two speakers, long-session drift, Sortformer inference, and end-to-end ASR word alignment on this public recording.

## Constructed three-voice diagnostic

A separate 71.065-second fixture combines the existing public two-speaker pyannote sample with a locally generated third voice. The order is the original sample at 0 to 30 seconds, silence at 30 to 31, macOS Daniel speech at 31 to 40.065, silence at 40.065 to 41.065, and the original sample repeated at 41.065 to 71.065. Daniel was generated with `/usr/bin/say -v Daniel -r 170 --data-format=LEI16@16000 --file-format=WAVE`; its text and all boundaries are in `multi-fixture.json`.

This is a constructed mixture of two real voices and one synthetic voice, not a natural three-person meeting. The repeated real excerpts test whether the original two groups survive insertion of the third voice; they do not add independent human speakers or new human speech.

Community-1 produced three groups with automatic counting in 0.908 seconds and with known count 3 in 0.642 seconds. Both modes produced the same assignment intervals. The two original voices retained their dominant groups S1 and S2; the synthetic clip occupied S3. The synthetic clip had 9.065 seconds of S3 coverage, with no S1/S2 coverage. That is whole-clip coverage, including possible pauses, and is not a speech-accuracy score.

For the duplicated real audio, the RTTM supplies 44.92 seconds of speech activity. Of that, 3.78 seconds contains overlapping reference speech and is excluded from identity comparison. No boundary collar is applied. Silence is excluded. A total of 0.183 seconds of reference speech has no detected cluster. On exclusive speech, speaker90 overlaps its dominant S1 group for 19.866 seconds and S2 for 0.412 seconds; speaker91 overlaps its dominant S2 group for 19.549 seconds and S1 for 1.874 seconds. Pairings can overlap when the model emits two groups, so these columns are not a partition or a DER score. Correct group count again coexists with local attribution errors.

`multi-auto.json` and `multi-known-3.json` are the CLI reports. Their generic accuracy metrics are omitted because the combined reference is explicitly marked `clipIdentity`. `multi-summary.json` computes coverage separately for the human speech annotations and the whole synthetic clip, with definitions and limitations included. No source, inference setting, package, preference, capture state, or model asset changed for this check.


## Native mute-sync test mode

**Status: live acceptance NOT RUN.** The user will help test later. Enable **Follow meeting mute** in Home's microphone options only for these tests. Grant Kleio Accessibility access manually when ready, and start from the chosen app shortcut. Leave test mode off for ordinary use until its behavior is verified. With syncing off, Kleio records the microphone independently of meeting-app mute.

There is no browser extension. Candidate browser readers use native Accessibility and recognized meeting origins. Native app readers currently require explicit English own-microphone action labels. Missing or unsupported labels produce an unavailable state, not a guessed mute value. All Mac audio + mic, calendar recording, and automatic recording lack a selected app target and cannot start while the test mode is enabled. Voice memos and system-audio-only recordings remain independent.

| App or path | Current evidence | Live acceptance |
| --- | --- | --- |
| Teams desktop | Parser fixtures and out-of-call read returning unavailable | NOT RUN |
| Slack desktop | Parser fixtures and out-of-call read returning unavailable | NOT RUN |
| Zoom desktop | Parser fixtures only | NOT RUN |
| Meet in a browser | Origin and action-label fixtures only | NOT RUN |
| Teams or Slack in a browser | Origin and own-microphone fixtures only | NOT RUN |
| Hidden/background browser meeting | Unavailable state is implemented; actual AX exposure is unknown | NOT RUN |

For each available app/browser combination:

1. Start muted and speak a distinct test phrase. Unmute and speak another. Mute again. Listen to the saved microphone CAF to confirm only the unmuted phrase is present and remote audio continues.
2. Repeat with keyboard shortcuts and any temporary-unmute control. Include quick toggles and speech at the boundaries. Polling can miss a brief transition; synthetic tests cannot prove these phrases are excluded.
3. Minimize the call, switch windows and browser tabs, then return. The status must remain accurate or become unavailable with microphone saving paused. Tab audio mute must never be mistaken for meeting microphone mute.
4. Open a second test call, disconnect/rejoin audio, and end the call. Ambiguous or missing state must suppress new microphone samples. A new call must require fresh confirmations.
5. Pause/resume Kleio and stop while muted or unmuted. Verify duration, later speech timing, remote audio, optional video, and the final microphone tail.
6. During an agreed permission test, revoke Accessibility access. The microphone must become unavailable without stopping remote capture. Restore access and verify fresh confirmations are required.

Record app/browser/macOS versions, the observed own-microphone labels, transition timing, saved-audio checks, and unsupported states before declaring support. Do not store room URLs, chat text, or participant names in diagnostics. Live Bluetooth transitions remain deferred.
