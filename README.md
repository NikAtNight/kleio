# Scribe

A native macOS transcription app — a MacWhisper-style tool built for reliability. Records
calls from **any** app (Zoom, Teams, Meet, FaceTime, browser tabs — anything that plays
audio), transcribes locally with Whisper, and never loses a recording to a crash.

## Features

- **Meeting recording** — captures your microphone and system audio simultaneously
  with a live scrolling waveform per side; transcripts label the two sides
  **You** / **Them** like a dialogue.
- **System-audio or mic-only modes** for one-sided captures and voice memos.
- **Calendar-aware** — reads your Apple Calendar (optional), shows today's meetings
  on the home screen, and notifies you before each one with a Join shortcut.
- **Auto call recording (optional, off by default)** — arms at a meeting's start
  time, confirms a call is actually happening (conferencing app plus real audio),
  then records after a visible 10-second countdown you can cancel. Per-calendar
  opt-in, per-event overrides, and a consent explainer up front. Everything stays
  on the Mac; see `docs/auto-record-plan.md` for the design.
- **Crash-safe by design** — audio streams to disk continuously (CAF format survives an
  unfinalized write). If the app dies mid-call, the recording shows up as *Recovered* on
  next launch, ready to transcribe.
- **File transcription** — drag & drop (or ⌘O, or Finder → Open With) any audio/video
  file; batch imports queue automatically.
- **System-wide dictation** — press ⌥Space in any app, speak with a floating
  waveform HUD for feedback, then press it again; Scribe transcribes locally and
  inserts the result at the cursor, restoring your clipboard afterward (or copies
  the text when Accessibility access has not been granted). Optional local cleanup
  normalizes the dictation with Apple Intelligence or an Ollama model
  (`scripts/setup-s1-mini.sh` registers the recommended one).
- **Podcast / multi-track transcription** — import one synchronized file per participant;
  filenames seed editable speaker names and the tracks become one chronological dialogue.
- **Automatic speaker recognition (optional)** — a second on-device Core ML diarization
  pass detects speakers in ordinary imports, mic recordings, and remote meeting audio;
  labels remain editable and transcription still succeeds if diarization is unavailable.
- **Local Whisper models** — tiny → large-v3-turbo via WhisperKit (CoreML, Apple Silicon
  optimized). Download/switch/delete in Settings → Models. Seeds its first model from
  LocalFlow's cache if present.
- **Transcript editor** — timestamped segments, click a timestamp to seek, a seekable
  waveform scrubber, playback follows along with highlighting, inline text editing,
  find/replace, editable speaker names and assignments, and adjustable speed
  (0.75×–2×).
- **Automatic cleanup** — optional filler-word removal plus reusable whole-word/case-aware
  replacement rules for names and terms Whisper commonly mishears. Editing a
  transcript offers to turn your correction into a rule, and saved rules bias
  Whisper toward your vocabulary on future transcriptions.
- **Watch folders** — automatically queue stable media files added to selected folders and
  export finished TXT, Markdown, HTML, SRT, or VTT files beside the source.
- **Export** — TXT, Markdown, HTML, SRT, VTT, CSV, JSON, or copy to clipboard.
- **AI summaries (optional)** — fully local via Apple Intelligence (macOS 26+) or
  Ollama, or bring your own Anthropic/OpenAI key in Settings → AI. With a local
  provider, nothing ever leaves the Mac.
- **Microphone picker** — choose an input device in Settings → General; hot-plug
  aware, falls back to the system default when a device disappears.
- **Menu bar quick-record** — start/stop a recording without opening the main window.

## Build & install

```bash
./scripts/make-app.sh --install   # builds, signs, pre-warms CoreML, installs to /Applications
```

On first launch grant **Microphone** and **System Audio Recording** when prompted.
For automatic dictation insertion, also enable Scribe under **System Settings → Privacy &
Security → Accessibility**. Dictation still works without this permission and copies its
result to the clipboard.

## Architecture notes

- SwiftUI + SPM executable target, bundled by `scripts/make-app.sh`, signed with the
  "Talix Dev Signing" identity so TCC grants survive rebuilds.
- System audio capture: Core Audio **process tap** (`AudioHardwareCreateProcessTap`,
  macOS 14.4+) with a global stereo mixdown excluding Scribe itself, hosted in a private
  aggregate device. Needs only the "System Audio Recording" permission — no screen
  recording permission.
- Transcription: [WhisperKit](https://github.com/argmaxinc/WhisperKit); models live in
  `~/Library/Application Support/Scribe/models/` (deliberately not ~/Documents — iCloud
  eviction corrupts model caches).
- Speaker recognition: [FluidAudio](https://github.com/FluidInference/FluidAudio)'s offline
  Core ML diarization pipeline; its models are lazy-loaded only when the feature is enabled.
- Library: one folder per document under
  `~/Library/Application Support/Scribe/library/<uuid>/` — `document.json` + audio files.
- `Scribe --transcribe <file> [model]` runs headless transcription (used for CoreML
  pre-warming and testing).
