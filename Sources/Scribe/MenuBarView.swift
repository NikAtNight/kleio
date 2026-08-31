import SwiftUI

/// Menu bar quick-recorder: start/stop a recording without opening the main
/// window — handy when a call is already ringing.
struct MenuBarView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var queue: TranscriptionQueue
    @EnvironmentObject private var recording: RecordingSession
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var dictation: DictationController
    @EnvironmentObject private var calendarSync: CalendarSync
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let nextMeeting, nextMeeting.start.timeIntervalSinceNow <= 60 * 60 {
            Text("Next: \(nextMeeting.title) at \(nextMeeting.start.formatted(date: .omitted, time: .shortened))")
            if let joinURL = nextMeeting.joinURL {
                Button("Join") { NSWorkspace.shared.open(joinURL) }
            }
            Divider()
        }

        if dictation.enabled {
            switch dictation.phase {
            case .idle:
                Button {
                    dictation.toggle()
                } label: {
                    Label("Start Dictation  ⌥Space", systemImage: "mic")
                }
            case .preparing:
                Label("Preparing Dictation…", systemImage: "mic")
            case .recording:
                Button {
                    dictation.toggle()
                } label: {
                    Label("Finish Dictation  ⌥Space", systemImage: "stop.circle.fill")
                }
                Button("Cancel Dictation", role: .destructive) {
                    dictation.cancelRecording()
                }
            case .transcribing:
                Label("Transcribing Dictation…", systemImage: "ellipsis.circle")
            }
            if let message = dictation.lastMessage {
                Text(message)
            }
            Divider()
        }

        if recording.isRecording {
            Text("Recording, \(recording.elapsed.clockString)")
            Button(recording.isPaused ? "Resume" : "Pause") {
                recording.togglePause()
            }
            Button("Stop & Transcribe") {
                let id = recording.activeDocumentID
                recording.stop(library: library, queue: queue)
                if let id { appState.select(document: id) }
                openMain()
            }
            Button("Discard Recording") {
                recording.discard(library: library)
            }
        } else {
            ForEach(RecordingMode.allCases) { mode in
                Button {
                    Task { await recording.start(mode: mode, library: library) }
                } label: {
                    Label(mode.title, systemImage: mode.icon)
                }
                .disabled(dictation.phase != .idle)
            }
        }

        Divider()

        let recent = library.documents.prefix(5)
        if !recent.isEmpty {
            Menu("Recent Transcripts") {
                ForEach(Array(recent)) { doc in
                    Button(doc.title) {
                        appState.select(document: doc.id)
                        openMain()
                    }
                }
            }
            Divider()
        }

        Button("Open Scribe") {
            openMain()
        }
        SettingsLink {
            Text("Settings…")
        }
        Divider()
        Button("Quit Scribe") {
            NSApp.terminate(nil)
        }
    }

    private func openMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private var nextMeeting: Meeting? {
        calendarSync.upcomingMeetings.first { $0.start >= Date() }
    }
}
