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
                LiveWaveformLane(label: "You", history: recording.micHistory, color: .blue),
                LiveWaveformLane(label: "Them", history: recording.systemHistory, color: .purple),
            ]
        }
        if recordsMic {
            return [LiveWaveformLane(label: "You", history: recording.micHistory, color: .accentColor)]
        }
        if recordsSystem {
            return [LiveWaveformLane(label: "Them", history: recording.systemHistory, color: .accentColor)]
        }
        return []
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            LiveWaveformView(lanes: waveformLanes, isPaused: recording.isPaused)
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

            Text(recording.isPaused ? "Paused" : (activeDocument?.title ?? "Recording"))
                .foregroundStyle(.secondary)
                .padding(.top, 6)

            Spacer(minLength: 30)

            controlCluster

            Spacer(minLength: 24)

            Text("Audio saves to disk continuously. A crash cannot lose it.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog("Discard this recording?", isPresented: $confirmDiscard) {
            Button("Discard Recording", role: .destructive) {
                recording.discard(library: library)
            }
        } message: {
            Text("The audio recorded so far will be deleted permanently.")
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
                appState.selection = id
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
