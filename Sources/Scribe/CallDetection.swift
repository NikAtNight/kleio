import AppKit
import ApplicationServices
import Combine

struct DetectedCall: Equatable {
    var application: RecordingApplication
    var contextID: String
    var name: String
}

struct CallDetectionSample {
    var application: RecordingApplication
    var presence: CallPresence
}

/// Confirms calls and remembers a dismissal until that call ends.
struct CallPromptCore {
    private struct State {
        var contextID: String?
        var confirmations = 0
        var lastActive: TimeInterval?
        var inactiveSince: TimeInterval?
    }
    private var states: [String: State] = [:]
    private var handledContexts: [String: [String]] = [:]

    mutating func update(_ samples: [CallDetectionSample], at now: TimeInterval,
                         recordingBusy: Bool, presentationBlocked: Bool) -> DetectedCall? {
        let running = Set(samples.map { $0.application.bundleID })
        states = states.filter { running.contains($0.key) }
        handledContexts = handledContexts.filter { running.contains($0.key) }
        var candidates: [DetectedCall] = []
        var activeCount = 0
        for sample in samples {
            let bundleID = sample.application.bundleID
            var state = states[bundleID] ?? State()
            switch sample.presence {
            case .active(let contextID, let name):
                activeCount += 1
                if state.contextID != contextID {
                    state = State(contextID: contextID)
                }
                let consecutive = state.lastActive.map { now >= $0 && now - $0 <= 6 } ?? false
                state.confirmations = consecutive ? state.confirmations + 1 : 1
                state.lastActive = now
                state.inactiveSince = nil
                if recordingBusy {
                    remember(contextID, for: bundleID)
                }
                if state.confirmations >= 2, handledContexts[bundleID]?.contains(contextID) != true {
                    candidates.append(DetectedCall(application: sample.application, contextID: contextID, name: name))
                }
            case .inactive:
                state.confirmations = 0
                state.lastActive = nil
                if state.inactiveSince == nil { state.inactiveSince = now }
                if now - (state.inactiveSince ?? now) >= 10 {
                    state = State()
                    handledContexts[bundleID] = nil
                }
            case .readyToJoin(let contextID):
                if state.contextID != contextID { state = State(contextID: contextID) }
                state.confirmations = 0
                state.lastActive = nil
                if state.inactiveSince == nil { state.inactiveSince = now }
                if now - (state.inactiveSince ?? now) >= 10 {
                    handledContexts[bundleID]?.removeAll { $0 == contextID }
                    state = State()
                }
            case .unknown:
                state.confirmations = 0
                state.lastActive = nil
                state.inactiveSince = nil
            }
            states[bundleID] = state
        }
        guard !recordingBusy, !presentationBlocked else { return nil }
        // Do not guess which call to record when several calls are visible.
        return activeCount == 1 && candidates.count == 1 ? candidates.first : nil
    }

    mutating func dismiss(_ call: DetectedCall) {
        guard states[call.application.bundleID]?.contextID == call.contextID else { return }
        remember(call.contextID, for: call.application.bundleID)
    }

    private mutating func remember(_ contextID: String, for bundleID: String) {
        var contexts = handledContexts[bundleID] ?? []
        contexts.removeAll { $0 == contextID }
        contexts.append(contextID)
        handledContexts[bundleID] = Array(contexts.suffix(128))
    }
}

/// Readers and their Accessibility caches are confined to one background queue.
private final class CallPresenceScanner: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Kleio.CallDetection", qos: .utility)
    private var readers: [String: MeetingMuteReader] = [:]

    func scan(_ applications: [RecordingApplication], debug: Bool) async -> [CallDetectionSample] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                let running = Set(applications.map(\.bundleID))
                readers = readers.filter { running.contains($0.key) }
                let samples = applications.map { app in
                    let reader = readers[app.bundleID] ?? MeetingMuteReader()
                    readers[app.bundleID] = reader
                    return CallDetectionSample(application: app, presence: reader.readCall(application: app, debug: debug))
                }
                continuation.resume(returning: samples)
            }
        }
    }

    /// Undoes accessibility changes made for detection. The next scan requests them again.
    /// Quitting waits so Teams isn't left with AXEnhancedUserInterface on.
    func release(waitUntilDone: Bool = false) {
        let work = { [self] in
            readers.values.forEach { $0.releaseAccessibility() }
            readers.removeAll()
        }
        guard waitUntilDone else { queue.async(execute: work); return }
        // Bounded so an unresponsive app can't hold up quitting.
        let done = DispatchSemaphore(value: 0)
        queue.async { work(); done.signal() }
        _ = done.wait(timeout: .now() + 0.5)
    }
}

