import SwiftUI

/// Full-screen state while a recording is in flight: pulsing indicator,
/// elapsed clock, per-source level meters, pause/stop/discard.
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

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.red.opacity(recording.isPaused ? 0 : 0.25))
                    .frame(width: 84, height: 84)
                    .scaleEffect(pulse ? 1.25 : 0.9)
                    .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulse)
                Circle()
                    .fill(recording.isPaused ? Color.orange : Color.red)
                    .frame(width: 56, height: 56)
                Image(systemName: recording.isPaused ? "pause.fill" : "waveform")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
            .onAppear { pulse = true }

            VStack(spacing: 4) {
                Text(recording.elapsed.clockString)
                    .font(.system(size: 44, weight: .semibold).monospacedDigit())
                Text(recording.isPaused ? "Paused" : (activeDocument?.title ?? "Recording…"))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                if recordsMic {
                    LevelMeter(label: "Microphone (You)", icon: "mic.fill", level: recording.micLevel)
                }
                if recordsSystem {
                    LevelMeter(label: "System Audio (Them)", icon: "macbook.and.wave.form", level: recording.systemLevel)
                }
            }
            .frame(maxWidth: 380)

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

            Text("Audio is saved to disk continuously — even a crash can't lose it.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
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
