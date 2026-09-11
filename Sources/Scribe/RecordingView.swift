import SwiftUI

/// Full-screen state while a recording is in flight. The waveform keeps each
/// recorded side visible without asking the user to read separate meters.
struct ActiveRecordingView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var queue: TranscriptionQueue
    @EnvironmentObject private var recording: RecordingSession
    @EnvironmentObject private var appState: AppState

    @State private var pulse = false
    @State private var confirmDiscard = false
    @State private var noteText = ""
    @State private var noteSaveError: String?

    private var activeDocument: ScribeDocument? {
        recording.activeDocumentID.flatMap { library.document(id: $0) }
    }

    private var recordsMic: Bool {
        activeDocument?.tracks.contains { $0.source == .microphone } ?? false
    }

    private var recordsSystem: Bool {
        activeDocument?.tracks.contains { $0.source == .system } ?? false
    }

    private var waveformLanes: [LiveWaveformLane] {
        if recordsMic && recordsSystem {
            return [
                LiveWaveformLane(label: activeDocument?.microphoneSpeakerName ?? "Me", history: recording.micHistory, color: .blue),
                LiveWaveformLane(label: "Other participants", history: recording.systemHistory, color: .purple),
            ]
        }
        if recordsMic {
            return [LiveWaveformLane(label: activeDocument?.microphoneSpeakerName ?? "Me", history: recording.micHistory, color: .accentColor)]
        }
        if recordsSystem {
            return [LiveWaveformLane(label: "Other participants", history: recording.systemHistory, color: .accentColor)]
        }
        return []
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            LiveWaveformView(
                lanes: waveformLanes,
                isPaused: recording.isPaused,
                lastAppend: recording.lastWaveformAppend
            )
            .padding(.horizontal, 24)

            Spacer(minLength: 22)

            HStack(spacing: 12) {
                Circle()
                    .fill(recording.isPaused ? .orange : .red)
                    .frame(width: 8, height: 8)
                    .opacity(recording.isPaused ? 1 : (pulse ? 1 : 0.45))
                    .animation(
                        recording.isPaused ? .default : .easeInOut(duration: 1).repeatForever(autoreverses: true),
                        value: pulse
                    )
                Text(recording.elapsed.clockString)
                    .font(.system(size: 56, weight: .semibold).monospacedDigit())
            }
            .onAppear { pulse = !recording.isPaused }
            .onChange(of: recording.isPaused) { _, isPaused in
                pulse = !isPaused
            }

            Text(recording.isFinalizing ? "Finishing media…" : recording.isPaused ? "Paused" : (activeDocument?.title ?? "Recording"))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            HStack(spacing: 16) {
                if recordsSystem {
                    Label(activeDocument?.recordingAppName ?? "All Mac audio", systemImage: "app.badge.waveform")
                }
                if activeDocument?.videoTracks?.isEmpty == false {
                    Label("Video on", systemImage: "video.fill")
                }
            }
            .font(.callout).foregroundStyle(.secondary)
            .padding(.top, 8)

            if let state = recording.meetingMuteState {
                MeetingMuteStatusView(state: state)
                    .padding(.top, 12)
            }

            Spacer(minLength: 30)

            controlCluster

            notesArea

            Spacer(minLength: 24)

            if let message = recording.healthMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .padding(.horizontal)
            }

            Text("Recordings stay on this Mac. Keep Kleio open while media finishes saving.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(recording.isFinalizing)
        .confirmationDialog("Discard this recording?", isPresented: $confirmDiscard) {
            Button("Discard Recording", role: .destructive) {
                recording.discard(library: library)
            }
        } message: {
            Text("The audio recorded so far will be deleted permanently.")
        }
        .alert("Note not saved", isPresented: Binding(
            get: { noteSaveError != nil },
            set: { if !$0 { noteSaveError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(noteSaveError ?? "")
        }
    }

    private var controlButtons: some View {
        HStack(spacing: 12) {
            Button {
                recording.togglePause()
            } label: {
                Label(recording.isPaused ? "Resume" : "Pause",
                      systemImage: recording.isPaused ? "play.fill" : "pause.fill")
                    .frame(minWidth: 90)
            }
            .controlSize(.large)

            Button {
                let id = recording.activeDocumentID
                recording.stop(library: library, queue: queue)
                if let id { appState.select(document: id) }
            } label: {
                Label("Stop & Transcribe", systemImage: "stop.fill")
                    .frame(minWidth: 150)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(.red)

            Button("Discard", role: .destructive) {
                confirmDiscard = true
            }
            .controlSize(.large)
        }
        .padding(12)
    }

    @ViewBuilder
    private var controlCluster: some View {
        if #available(macOS 26.0, *) {
            controlButtons.glassEffect(.regular, in: Capsule())
        } else {
            controlButtons.background(.regularMaterial, in: Capsule())
        }
    }

    private var notesArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Add a note…", text: $noteText)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addNote)

            if let notes = activeDocument?.notes, !notes.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(notes) { note in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(note.time.clockString)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 48, alignment: .trailing)
                                Text(note.text)
                                    .font(.callout)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
            }
        }
        .frame(maxWidth: 520)
        .padding(.top, 14)
        .padding(.horizontal, 20)
    }

    private func addNote() {
        let text = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let documentID = recording.activeDocumentID else { return }
        do {
            try DocumentEditing.appendNote(
                MeetingNote(time: recording.elapsed, text: text),
                documentID: documentID,
                library: library
            )
            noteText = ""
        } catch {
            noteSaveError = error.localizedDescription
        }
    }
}