@MainActor
final class CallDetectionController: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "callDetectionEnabled")
            if !enabled {
                hidePrompt()
                scanner.release()
            }
        }
    }
    @Published private(set) var accessibilityGranted = false
    /// Opt-in diagnostics: `defaults write app.talix.scribe callDetectionDebug -bool true`.
    var debugLogging: Bool { defaults.bool(forKey: "callDetectionDebug") }

    func releaseBeforeQuit() { scanner.release(waitUntilDone: true) }
    private let defaults: UserDefaults
    private let scanner = CallPresenceScanner()
    private var core = CallPromptCore()
    private var timer: Timer?
    private var scanning = false
    private var starting = false
    private var prompt: CallRecordingPrompt?
    private var visibleCall: DetectedCall?
    private var promptError: String?
    private var latestPresence: [String: CallPresence] = [:]
    private var latestPresenceTime: TimeInterval?
    private weak var recording: RecordingSession?
    private weak var library: LibraryStore?
    private var presentationBlocked: () -> Bool = { true }
    private var didStart: (UUID) -> Void = { _ in }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "callDetectionEnabled") as? Bool ?? true
    }

    func configure(recording: RecordingSession, library: LibraryStore,
                   presentationBlocked: @escaping () -> Bool, didStart: @escaping (UUID) -> Void) {
        guard timer == nil else { return }
        self.recording = recording
        self.library = library
        self.presentationBlocked = presentationBlocked
        self.didStart = didStart
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task { await poll() }
    }

    /// The latest call read for a running app. Nil when detection is off or hasn't read it recently.
    func presence(for bundleID: String) -> CallPresence? {
        guard let latestPresenceTime, RecordingClock.now - latestPresenceTime <= 6 else { return nil }
        return latestPresence[bundleID]
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    private func poll() async {
        accessibilityGranted = AXIsProcessTrusted()
        guard enabled, accessibilityGranted, !starting else { hidePrompt(); return }
        guard !scanning, let recording, let library else { return }
        scanning = true
        defer { scanning = false }
        let applications = RecordingApplication.runningApplications().filter {
            MeetingMuteReader.supportsCallDetection(bundleID: $0.bundleID)
        }
        let samples = await scanner.scan(applications, debug: debugLogging)
        guard enabled, AXIsProcessTrusted(), !starting else { hidePrompt(); return }
        latestPresence = Dictionary(samples.map { ($0.application.bundleID, $0.presence) },
                                    uniquingKeysWith: { first, _ in first })
        latestPresenceTime = RecordingClock.now
        let call = core.update(samples, at: RecordingClock.now,
                               recordingBusy: recording.isBusy || library.hasPendingRecordingSaves,
                               presentationBlocked: presentationBlocked())
        guard let call else { hidePrompt(); return }
        showPrompt(for: call)
    }

    private func showPrompt(for call: DetectedCall, error: String? = nil) {
        if visibleCall != call { promptError = error }
        visibleCall = call
        if prompt == nil { prompt = CallRecordingPrompt() }
        prompt?.show(call: call, error: promptError, record: { [weak self] includeScreen in
            Task { @MainActor in await self?.start(call, includeScreen: includeScreen) }
        }, dismiss: { [weak self] in
            self?.core.dismiss(call)
            self?.hidePrompt()
        })
    }

    private func hidePrompt() {
        prompt?.hide()
        visibleCall = nil
    }

    private func start(_ call: DetectedCall, includeScreen: Bool) async {
        guard enabled, !starting, visibleCall == call,
              let recording, let library, !recording.isBusy,
              !library.hasPendingRecordingSaves, !presentationBlocked() else { hidePrompt(); return }
        starting = true
        hidePrompt()
        defer { starting = false }
        // Recheck after the click so a stale popup cannot start an unrelated recording.
        let applications = RecordingApplication.runningApplications().filter {
            MeetingMuteReader.supportsCallDetection(bundleID: $0.bundleID)
        }
        let samples = await scanner.scan(applications, debug: false)
        guard enabled, !recording.isBusy, !presentationBlocked(),
              case .active(let contextID, _) = samples.first(where: { $0.application == call.application })?.presence,
              contextID == call.contextID else { return }
        await recording.startUsingPreferences(mode: .meeting, library: library,
                                               shortcut: call.application,
                                               videoMode: includeScreen ? .display : nil)
        if recording.isRecording, let id = recording.activeDocumentID {
            core.dismiss(call)
            didStart(id)
        } else if enabled, !recording.isBusy, !presentationBlocked() {
            // Picker cancellation and permission failures leave a visible retry path.
            showPrompt(for: call, error: recording.lastError)
        }
    }

    deinit { timer?.invalidate() }
}
