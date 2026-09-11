import AVFoundation
import XCTest
@testable import Scribe

final class MeetingMuteMonitorTests: XCTestCase {
    func testNativeObservationsControlSavedSamplesAndStopPreventsFurtherReads() {
        var time: TimeInterval = 100
        let gate = MeetingMicrophoneGate(now: { time })
        let reader = FakeMuteReader()
        let updates = ObservationStore()
        let monitor = MeetingMuteMonitor(application: .init(bundleID: "test", name: "Meeting"),
                                        reader: reader, gate: gate, onUpdate: { updates.append($0) })
        monitor.poll()
        time = 100.2
        reader.observation.observedAt = time
        monitor.poll()
        time = 100.4
        reader.observation = .init(state: .muted, contextID: "call", sourceName: "Meeting", observedAt: time)
        monitor.poll()

        let format = AVAudioFormat(standardFormatWithSampleRate: 1000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 400)!
        buffer.frameLength = 400
        buffer.floatChannelData![0].update(repeating: 0.8, count: 400)
        _ = gate.enqueue(buffer, hostTime: 100, at: time)
        let result = gate.drain(at: time, finishing: true)[0].buffer
        XCTAssertEqual(result.floatChannelData![0][100], 0.8)
        XCTAssertEqual(result.floatChannelData![0][300], 0)
        XCTAssertEqual(updates.values.map(\.state), [.unmuted, .unmuted, .muted])
        monitor.stop()
        monitor.poll()
        XCTAssertEqual(reader.readCount, 3)
    }

    func testStopDuringReadDiscardsLateUnmutedResult() {
        let reader = FakeMuteReader()
        let gate = MeetingMicrophoneGate(now: { 100 })
        let updates = ObservationStore()
        let monitor = MeetingMuteMonitor(application: .init(bundleID: "test", name: "Meeting"),
                                        reader: reader, gate: gate, onUpdate: { updates.append($0) })
        reader.duringRead = { monitor.stop() }
        monitor.poll()
        XCTAssertTrue(updates.values.isEmpty)
        XCTAssertFalse(gate.hasFreshUnmutedObservation(at: 100))
    }

    func testStatusExpiresAndRejectsMissingContextAndFutureTimes() {
        var observation = MeetingMuteObservation(state: .unmuted, contextID: "call", sourceName: "Meeting", observedAt: 100)
        XCTAssertEqual(observation.effectiveState(at: 100.4), .unmuted)
        for time in [99, 100.6, .infinity, .nan] {
            guard case .unavailable = observation.effectiveState(at: time) else {
                return XCTFail("An invalid or stale observation showed an open microphone.")
            }
        }
        observation.readStartedAt = 99.7
        guard case .unavailable = observation.effectiveState(at: 100.3) else {
            return XCTFail("Staleness must include the native control read duration.")
        }
        observation.readStartedAt = nil
        observation.contextID = nil
        guard case .unavailable = observation.effectiveState(at: 100.1) else {
            return XCTFail("An unidentified call showed an open microphone.")
        }
    }
}

private final class FakeMuteReader: MeetingMuteReading {
    var observation = MeetingMuteObservation(state: .unmuted, contextID: "call", sourceName: "Meeting", observedAt: 100)
    var readCount = 0
    var duringRead: (() -> Void)?
    func read(application: RecordingApplication) -> MeetingMuteObservation {
        readCount += 1
        duringRead?()
        return observation
    }
}

private final class ObservationStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [MeetingMuteObservation] = []
    var values: [MeetingMuteObservation] { lock.lock(); defer { lock.unlock() }; return storage }
    func append(_ value: MeetingMuteObservation) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
}
