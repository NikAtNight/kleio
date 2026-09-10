# Meeting recorder validation

This checklist covers the native implementation. The interface concept in `local-recording-review.html` is a design reference, not capture evidence.

## Automated checks

Run from the repository root:

```sh
swift test --disable-automatic-resolution
swift build -c release --disable-automatic-resolution
```

The focused suites cover speaker correction and undo, transcript word alignment, explicit participant counts, app shortcut persistence, capture target resolution, recording clock behavior, storage failures, and media composition. See `flows/meeting-recording.md` for the recorded results.

## Native acceptance checks

Use a test call with consenting participants and no private screen content. Model downloads need a connection once; recording and inference should then work offline.

1. Add Zoom, Teams, Slack, and a browser shortcut. Restart Scribe and verify the shortcuts remain. Remove a shortcut and confirm it stays removed.
2. Start a call with one other person. Choose **One other person**, leave video off, and record speech from both sides. Verify the transcript has the fixed microphone identity and one remote identity, including brief replies and changes in tone.
3. Record three remote participants with automatic detection. Include short replies, similar voices, interruptions, and overlapping speech. Check the detected count and listen around every speaker change.
4. In a browser call, confirm remote audio is captured from the browser. Play a test sound in another tab to confirm browser-wide capture; sound from an unrelated application must be excluded when using an app shortcut.
5. Enable video and select a window, then repeat with a display. Confirm the selection shown by macOS matches the captured image. Cancel the picker and verify no recording starts.
6. Pause and resume. Briefly disconnect and reconnect a test microphone. Confirm audio, video, notes, transcript times, and seeking remain aligned. Confirm input loss is visible.
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
