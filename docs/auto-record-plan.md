# Auto call recording, fully private: implementation plan

Status: plan only. Nothing in this document is implemented yet. It builds on the calendar
sync + notification feature (CalendarSync, meeting detection, pre-meeting notifications)
that shipped first.

## Goal

When a meeting the user opted into begins, Scribe starts a meeting-mode recording by
itself, tells the user it is doing so, and stops when the meeting ends. Everything stays
on the Mac. The user never discovers a recording they did not expect and never misses one
they did expect.

## Trigger design: calendar arms, audio confirms

The calendar knows when a meeting is scheduled. It does not know whether the user actually
joined. Recording on schedule alone produces empty recordings of silence when a meeting is
skipped, and misses meetings that run late. So the trigger has two stages:

1. **Arm.** At meeting start minus the lead time, an `AutoRecordArbiter` enters an armed
   state for that event. Armed state lasts from lead time until a configurable window past
   the scheduled start (default 15 minutes), so late joins still record.
2. **Confirm.** While armed, Scribe looks for evidence a call is actually happening:
   - A known conferencing process is running: Zoom (`us.zoom.xos`), Teams, FaceTime,
     Webex, or a browser when the event has a Meet/Teams link.
   - That evidence is corroborated by audio: the system tap (metering only, nothing
     written to disk) shows sustained output above the noise floor for a few seconds.
   Both signals together start the countdown. Metering-only taps never write audio; the
   arbiter discards levels as it reads them.
3. **Countdown.** A notification fires: "Recording <title> in 10 seconds", with Cancel and
   Start Now actions. If the user does nothing, recording starts when the countdown ends.
   Cancel disarms that event only.

States: `idle -> armed -> confirming -> countdown -> recording -> stopping -> idle`, with
cancel paths from every state.

## Consent and etiquette

- Master toggle off by default. Auto-record is opt-in per calendar, with an optional
  per-event override (context menu on the Up Next strip).
- The countdown notification is not skippable by configuration. There is always a visible
  path to cancel before recording starts.
- While recording, the menu bar icon already shows the recording state; auto-started
  recordings additionally show which event triggered them in the recording view and the
  library row.
- A first-run sheet explains recording-consent law plainly: in many places everyone on the
  call must be told they are recorded. Scribe records locally for the user's own notes;
  informing participants is the user's responsibility and the sheet says so.
- Auto-recordings are labeled distinctly in the library and can be discarded with one
  action, which deletes audio and transcript together.

## Privacy guarantees (and how they are enforced)

- **Nothing leaves the Mac.** Capture, transcription (WhisperKit), and diarization
  (FluidAudio) are already local. Auto-recording adds no network calls anywhere in the
  trigger or recording path. The only network features in Scribe remain model downloads
  and optional cloud summaries.
- **Summaries of auto-recordings default to local providers** (Apple Intelligence or
  Ollama once the local-summary lane ships) or to none. Cloud summarization of an
  auto-recording requires the user to invoke it explicitly per document.
- **Calendar data stays minimal.** Scribe stores at most the event title and identifier on
  the resulting document so the transcript is named usefully. A setting turns that off.
  Attendee names and notes are never persisted.
- **Metering is not recording.** The confirmation stage reads levels only; the recording
  files are created exactly when the countdown completes, which is also when the crash
  marker is written.
- These guarantees go in the README and in the auto-record settings pane in plain words.

## Stopping

Recording stops at the first of:

- Manual stop (always wins, from window or menu bar).
- Scheduled end plus grace (default 5 minutes), if audio has gone quiet.
- Sustained silence: both mic and system stay under the noise floor for N minutes
  (default 3), regardless of schedule. Covers meetings that end early.
- The confirming conferencing process quits.

Stopping behaves exactly like a manual stop today: finalize tracks, enqueue transcription.

## Failure modes

- **Permissions revoked** (calendar, microphone, system audio): disarm, notify once, and
  surface the state in Settings -> Calendar. Never retry silently.
- **Mac asleep at meeting start:** timers are re-evaluated on wake (`NSWorkspace`
  wake notification); a meeting still inside its armed window arms immediately.
- **Scribe not running:** out of scope for the first version. Auto-record works while
  Scribe runs (it already stays alive for the menu bar). A login item is a later opt-in.
- **Overlapping meetings:** one recording at a time; the active one wins and the second
  event's notification offers to stop and switch.
- **Low disk:** below a threshold, refuse to auto-start and notify instead.
- **Crash mid-recording:** unchanged from today; continuous CAF streaming plus the
  `.recording` crash marker means the file recovers on next launch.

## Implementation sketch

New: `AutoRecordArbiter` (state machine above), `AudioProcessMonitor` (CoreAudio process
list + running-app checks + metering hook on the existing tap). Modified: `CalendarSync`
(expose armed-window events and per-calendar auto-record flags), `RecordingSession`
(accept a triggering-event reference), notification category with Cancel/Start Now,
settings pane additions, library labeling. Tests: state machine transitions are pure and
unit-testable; process detection and metering get fake-driven tests.

Rough order: arbiter + tests, process monitor, notification plumbing, settings, labeling.
Ships dark behind the master toggle until the whole path has soaked.
