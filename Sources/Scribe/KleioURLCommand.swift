import AppKit

/// A command carried by a `kleio://` URL, so other apps and launchers can drive recording without the UI.
enum KleioURLCommand: Equatable {
    case startRecording(RecordingMode)
    case stopRecording
    case toggleRecording(RecordingMode)
    case toggleDictation
    case open

    static let scheme = "kleio"

    /// Accepted shapes:
    /// `kleio://record/start?mode=meeting|system|mic`, `kleio://record/stop`,
    /// `kleio://record/toggle?mode=…`, `kleio://dictation/toggle`, `kleio://open`.
    static func parse(_ url: URL) -> KleioURLCommand? {
        guard url.scheme?.lowercased() == scheme, let host = url.host?.lowercased() else { return nil }
        let action = url.pathComponents.dropFirst().first?.lowercased()
        // An absent mode means meeting; a misspelt one must not start the wrong recording.
        guard let mode = recordingMode(from: url) else { return nil }
        switch (host, action) {
        case ("record", "start"): return .startRecording(mode)
        case ("record", "stop"): return .stopRecording
        case ("record", "toggle"): return .toggleRecording(mode)
        case ("dictation", "toggle"): return .toggleDictation
        case ("open", nil): return .open
        default: return nil
        }
    }

    private static func recordingMode(from url: URL) -> RecordingMode? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let raw = items.first(where: { $0.name == "mode" })?.value?.lowercased() else { return .meeting }
        switch raw {
        case "meeting": return .meeting
        case "system", "systemonly": return .systemOnly
        case "mic", "microphone", "microphoneonly": return .microphoneOnly
        default: return nil
        }
    }
}

@MainActor
struct KleioURLCommandHandler {
    let recording: RecordingSession
    let library: LibraryStore
    let queue: TranscriptionQueue
    let dictation: DictationController
    let appState: AppState

    func handle(_ command: KleioURLCommand) {
        switch command {
        case .startRecording(let mode):
            start(mode)
        case .stopRecording:
            stop()
        case .toggleRecording(let mode):
            if recording.isRecording { stop() } else { start(mode) }
        case .toggleDictation:
            dictation.toggle()
        case .open:
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func start(_ mode: RecordingMode) {
        // Busy covers starting, finishing, and a pending save; a second start would be dropped anyway.
        guard !recording.isBusy else { return }
        Task {
            await recording.startUsingPreferences(mode: mode, library: library)
            if let id = recording.activeDocumentID { appState.select(document: id) }
        }
    }

    private func stop() {
        guard recording.isRecording, !recording.isStarting else { return }
        recording.stop(library: library, queue: queue)
    }
}
