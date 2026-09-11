import SwiftUI
import AppKit

/// A failed job keeps its recording context and offers actions for the audio
/// actually on disk. Technical errors stay available in a disclosure.
struct RecordingProblemView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var queue: TranscriptionQueue
    @EnvironmentObject private var recording: RecordingSession
    @EnvironmentObject private var appState: AppState
    let document: ScribeDocument
    let onViewTranscript: () -> Void

    @State private var availability: RecordingAudioAvailability?
    @State private var checking = false
    @State private var showDetails = false

    private var saving: Bool {
        recording.activeDocumentID == document.id || library.hasPendingRecordingSave(document.id)
    }

    private var title: String {
        guard let availability else { return "Checking your recording" }
        if availability.unavailable.count == 1, let item = availability.unavailable.first {
            switch item.state {
            case .empty: return "\(item.name) is empty"
            case .missing: return "\(item.name) couldn't be found"
            case .unreadable: return "\(item.name) couldn't be opened"
            case .available: break
            }
        }
        if availability.availableTracks.isEmpty { return "No audio is available" }
        if !availability.unavailable.isEmpty { return "Some audio isn't available" }
        return document.status == .recovered ? "Your saved audio is available" : "Transcription couldn't finish"
    }

    private var explanation: String {
        guard let availability else { return "Checking the audio saved with this recording." }
        if availability.availableTracks.isEmpty {
            return "Check the recording files or restore them from a backup, then check again."
        }
        if !availability.unavailable.isEmpty {
            if availability.availableTracks.count == 1, availability.availableTracks[0].source == .microphone {
                return "Your microphone audio is available. You can transcribe your side of the conversation, or restore the app audio and check again."
            }
            return "You can transcribe the available audio, or restore the unavailable files and check again."
        }
        return document.status == .recovered
            ? "The saved audio is available to transcribe. The original files will be kept."
            : "Your audio is available. Retry transcription, or open the details to see what stopped it."
    }

    private var transcribeLabel: String {
        guard let availability, !availability.unavailable.isEmpty else {
            return document.status == .recovered ? "Transcribe recording" : "Retry transcription"
        }
        if availability.availableTracks.count == 1 {
            switch availability.availableTracks[0].source {
            case .microphone: return "Transcribe microphone only"
            case .system: return "Transcribe app audio only"
            case .imported: break
            }
        }
        return "Transcribe available audio"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Button {
                        appState.selection = .home
                    } label: {
                        Label("Recordings", systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    Text(document.title)
                        .font(.system(size: 24, weight: .semibold))
                        .textSelection(.enabled)
                    Text("\(document.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(document.duration.clockString)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "waveform.badge.exclamationmark")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.orange)
                            .frame(width: 48, height: 48)
                            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(title)
                                .font(.system(size: 20, weight: .semibold))
                            Text(explanation)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let availability {
                        VStack(spacing: 0) {
                            ForEach(Array(availability.items.enumerated()), id: \.offset) { index, item in
                                HStack(spacing: 10) {
                                    Image(systemName: item.track.source == .microphone ? "mic" : "speaker.wave.2")
                                        .frame(width: 20)
                                        .foregroundStyle(.secondary)
                                    Text(item.name)
                                    Spacer()
                                    Label(item.state.label, systemImage: item.state == .available ? "checkmark.circle" : "exclamationmark.circle")
                                        .font(.callout)
                                        .foregroundStyle(item.state == .available ? Color.secondary : .orange)
                                }
                                .padding(.vertical, 12)
                                if index + 1 < availability.items.count { Divider() }
                            }
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 10) { recoveryActions(availability) }
                                VStack(alignment: .leading, spacing: 10) { recoveryActions(availability) }
                            }
                            if !availability.unavailable.isEmpty, !availability.availableTracks.isEmpty {
                                Text("A partial transcript will include only the available sources.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if !document.segments.isEmpty {
                                Text("Re-transcribing will replace the current transcript. You can view the saved version before continuing.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if saving {
                                Text("Finish saving this recording before transcribing it.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        ProgressView("Checking saved audio…")
                            .controlSize(.small)
                    }

                    Divider()
                    DisclosureGroup("Technical details", isExpanded: $showDetails) {
                        VStack(alignment: .leading, spacing: 10) {
                            if let reason = document.failureReason {
                                Text(reason)
                            }
                            if let availability {
                                ForEach(Array(availability.items.enumerated()), id: \.offset) { _, item in
                                    Text("\(item.track.fileName): \(item.state.label)")
                                }
                            }
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 10)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .padding(24)
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: 20))
                .overlay {
                    RoundedRectangle(cornerRadius: 20).strokeBorder(Color.primary.opacity(0.05))
                }

                if !document.segments.isEmpty {
                    Button(action: onViewTranscript) {
                        Label("View saved transcript", systemImage: "doc.text")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paperBackground)
        .task(id: document.tracks) { await checkAudio() }
    }

    @ViewBuilder
    private func recoveryActions(_ availability: RecordingAudioAvailability) -> some View {
        if !availability.availableTracks.isEmpty {
            Button(transcribeLabel) {
                queue.enqueue(document.id, allowPartialAudio: !availability.unavailable.isEmpty)
            }
            .buttonStyle(.borderedProminent)
            .disabled(saving || checking)
        }
        Button("Show audio files") {
            NSWorkspace.shared.activateFileViewerSelecting([library.folder(for: document.id)])
        }
        .buttonStyle(.bordered)
        if !availability.unavailable.isEmpty || availability.items.isEmpty {
            Button(checking ? "Checking…" : "Check again") {
                Task { await checkAudio() }
            }
            .buttonStyle(.borderless)
            .disabled(checking)
        }
    }

    @MainActor
    private func checkAudio() async {
        checking = true
        defer { checking = false }
        let folder = library.folder(for: document.id)
        let snapshot = document
        let result = await Task.detached(priority: .userInitiated) {
            RecordingAudioAvailability.inspect(snapshot, folder: folder)
        }.value
        guard !Task.isCancelled else { return }
        availability = result
    }
}
