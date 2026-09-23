import AppKit
import Foundation
@preconcurrency import UserNotifications

struct AutoRecordEvent: Equatable, Identifiable, Sendable {
    let eventID: String
    let title: String
    let start: Date
    let end: Date
    let joinURL: URL?

    var id: String { "\(eventID)-\(Int(start.timeIntervalSince1970))" }
}

enum AutoRecordStopReason: Equatable {
    case manual
    case scheduledEnd
    case silence
    case processQuit
    case cancelled
    case disabled
    case switchMeeting
}

enum AutoRecordPhase: Equatable {
    case idle
    case armed(AutoRecordEvent)
    case confirming(AutoRecordEvent)
    case countdown(AutoRecordEvent, deadline: Date)
    case recording(AutoRecordEvent)
    case stopping(AutoRecordEvent)

    var event: AutoRecordEvent? {
        switch self {
        case .idle: return nil
        case .armed(let event), .confirming(let event), .recording(let event), .stopping(let event):
            return event
        case .countdown(let event, _):
            return event
        }
    }
}

struct AutoRecordConfiguration: Equatable {
    var enabled = false
    var leadMinutes = 2
    var lateJoinMinutes = 15
    var graceMinutes = 5
    var silenceMinutes = 3
    var confirmationSeconds: TimeInterval = 3
    var countdownSeconds: TimeInterval = 10
}

enum AutoRecordCommand: Equatable {
    case startMetering
    case stopMetering
    case postCountdown(AutoRecordEvent)
    case startRecording(AutoRecordEvent)
    case stopRecording(AutoRecordStopReason)
    case postOverlap(active: AutoRecordEvent, waiting: AutoRecordEvent)
}

enum ManualAutoStopCommand: Equatable {
    case stopRecording
}

struct ManualAutoStopCore {
    private var silenceSince: Date?
    private var pausedAt: Date?
    private var didRequestStop = false

    mutating func update(
        now: Date,
        enabled: Bool,
        recording: ActiveRecording?,
        isPaused: Bool,
        elapsed: TimeInterval,
        conferencingProcessBundleIDs: Set<String>,
        systemAudioActive: Bool,
        micAudioActive: Bool,
        silenceMinutes: Int
    ) -> [ManualAutoStopCommand] {
        // Auto-record stops the recordings it started. Every other meeting recording,
        // including Join & Record, follows these rules.
        guard enabled, let recording, recording.mode == .meeting, recording.origin == .manual else {
            reset()
            return []
        }

        if isPaused {
            if pausedAt == nil { pausedAt = now }
            return []
        }
        if let pausedAt {
            if let silenceSince {
                self.silenceSince = silenceSince.addingTimeInterval(now.timeIntervalSince(pausedAt))
            }
            self.pausedAt = nil
        }

        if !systemAudioActive && !micAudioActive {
            if silenceSince == nil { silenceSince = now }
        } else {
            silenceSince = nil
        }

        guard elapsed >= 2 * 60, !didRequestStop else { return [] }

        // Only the recorded app quitting ends the call. A browser or all-Mac-audio
        // recording has no app that quits with the call, so it relies on silence.
        if let bundleID = recording.application?.bundleID,
           AudioProcessMonitor.isCallApp(bundleID),
           !conferencingProcessBundleIDs.contains(bundleID) {
            didRequestStop = true
            return [.stopRecording]
        }

        if let silenceSince,
           now.timeIntervalSince(silenceSince) >= TimeInterval(silenceMinutes * 60) {
            didRequestStop = true
            return [.stopRecording]
        }
        return []
    }

    private mutating func reset() {
        silenceSince = nil
        pausedAt = nil
        didRequestStop = false
    }
}

struct AutoRecordArbiterCore {
    private(set) var phase: AutoRecordPhase = .idle
    private(set) var lastStopReason: AutoRecordStopReason?
    private var audioEvidenceSince: Date?
    private var silenceSince: Date?
    private var cancelledEventIDs: Set<String> = []
    private var overlapNotificationIDs: Set<String> = []
    private var pendingSwitch: AutoRecordEvent?

