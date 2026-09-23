import AppKit
import ApplicationServices
import Carbon
import Foundation
import SwiftUI

/// Local, system-wide press-to-toggle dictation. Option-Space starts capture;
/// pressing it again transcribes with the selected Whisper model and pastes
/// into the app that was active when dictation began.
@MainActor
final class DictationController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        case recording
        case transcribing
    }

    @Published private(set) var phase: Phase = .idle {
        didSet { updateHUD(for: phase) }
    }
    @Published private(set) var level: Float = 0 {
        didSet {
            if phase == .recording {
                dictationHUD?.update(level: level)
            }
        }
    }
    @Published private(set) var lastMessage: String?
    @Published private(set) var enabled: Bool

    private weak var modelManager: ModelManager?
    private weak var replacements: ReplacementStore?
    private weak var recordingSession: RecordingSession?
    private var recorder: MicRecorder?
    private var recordingURL: URL?
    private var targetApplication: NSRunningApplication?
    private var dictationHUD: DictationHUD?
    private let transcriber = Transcriber()
    private lazy var hotKey = GlobalHotKey { [weak self] in
        Task { @MainActor in self?.toggle() }
    }

    init() {
        enabled = UserDefaults.standard.bool(forKey: "dictationEnabled")
    }

    var statusText: String {
        switch phase {
        case .idle: return lastMessage ?? "Ready. Press ⌥Space"
        case .preparing: return "Preparing microphone…"
        case .recording: return "Listening. Press ⌥Space to finish"
        case .transcribing: return "Transcribing dictation…"
        }
    }

    var isAccessibilityGranted: Bool { AXIsProcessTrusted() }

    func configure(
        modelManager: ModelManager,
        replacements: ReplacementStore,
        recordingSession: RecordingSession
    ) {
        self.modelManager = modelManager
        self.replacements = replacements
        self.recordingSession = recordingSession
        if enabled && !hotKey.register() {
            lastMessage = "Could not register ⌥Space. Another app may already use it."
        }
    }

    func setEnabled(_ newValue: Bool, promptForAccessibility: Bool = false) {
        enabled = newValue
        UserDefaults.standard.set(newValue, forKey: "dictationEnabled")
        if newValue {
            if promptForAccessibility { requestAccessibility() }
            if !hotKey.register() {
                lastMessage = "Could not register ⌥Space. Another app may already use it."
            } else {
                lastMessage = isAccessibilityGranted
                    ? "Dictation enabled"
                    : "Dictation enabled; results will copy until Accessibility is allowed"
            }
        } else {
            if phase == .recording { cancelRecording() }
            hotKey.unregister()
            lastMessage = nil
        }
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func toggle() {
        guard enabled else { return }
        switch phase {
        case .idle:
            startRecording()
        case .recording:
            finishRecording()
        case .preparing, .transcribing:
            break
        }
    }

    func cancelRecording() {
        recorder?.stop()
        recorder = nil
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        recordingURL = nil
        targetApplication = nil
        level = 0
        phase = .idle
        lastMessage = "Dictation cancelled"
    }

    /// Quit drops a take that's still listening and gives a running transcription
    /// time to finish and paste. After the timeout, quit goes ahead without it.
    func prepareToQuit(timeout: TimeInterval = 15) async {
        if phase == .preparing || phase == .recording { cancelRecording() }
        let deadline = Date().addingTimeInterval(timeout)
        while phase == .transcribing, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func startRecording() {
        guard recordingSession?.isBusy != true else {
            lastMessage = "Finish the active recording before starting dictation"
            return
        }
        phase = .preparing
        lastMessage = nil
        targetApplication = NSWorkspace.shared.frontmostApplication
        Task {
            guard await MicRecorder.requestPermission() else {
                phase = .idle
                lastMessage = MicRecorder.MicError.permissionDenied.localizedDescription
                return
            }
            guard phase == .preparing, recordingSession?.isBusy != true else {
                phase = .idle
                lastMessage = "Finish the active recording before starting dictation"
                return
            }
            do {
                let directory = ModelManager.downloadBase.appendingPathComponent("Dictation", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("dictation-\(UUID().uuidString).caf")
                let recorder = MicRecorder()
                try recorder.start(writingTo: url) { [weak self] level in
                    Task { @MainActor in self?.level = level }
                }
                self.recorder = recorder
                recordingURL = url
                phase = .recording
            } catch {
                phase = .idle
                lastMessage = error.localizedDescription
            }
        }
    }

    private func finishRecording() {
        guard let url = recordingURL, let modelManager else { return }
        recorder?.stop()
        recorder = nil
        level = 0
        phase = .transcribing

        let model = modelManager.selectedVariant
        let language = UserDefaults.standard.string(forKey: "language")
        Task {
            defer {
                try? FileManager.default.removeItem(at: url)
                recordingURL = nil
            }
            do {
                try await transcriber.load(model: model)
                let segments = try await transcriber.transcribe(
                    file: url,
                    source: .microphone,
                    language: language?.isEmpty == false ? language : nil,
                    translate: false
                )
                var text = segments.map(\.text).joined(separator: " ")
                if let replacements { text = replacements.apply(to: text) }
                guard !text.isEmpty else {
                    phase = .idle
                    lastMessage = "No speech detected"
                    return
                }
                let cleanedText = await cleanedIfEnabled(text)
                deliver(cleanedText.text, wasCleaned: cleanedText.wasCleaned)
            } catch {
                phase = .idle
                lastMessage = error.localizedDescription
            }
        }
    }

    private func cleanedIfEnabled(_ text: String) async -> (text: String, wasCleaned: Bool) {
        guard TranscriptCleaner.isEnabled else { return (text, false) }
        do {
            let cleaned = try await withTimeout(seconds: 3) {
                try await TranscriptCleaner().clean(text)
            }
            return (cleaned, cleaned != text)
        } catch {
            return (text, false)
        }
    }

    private func deliver(_ text: String, wasCleaned: Bool) {
        guard AXIsProcessTrusted() else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            phase = .idle
            lastMessage = wasCleaned
                ? "Cleaned up and copied to clipboard. Allow Accessibility to paste automatically"
                : "Copied to clipboard. Allow Accessibility to paste automatically"
            return
        }

        targetApplication?.activate()
        // Give the target app a beat to regain key focus before the synthetic
        // ⌘V lands, otherwise the paste can hit the wrong app.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            TextInjector.inject(text) { [weak self] landed in
                guard let self else { return }
                phase = .idle
                lastMessage = landed
                    ? (wasCleaned ? "Cleaned up and inserted" : "Inserted")
                    : "Could not paste dictation"
                targetApplication = nil
            }
        }
    }

    private func updateHUD(for phase: Phase) {
        guard NSApp != nil else { return }
        switch phase {
        case .idle:
            dictationHUD?.hide()
        case .preparing:
            if dictationHUD == nil { dictationHUD = DictationHUD() }
            dictationHUD?.show(.preparing)
        case .recording:
            dictationHUD?.setPhase(.recording)
        case .transcribing:
            dictationHUD?.setPhase(.transcribing)
        }
    }
}

private enum DictationCleanupTimeout: Error {
    case elapsed
}

private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            try Task.checkCancellation()
            throw DictationCleanupTimeout.elapsed
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw DictationCleanupTimeout.elapsed }
        return result
    }
}

/// Carbon hot keys remain the least intrusive way to reserve a global key
/// combination: unlike a global key monitor they don't require Input
/// Monitoring and they consume only the registered shortcut.
private final class GlobalHotKey {
    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(action: @escaping () -> Void) {
        self.action = action
    }

    @discardableResult
    func register() -> Bool {
        if hotKeyRef != nil { return true }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                let monitor = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { monitor.action() }
                return noErr
            },
            1,
            &eventType,
            pointer,
            &handlerRef
        )
        guard handlerStatus == noErr else { return false }

        let identifier = EventHotKeyID(signature: 0x53435242, id: 1) // SCRB
        let status = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            identifier,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status != noErr {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            handlerRef = nil
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }

    deinit {
        unregister()
    }
}
