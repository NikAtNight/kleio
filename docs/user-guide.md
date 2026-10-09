# Kleio user guide

[Back to the README](../README.md) · [Developer guide](development.md)

Recording, transcription, and speaker detection run on your Mac. Models need a one-time download.

## Record a meeting

### App audio and video

Add a shortcut on Home for Zoom, Teams, Slack, a browser, or another installed app. Kleio captures that app's audio and your microphone separately. Browser capture includes all audible tabs. If the app target fails, Kleio reports the failure instead of switching to all system audio.

To include video, turn it on and choose a window or display with the macOS picker. Kleio writes H.264 video alongside separate microphone and app audio. Audio, video, notes, pause/resume, and transcript seeking share a timeline.

Grant Microphone and System Audio Recording access when recording. Video uses the native screen-sharing picker and the corresponding macOS permission flow. Microphone-only voice memos and explicit all-Mac-audio recording are also available.

### Audio devices and microphone identity

Choose your microphone and headset or speakers in Settings → Audio Devices or the device bar on Home. App audio is captured through the output your call plays on. Kleio doesn't change your Mac's sound settings.

Set your display name in Settings → Speakers. Your microphone is always identified as you. Choose **One other person** to assign all remote speech to one person without running a speaker model.

### Follow meeting mute

Enable this native test mode through the device bar on Home → Follow meeting mute. Candidate native readers gate microphone saving using meeting controls, with Accessibility access. Unreadable state pauses microphone saving while remote audio continues.

This mode stays off by default, requires an app shortcut, and is not yet verified in live calls. Background browser tabs may be unreadable. See the [acceptance matrix](meeting-recorder-validation.md#native-mute-sync-test-mode).

### Capture recovery and save retries

Kleio writes audio progressively to CAF and saves an atomic document manifest before capture begins. Video uses a fragmented MOV and is finalized before transcription or normal quit. Capture and save errors are visible. Recovery depends on the media actually saved; it cannot guarantee recovery from every crash or disk failure.

Completed transcription, speaker analysis, and summary results remain in memory after a save failure. **Retry Save** uses that retained result. Pending saves block normal quit, and editing drafts stay open after a failed write.

## Review speakers and transcripts

Download speaker models in Settings → Speakers. Community-1 is the default and supports automatic counting or a supplied participant count. Sortformer v2.1 is an experimental alternative for a declared two to four remote participants. That count checks eligibility; it does not force an exact number of groups.

Click a remote name to rename it or choose a saved person. Use the ellipsis or context menu to merge labels, or combine all remote labels with **Only one other person**. Undo restores assignments without replacing transcript edits. Corrections never train or rename global voice profiles. Saved people are local names, separate from the legacy voice-profile store. Original media and raw transcription remain available.

Speaker analysis can fail while the transcript remains available. Retry analysis without retranscribing or replacing your corrections. Uncertain audio is labelled for review.

Edit timestamped transcripts, search and replace words, seek through the waveform, adjust playback speed, and add meeting notes. Add reusable replacement rules in Settings → Find & Replace. Editing a word can suggest a new rule.

The native interface has light and dark appearances, saved app shortcuts, recent recordings, a people inspector, and recording controls that remain accessible while browsing.

## Transcription models

Download, select, or delete models in Settings → Models. The selected model is used for meetings, imports, and watch folders.

| Engine | Models and capabilities |
| --- | --- |
| Parakeet through FluidAudio | v3 supports 25 European languages; v2 and 110M support English; a Japanese model is also available. Parakeet has no vocabulary hints or translation. Unsupported languages or enabling Translate to English produce an error. Replacement rules still apply. |
| Whisper through WhisperKit | Tiny through Large v3, Large v3 Turbo, Distil Large v3, and compressed variants of Small, Large v3, Large v3 Turbo, and Distil. Whisper supports vocabulary hints and translation to English. |

**Unload model when idle** releases the transcription model after 1 to 60 minutes without a transcription. The default is 10 minutes; choose Never to keep it loaded. The next job reloads it. Speaker models stay loaded.

Kleio copies models already downloaded by Flo on launch, so those models do not need another download. Speaker analysis never downloads models implicitly.

## Import and export

Drag and drop media or use file import. Kleio supports batch transcription and podcast participant tracks. Copying and media inspection run in the background, with progress and file errors in the main window.

Export TXT, Markdown, HTML, SRT, VTT, CSV, JSON, or copy to the clipboard. Watch folders can transcribe and export automatically. Automatic exports preserve existing files by choosing another filename. Retry a failed export without transcribing again.

See the [import and export flow](flows/import-and-export.md) for failure handling and validation evidence.

## Calendar and call detection

Optional Calendar integration and automatic call recording use a visible countdown. See the [auto-record plan](auto-record-plan.md) for the intended trigger behavior.

Call prompts appear in the bottom-left corner with **Audio** and **Audio + screen** choices. Enable Accessibility access in Settings → Call Detection. Candidate readers cover Slack Huddles, Teams, Google Meet, Zoom, and FaceTime. Live app detection remains unverified; hidden browser tabs may be unreadable. See the [call detection flow](flows/call-detection.md).

## Menu bar

Closing the window keeps recording, transcription, and call watching running. Kleio appears in the Dock while a window is open. Reopen it from the menu bar scroll icon.

## Summaries

Summaries are optional. Choose Apple Intelligence or Ollama locally, or configure a cloud provider in Settings → AI Summaries. Apple Intelligence requires macOS 26 or later and must be available on your Mac. Transcription always stays local.

Cloud summaries send transcript text, speaker names, notes, and recording context to the provider you choose. Claude, ChatGPT, and Cursor subscription summaries use the official `claude`, `codex`, or Cursor `agent` CLI. Kleio runs them with tools off, no MCP servers or plugins, no saved session, and an empty temporary folder. It never reads the CLI's credentials. Signing in from Settings → AI Summaries opens Terminal on the CLI's own login command.

Use a general-purpose instruction model. Kleio rejects the s1-mini text-cleanup model. Long transcripts are processed in bounded parts without discarding the end. Repeated, empty, oversized, or incomplete responses are rejected. These checks detect generation failures, not factual accuracy. Review summaries against the transcript before relying on decisions or action items.

Generation continues when you navigate to another recording. Later transcript, note, or speaker-name changes mark the saved summary out of date. Renaming a recording doesn't.

### API keys

Anthropic and OpenAI keep separate model settings and API keys. Settings → AI Summaries stores keys in the macOS Keychain. Older keys move there only after storage succeeds. If the old provider is unknown, choose it and use **Move Older Settings**. Keys stay out of library backups.

## Back up and restore

Finish active recording, imports, processing, and pending saves before starting a backup. In Settings → Library & Backup, use **Back Up Library** to create a `.kleiobackup` folder. It includes recording media, manifests, transcripts, summaries, notes, saved people, voice profiles, and selected local preferences. Downloaded models and credentials are excluded.

Use **Restore Backup** to select the backup. Kleio verifies file hashes and recording metadata before changing the library. Restore runs on the next launch and preserves the previous library in `~/Library/Application Support/Scribe/Backups/`.

Keep the selected backup in place until that launch finishes. An interrupted restore is recovered before the app opens its library. Copy backups to another drive for protection from drive failure.

## Current validation limits

Automated tests cover domain behavior and generated media. Real meeting accuracy, app/process behavior, permission flows, Bluetooth transitions, and long video sessions still need native acceptance testing. The [validation checklist](meeting-recorder-validation.md) records those checks and remaining release work.