    mutating func update(
        now: Date,
        meetings: [AutoRecordEvent],
        configuration: AutoRecordConfiguration,
        processRunning: Bool,
        systemAudioActive: Bool,
        micAudioActive: Bool,
        recordingActive: Bool,
        startBlocked: Bool
    ) -> [AutoRecordCommand] {
        guard configuration.enabled else {
            return disableCurrentState(recordingActive: recordingActive)
        }

        switch phase {
        case .idle:
            if let pendingSwitch {
                self.pendingSwitch = nil
                return beginCountdown(for: pendingSwitch, now: now, configuration: configuration)
            }
            guard let event = eligibleMeeting(at: now, meetings: meetings, configuration: configuration) else {
                return []
            }
            phase = .armed(event)
            return []

        case .armed(let event):
            guard isInsideArmedWindow(event, at: now, configuration: configuration) else {
                phase = .idle
                return []
            }
            guard processRunning else { return [] }
            phase = .confirming(event)
            audioEvidenceSince = systemAudioActive ? now : nil
            return [.startMetering]

        case .confirming(let event):
            guard isInsideArmedWindow(event, at: now, configuration: configuration), processRunning else {
                phase = isInsideArmedWindow(event, at: now, configuration: configuration) ? .armed(event) : .idle
                audioEvidenceSince = nil
                return [.stopMetering]
            }
            guard systemAudioActive else {
                audioEvidenceSince = nil
                return []
            }
            if audioEvidenceSince == nil { audioEvidenceSince = now }
            guard now.timeIntervalSince(audioEvidenceSince!) >= configuration.confirmationSeconds else { return [] }
            audioEvidenceSince = nil
            return [.stopMetering] + beginCountdown(for: event, now: now, configuration: configuration)

        case .countdown(let event, let deadline):
            guard processRunning else {
                phase = .idle
                return []
            }
            guard now >= deadline else { return [] }
            // Dictation or a backup holds the countdown open. Give up only once the meeting is over.
            if startBlocked {
                if now > event.end {
                    cancelledEventIDs.insert(event.eventID)
                    phase = .idle
                }
                return []
            }
            phase = .recording(event)
            silenceSince = nil
            return [.startRecording(event)]

        case .recording(let event):
            guard recordingActive else {
                lastStopReason = .manual
                phase = .stopping(event)
                silenceSince = nil
                return []
            }
            if !processRunning {
                return stop(event, reason: .processQuit)
            }

            let quiet = !systemAudioActive && !micAudioActive
            if quiet {
                if silenceSince == nil { silenceSince = now }
            } else {
                silenceSince = nil
            }

            if now >= event.end.addingTimeInterval(TimeInterval(configuration.graceMinutes * 60)), quiet {
                return stop(event, reason: .scheduledEnd)
            }
            if let silenceSince,
               now.timeIntervalSince(silenceSince) >= TimeInterval(configuration.silenceMinutes * 60) {
                return stop(event, reason: .silence)
            }

            if let overlap = eligibleMeeting(at: now, meetings: meetings, configuration: configuration, excluding: event.eventID),
               overlapNotificationIDs.insert(overlap.id).inserted {
                return [.postOverlap(active: event, waiting: overlap)]
            }
            return []

        case .stopping:
            guard !recordingActive else { return [] }
            phase = .idle
            if let pendingSwitch {
                self.pendingSwitch = nil
                return beginCountdown(for: pendingSwitch, now: now, configuration: configuration)
            }
            return []
        }
    }

    mutating func cancel(eventID: String? = nil) -> [AutoRecordCommand] {
        if let eventID { cancelledEventIDs.insert(eventID) }
        guard let event = phase.event,
              eventID == nil || event.eventID == eventID else { return [] }
        cancelledEventIDs.insert(event.eventID)
        audioEvidenceSince = nil
        silenceSince = nil
        pendingSwitch = nil
        switch phase {
        case .recording, .stopping:
            return stop(event, reason: .cancelled)
        case .confirming:
            phase = .idle
            return [.stopMetering]
        default:
            phase = .idle
            return []
        }
    }