private struct MeetingMuteStatusView: View {
    let state: MeetingMuteState

    var body: some View {
        switch state {
        case .muted:
            Label("Microphone muted in meeting", systemImage: "mic.slash")
                .font(.callout).foregroundStyle(.secondary)
        case .unmuted:
            Label("Following meeting microphone", systemImage: "mic")
                .font(.callout).foregroundStyle(.secondary)
        case .unavailable(let reason):
            VStack(spacing: 4) {
                Label("Microphone saving paused", systemImage: "mic.slash")
                    .font(.callout).foregroundStyle(.orange)
                Text(reason).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }.frame(maxWidth: 440).padding(.horizontal)
        }
    }
}

struct LevelMeter: View {
    let label: String
    let icon: String
    let level: Float

    var body: some View {
        HStack(spacing: 10) {
            Label(label, systemImage: icon)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 170, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(meterColor)
                        .frame(width: max(6, geo.size.width * CGFloat(level)))
                        .animation(.linear(duration: 0.12), value: level)
                }
            }
            .frame(height: 8)
        }
    }

    private var meterColor: Color {
        level > 0.85 ? .orange : .green
    }
}

/// Keeps capture controls accessible while browsing previous recordings.
struct RecordingStatusBar: View {
    @EnvironmentObject private var recording: RecordingSession
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var queue: TranscriptionQueue
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: recording.isFinalizing ? "externaldrive" : "record.circle.fill")
                .foregroundStyle(recording.isPaused ? .orange : .red)
            Button {
                if let id = recording.activeDocumentID ?? recording.pendingSaveDocumentID { appState.select(document: id) }
            } label: {
                Text(recording.hasPendingSave ? "Recording needs to be saved" : recording.isFinalizing ? "Finishing recording…" : "\(recording.isPaused ? "Paused" : "Recording") · \(recording.elapsed.clockString)")
                    .font(.callout.weight(.semibold).monospacedDigit())
            }.buttonStyle(.plain)
            if let state = recording.meetingMuteState {
                MeetingMuteStatusView(state: state).lineLimit(1)
            }
            if let message = recording.healthMessage {
                Text(message).font(.caption).foregroundStyle(.orange).lineLimit(1)
            }
            Spacer()
            if recording.hasPendingSave {
                Button("Retry save") { recording.retryFinalSave(library: library, queue: queue) }
                    .buttonStyle(.borderedProminent)
            } else if recording.isFinalizing {
                ProgressView().controlSize(.small)
            } else {
                Button(recording.isPaused ? "Resume" : "Pause") { recording.togglePause() }
                Button("Stop", systemImage: "stop.fill") {
                    let id = recording.activeDocumentID
                    recording.stop(library: library, queue: queue)
                    if let id { appState.select(document: id) }
                }
                .buttonStyle(.borderedProminent).tint(.red)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(.bar)
    }
}
