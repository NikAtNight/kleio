import Foundation

extension MeetingMuteObservation {
    func effectiveState(at time: TimeInterval) -> MeetingMuteState {
        let readStart = readStartedAt ?? observedAt
        guard time.isFinite, observedAt.isFinite, readStart.isFinite, readStart <= observedAt,
              time >= observedAt, time - readStart <= MeetingMicrophoneGate.maximumObservationGap else {
            return .unavailable("The meeting microphone state is no longer available.")
        }
        if state == .unmuted, contextID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return .unavailable("The meeting could not be identified.")
        }
        return state
    }
}

/// Serializes native Accessibility reads away from capture and the main actor.
/// Stopping invalidates an in-flight read before it can authorize more audio.
final class MeetingMuteMonitor: @unchecked Sendable {
    private let application: RecordingApplication
    private let reader: any MeetingMuteReading
    private let gate: MeetingMicrophoneGate
    private let onUpdate: @Sendable (MeetingMuteObservation) -> Void
    private let queue = DispatchQueue(label: "Kleio.MeetingMute", qos: .userInitiated)
    private let lock = NSLock()
    private var active = true
    private var timer: DispatchSourceTimer?

    init(application: RecordingApplication, reader: any MeetingMuteReading = MeetingMuteReader(),
         gate: MeetingMicrophoneGate, onUpdate: @escaping @Sendable (MeetingMuteObservation) -> Void) {
        self.application = application
        self.reader = reader
        self.gate = gate
        self.onUpdate = onUpdate
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard active, timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.2, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.poll() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        active = false
        timer?.cancel()
        timer = nil
    }

    // Called on the serial queue in production, directly with fake readers in tests.
    func poll() {
        lock.lock()
        let shouldRead = active
        lock.unlock()
        guard shouldRead else { return }
        let observation = reader.read(application: application)
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        gate.record(state: observation.state, contextID: observation.contextID, at: observation.observedAt,
                    readStartedAt: observation.readStartedAt)
        onUpdate(observation)
    }

    deinit { timer?.cancel() }
}