    mutating func startNow() -> [AutoRecordCommand] {
        guard case .countdown(let event, _) = phase else { return [] }
        phase = .recording(event)
        silenceSince = nil
        return [.startRecording(event)]
    }

    mutating func recordingStartFailed() {
        guard case .recording(let event) = phase else { return }
        cancelledEventIDs.insert(event.eventID)
        phase = .idle
        silenceSince = nil
    }

    mutating func stopAndSwitch(to event: AutoRecordEvent) -> [AutoRecordCommand] {
        guard case .recording(let current) = phase else { return [] }
        pendingSwitch = event
        return stop(current, reason: .switchMeeting)
    }

    private mutating func beginCountdown(
        for event: AutoRecordEvent,
        now: Date,
        configuration: AutoRecordConfiguration
    ) -> [AutoRecordCommand] {
        phase = .countdown(event, deadline: now.addingTimeInterval(configuration.countdownSeconds))
        return [.postCountdown(event)]
    }

    private mutating func stop(_ event: AutoRecordEvent, reason: AutoRecordStopReason) -> [AutoRecordCommand] {
        lastStopReason = reason
        phase = .stopping(event)
        silenceSince = nil
        return [.stopRecording(reason)]
    }

    private mutating func disableCurrentState(recordingActive: Bool) -> [AutoRecordCommand] {
        guard let event = phase.event else { return [] }
        audioEvidenceSince = nil
        silenceSince = nil
        pendingSwitch = nil
        switch phase {
        case .recording:
            return stop(event, reason: .disabled)
        case .stopping:
            if recordingActive { return [.stopRecording(.disabled)] }
            phase = .idle
            return []
        case .confirming:
            phase = .idle
            return [.stopMetering]
        default:
            phase = .idle
            return []
        }
    }

    private func eligibleMeeting(
        at now: Date,
        meetings: [AutoRecordEvent],
        configuration: AutoRecordConfiguration,
        excluding eventID: String? = nil
    ) -> AutoRecordEvent? {
        meetings
            .filter {
                $0.eventID != eventID &&
                !cancelledEventIDs.contains($0.eventID) &&
                isInsideArmedWindow($0, at: now, configuration: configuration)
            }
            .sorted { $0.start < $1.start }
            .first
    }

    private func isInsideArmedWindow(
        _ event: AutoRecordEvent,
        at now: Date,
        configuration: AutoRecordConfiguration
    ) -> Bool {
        let armDate = event.start.addingTimeInterval(-TimeInterval(configuration.leadMinutes * 60))
        let expiry = event.start.addingTimeInterval(TimeInterval(configuration.lateJoinMinutes * 60))
        return now >= armDate && now <= expiry
    }
}

@MainActor
final class AutoRecordArbiter: ObservableObject {
    nonisolated static let countdownCategoryIdentifier = "AUTO_RECORD"
    nonisolated static let overlapCategoryIdentifier = "AUTO_RECORD_OVERLAP"
    nonisolated static let cancelActionIdentifier = "AUTO_RECORD_CANCEL"
    nonisolated static let startNowActionIdentifier = "AUTO_RECORD_START_NOW"
    nonisolated static let stopAndSwitchActionIdentifier = "AUTO_RECORD_STOP_AND_SWITCH"
    nonisolated static let keepCurrentActionIdentifier = "AUTO_RECORD_KEEP_CURRENT"

    @Published private(set) var phase: AutoRecordPhase = .idle
    @Published private(set) var lastProblem: String?
    nonisolated private static let audioLevelThreshold: Float = 0.04

    private var core = AutoRecordArbiterCore()
    private var manualAutoStopCore = ManualAutoStopCore()
    private let processMonitor = AudioProcessMonitor()
    private weak var calendarSync: CalendarSync?
    private weak var recording: RecordingSession?
    private weak var library: LibraryStore?
    private weak var queue: TranscriptionQueue?
    private var timer: Timer?
    private var systemAudioActive = false
    private var notifiedPermissionFailure = false
    private var isConfigured = false
    private var startInProgress = false
    private var startBlocked: () -> Bool = { true }
    private var loggedStartWait = false

    func configure(
        calendarSync: CalendarSync,
        recording: RecordingSession,
        library: LibraryStore,
        queue: TranscriptionQueue,
        startBlocked: @escaping () -> Bool
    ) {
        guard !isConfigured else { return }
        isConfigured = true
        self.startBlocked = startBlocked
        self.calendarSync = calendarSync
        self.recording = recording
        self.library = library
        self.queue = queue
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        tick()
    }

    func handleNotificationAction(identifier: String, userInfo: [AnyHashable: Any]) {
        switch identifier {
        case Self.cancelActionIdentifier:
            run(core.cancel(eventID: userInfo["eventID"] as? String))
        case Self.startNowActionIdentifier:
            // A blocked start keeps its countdown; the first unblocked tick starts it.
            guard !startBlocked() else { break }
            run(core.startNow())
        case Self.stopAndSwitchActionIdentifier:
            guard let eventID = userInfo["eventID"] as? String,
                  let event = calendarSync?.autoRecordMeetings(at: Date()).first(where: { $0.eventID == eventID }) else { return }
            run(core.stopAndSwitch(to: event))
        default:
            break
        }
        phase = core.phase
    }

    private func tick() {
        guard let calendarSync, let recording else { return }
        guard !startInProgress else { return }
        let now = Date()
        if calendarSync.autoRecordEnabled && calendarSync.autoRecordProblem == nil {
            notifiedPermissionFailure = false
        }
        if calendarSync.autoRecordEnabled && calendarSync.authorizationStatus != .fullAccess {
            notifyPermissionFailureOnce("Calendar access is unavailable. Auto-record has stopped.")
        }
        let currentEvent = core.phase.event
        let processRunning = currentEvent.map(processMonitor.hasConferencingProcess) ?? false
        let activeRecording = recording.isRecording ? recording.activeRecording : nil
        let recordingSystemActive = recording.systemLevel > Self.audioLevelThreshold
        let recordingMicActive = recording.micLevel > Self.audioLevelThreshold
        let startBlocked = startBlocked()
        let commands = core.update(
            now: now,
            meetings: calendarSync.autoRecordMeetings(at: now),
            configuration: calendarSync.autoRecordConfiguration,
            processRunning: processRunning,
            systemAudioActive: systemAudioActive || recordingSystemActive,
            micAudioActive: recordingMicActive,
            recordingActive: activeRecording?.origin == .autoRecord,
            startBlocked: startBlocked
        )
        let manualCommands = manualAutoStopCore.update(
            now: now,
            enabled: UserDefaults.standard.bool(forKey: "manualAutoStopEnabled"),
            recording: activeRecording,
            isPaused: recording.isPaused,
            elapsed: recording.elapsed,
            conferencingProcessBundleIDs: processMonitor.runningCallAppBundleIDs(),
            systemAudioActive: recordingSystemActive,
            micAudioActive: recordingMicActive,
            silenceMinutes: calendarSync.autoRecordSilenceMinutes
        )
        if startBlocked, case .countdown(let event, let deadline) = core.phase, now >= deadline {
            if !loggedStartWait {
                loggedStartWait = true
                DiagLog.log("auto-record waiting to start %@ until dictation or a backup finishes", event.eventID)
            }
        } else {
            loggedStartWait = false
        }
        phase = core.phase
        run(commands)
        run(manualCommands)
    }

    private func run(_ commands: [AutoRecordCommand]) {
        for command in commands {
            switch command {
            case .startMetering:
                do {
                    try processMonitor.startMetering { [weak self] level in
                        Task { @MainActor in self?.systemAudioActive = level > Self.audioLevelThreshold }
                    }
                } catch {
                    lastProblem = error.localizedDescription
                    notifyPermissionFailureOnce("System audio access is unavailable. Auto-record has stopped.")
                    run(core.cancel())
                }
            case .stopMetering:
                processMonitor.stopMetering()
                systemAudioActive = false
            case .postCountdown(let event):
                postCountdown(for: event)
            case .startRecording(let event):
                startRecording(for: event)
            case .stopRecording:
                guard let recording, let library, let queue, recording.isRecording,
                      recording.activeRecording?.origin == .autoRecord else { continue }
                recording.stop(library: library, queue: queue)
            case .postOverlap(let active, let waiting):
                postOverlap(active: active, waiting: waiting)
            }
        }
        phase = core.phase
    }

    private func run(_ commands: [ManualAutoStopCommand]) {
        for command in commands {
            switch command {
            case .stopRecording:
                guard let recording, let library, let queue, recording.isRecording else { continue }
                recording.stop(library: library, queue: queue)
                postManualAutoStopNotification()
            }
        }
    }

    private func startRecording(for event: AutoRecordEvent) {
        guard let recording, let library else { return }
        guard !recording.isRecording else {
            DiagLog.log("auto-record skipped %@ because another recording is active", event.eventID)
            core.recordingStartFailed()
            phase = core.phase
            return
        }
        startInProgress = true
        Task {
            await recording.startAutoRecording(
                for: event,
                library: library,
                storeCalendarDetails: calendarSync?.storesAutoRecordEventDetails ?? true
            )
            startInProgress = false
            if !recording.isRecording {
                if let error = recording.lastError {
                    lastProblem = error
                    if error == RecordingSession.insufficientDiskMessage {
                        postProblem(error, eventID: event.eventID)
                    } else {
                        notifyPermissionFailureOnce(error)
                    }
                }
                core.recordingStartFailed()
                phase = core.phase
            }
            tick()
        }
    }

    private var isBundledApp: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    private func postCountdown(for event: AutoRecordEvent) {
        guard isBundledApp else { return }
        let content = UNMutableNotificationContent()
        content.title = "Auto-record"
        content.body = "Recording \(event.title) in 10 seconds"
        content.sound = .default
        content.categoryIdentifier = Self.countdownCategoryIdentifier
        content.userInfo = ["eventID": event.eventID]
        let request = UNNotificationRequest(
            identifier: "auto-record-countdown-\(event.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func postOverlap(active: AutoRecordEvent, waiting: AutoRecordEvent) {
        guard isBundledApp else { return }
        let content = UNMutableNotificationContent()
        content.title = "Another meeting is ready"
        content.body = "Kleio is recording \(active.title). Stop it and switch to \(waiting.title)?"
        content.sound = .default
        content.categoryIdentifier = Self.overlapCategoryIdentifier
        content.userInfo = ["eventID": waiting.eventID]
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "auto-record-overlap-\(waiting.id)",
            content: content,
            trigger: nil
        ))
    }

    private func notifyPermissionFailureOnce(_ message: String) {
        calendarSync?.suspendAutoRecord(with: message)
        guard !notifiedPermissionFailure else { return }
        notifiedPermissionFailure = true
        lastProblem = message
        postProblem(message, eventID: "permission")
    }

    private func postProblem(_ message: String, eventID: String) {
        guard isBundledApp else { return }
        let content = UNMutableNotificationContent()
        content.title = "Auto-record stopped"
        content.body = message
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "auto-record-problem-\(eventID)",
            content: content,
            trigger: nil
        ))
    }

    private func postManualAutoStopNotification() {
        guard isBundledApp else { return }
        let content = UNMutableNotificationContent()
        content.title = "Recording stopped"
        content.body = "The call ended."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "manual-auto-stop-\(UUID().uuidString)",
            content: content,
            trigger: nil
        ))
    }

    @objc private func workspaceDidWake() {
        calendarSync?.refresh()
        tick()
    }
}
