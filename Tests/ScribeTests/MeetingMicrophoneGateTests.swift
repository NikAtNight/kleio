import AVFoundation
import XCTest
@testable import Scribe

final class MeetingMicrophoneGateTests: XCTestCase {
    private var time: TimeInterval = 100
    private lazy var gate = MeetingMicrophoneGate(now: { [unowned self] in self.time })

    func testWritesOnlyBetweenAdjacentUnmutedConfirmations() {
        observe(.unmuted, at: 100)
        _ = gate.enqueue(buffer(frames: 750), hostTime: 99.9, at: 100)
        observe(.unmuted, at: 100.25)
        observe(.muted, at: 100.5)
        let output = gate.drain(at: 100.6, finishing: true)
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output[0].hostTime, 99.9)
        let values = samples(output[0].buffer)
        XCTAssertTrue(values[0..<99].allSatisfy { $0 == 0 })
        XCTAssertTrue(values[102..<349].allSatisfy { $0 == 0.5 })
        XCTAssertTrue(values[350...].allSatisfy { $0 == 0 })
        XCTAssertEqual(gate.level(of: output[0].buffer, at: 100.6), 0)
    }

    func testQueuedBufferUsesItsCaptureTimeAndCopiesReusableInput() {
        observe(.unmuted, at: 100)
        observe(.unmuted, at: 100.25)
        observe(.muted, at: 100.5)
        let source = buffer(frames: 100)
        _ = gate.enqueue(source, hostTime: 100.05, at: 100.5)
        source.floatChannelData![0].update(repeating: 0.9, count: 100)
        let result = gate.drain(at: 101, finishing: true)
        XCTAssertEqual(result[0].hostTime, 100.05)
        XCTAssertTrue(samples(result[0].buffer).allSatisfy { $0 == 0.5 })
    }

    func testUnknownAndContextSwitchNeedANewPair() {
        observe(.unmuted, at: 100)
        observe(.unavailable("No control"), at: 100.1)
        observe(.unmuted, at: 100.2)
        observe(.unmuted, context: "other", at: 100.3)
        observe(.unmuted, context: "other", at: 100.4)
        _ = gate.enqueue(buffer(frames: 500), hostTime: 100, at: 100.5)
        let values = samples(gate.drain(at: 100.5, finishing: true)[0].buffer)
        XCTAssertTrue(values[0..<300].allSatisfy { $0 == 0 })
        XCTAssertTrue(values[302..<399].allSatisfy { $0 == 0.5 })
        XCTAssertTrue(values[400...].allSatisfy { $0 == 0 })
    }

    func testStaleFutureUnorderedAndInvalidObservationsFailClosed() {
        for invalid in [99.0, 101.0, 100.0, Double.nan, Double.infinity] {
            time = 100
            gate.reset()
            observe(.unmuted, at: 100)
            time = 100.25
            gate.record(state: .unmuted, contextID: "meeting", at: invalid)
            observe(.unmuted, at: 100.5)
            _ = gate.enqueue(buffer(frames: 500), hostTime: 100, at: 100.5)
            XCTAssertTrue(samples(gate.drain(at: 100.6, finishing: true)[0].buffer).allSatisfy { $0 == 0 })
        }
        time = 101
        gate.reset()
        observe(.unmuted, at: 101)
        observe(.unmuted, at: 101.51)
        _ = gate.enqueue(buffer(frames: 600), hostTime: 101, at: 101.6)
        XCTAssertTrue(samples(gate.drain(at: 101.6, finishing: true)[0].buffer).allSatisfy { $0 == 0 })
    }

    func testUnmutedWithoutContextCannotAuthorizeAudio() {
        for context: String? in [nil, "", " \n"] {
            time = 100
            gate.reset()
            observe(.unmuted, context: context, at: 100)
            observe(.unmuted, context: context, at: 100.25)
            _ = gate.enqueue(buffer(frames: 250), hostTime: 100, at: 100.25)
            XCTAssertTrue(samples(gate.drain(at: 100.3, finishing: true)[0].buffer).allSatisfy { $0 == 0 })
        }
    }

    func testStopZeroesUnconfirmedTailAndResetRejectsOldObservations() {
        observe(.unmuted, at: 100)
        observe(.unmuted, at: 100.25)
        _ = gate.enqueue(buffer(frames: 500), hostTime: 100, at: 100.5)
        let values = samples(gate.drain(at: 100.5, finishing: true)[0].buffer)
        XCTAssertTrue(values[0..<250].allSatisfy { $0 == 0.5 })
        XCTAssertTrue(values[250...].allSatisfy { $0 == 0 })
        time = 100.5
        gate.reset()
        gate.record(state: .unmuted, contextID: "meeting", at: 100.4)
        observe(.unmuted, at: 100.6)
        _ = gate.enqueue(buffer(frames: 500), hostTime: 100.25, at: 100.75)
        XCTAssertTrue(samples(gate.drain(at: 100.75, finishing: true)[0].buffer).allSatisfy { $0 == 0 })
        _ = gate.enqueue(buffer(frames: 100), hostTime: 100.7, at: 100.75)
        gate.reset()
        XCTAssertTrue(gate.drain(at: 101, finishing: true).isEmpty)
    }

    func testFutureBuffersAndAgedCallbacksAreSilent() {
        observe(.unmuted, at: 100)
        observe(.unmuted, at: 100.25)
        let future = gate.enqueue(buffer(frames: 100), hostTime: 100.1, at: 100.05)
        XCTAssertTrue(samples(future[0].buffer).allSatisfy { $0 == 0 })
        let aged = gate.enqueue(buffer(frames: 100), hostTime: 100.1, at: 103)
        XCTAssertTrue(samples(aged[0].buffer).allSatisfy { $0 == 0 })
    }

    func testLongRunsBoundPCMAndObservationHistory() {
        for index in 0..<20_000 {
            let timestamp = 100 + Double(index) * 0.01
            observe(.unmuted, at: timestamp)
            _ = gate.enqueue(buffer(frames: 10), hostTime: timestamp, at: timestamp)
            let state = gate.retainedState
            XCTAssertLessThanOrEqual(state.buffers, 128)
            XCTAssertLessThanOrEqual(state.duration, 0.750001)
            XCTAssertLessThanOrEqual(state.intervals, 128)
        }
        // Repeated callback timestamps cannot grow the PCM queue indefinitely.
        for _ in 0..<200 {
            _ = gate.enqueue(buffer(frames: 10), hostTime: time, at: time)
        }
        XCTAssertLessThanOrEqual(gate.retainedState.duration, 0.750001)
    }

    func testCAFContainsNoPrivateSamplesAndPreservesTimelineAndMutedTracks() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = RecordingClock(start: 100)
        let writer = try TimelineAudioWriter(url: url, format: buffer(frames: 1).format, clock: clock)
        observe(.unmuted, at: 100.1)
        observe(.unmuted, at: 100.3)
        observe(.muted, at: 100.4)
        let source = buffer(frames: 600, value: 0.99)
        for frame in 101..<299 { source.floatChannelData![0][frame] = 0.5 }
        // Place private values outside the conservative, fully confirmed span.
        source.floatChannelData![0][100] = 0.5
        source.floatChannelData![0][299] = 0.5
        _ = gate.enqueue(source, hostTime: 100, at: 100.6)
        for output in gate.drain(at: 100.6, finishing: true) {
            try writer.write(output.buffer, hostTime: output.hostTime)
        }
        clock.pause(at: 100.6)
        clock.resume(at: 110.6)
        gate.reset()
        _ = gate.enqueue(buffer(frames: 200, value: 0.99), hostTime: 110.6, at: 110.8)
        for output in gate.drain(at: 110.8, finishing: true) {
            try writer.write(output.buffer, hostTime: output.hostTime)
        }
        writer.finish()
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 800)
        let result = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 800)!
        try file.read(into: result)
        let values = samples(result)
        XCTAssertFalse(values.contains(0.99))
        XCTAssertTrue(values[101..<299].allSatisfy { $0 == 0.5 })
        XCTAssertTrue(values[600...].allSatisfy { $0 == 0 })
    }

    func testFramesCrossingConfirmationEdgesAreSilent() {
        observe(.unmuted, at: 100.0005)
        observe(.unmuted, at: 100.1005)
        _ = gate.enqueue(buffer(frames: 102), hostTime: 100, at: 100.2)
        let values = samples(gate.drain(at: 100.2, finishing: true)[0].buffer)
        XCTAssertEqual(values[0], 0)
        XCTAssertTrue(values[1..<100].allSatisfy { $0 == 0.5 })
        XCTAssertEqual(values[100], 0)
        XCTAssertEqual(values[101], 0)
    }

    func testTouchingConfirmationsDoNotCutInteriorAudioFrames() {
        observe(.unmuted, at: 100.0005)
        observe(.unmuted, at: 100.1005)
        observe(.unmuted, at: 100.2005)
        observe(.unmuted, at: 100.3005)
        _ = gate.enqueue(buffer(frames: 302), hostTime: 100, at: 100.4)
        let values = samples(gate.drain(at: 100.4, finishing: true)[0].buffer)
        XCTAssertEqual(values[0], 0)
        XCTAssertTrue(values[1..<300].allSatisfy { $0 == 0.5 })
        XCTAssertEqual(values[300], 0)
    }

    func testNativeReadWindowsCannotAuthorizeAudio() {
        time = 100.05
        gate.record(state: .unmuted, contextID: "meeting", at: time, readStartedAt: 100)
        time = 100.25
        gate.record(state: .unmuted, contextID: "meeting", at: time, readStartedAt: 100.2)
        time = 100.45
        gate.record(state: .unmuted, contextID: "meeting", at: time, readStartedAt: 100.4)
        _ = gate.enqueue(buffer(frames: 500), hostTime: 100, at: time)
        let values = samples(gate.drain(at: time, finishing: true)[0].buffer)
        XCTAssertEqual(values[25], 0)
        XCTAssertEqual(values[100], 0.5)
        XCTAssertEqual(values[225], 0)
        XCTAssertEqual(values[300], 0.5)
        XCTAssertEqual(values[425], 0)
    }

    func testInvalidReadWindowAndSingleObservationCannotAdmitSamples() {
        for readStart in [Double.nan, 101, 99] {
            time = 100
            gate.reset()
            gate.record(state: .unmuted, contextID: "meeting", at: 100, readStartedAt: readStart)
            observe(.unmuted, at: 100.2)
            _ = gate.enqueue(buffer(frames: 250), hostTime: 100, at: 100.25)
            XCTAssertTrue(samples(gate.drain(at: 100.25, finishing: true)[0].buffer).allSatisfy { $0 == 0 })
        }
    }

    func testEntirelyMutedCaptureIsAReadableSilentCAF() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try TimelineAudioWriter(url: url, format: buffer(frames: 1).format,
                                             clock: RecordingClock(start: 100))
        observe(.muted, at: 100)
        _ = gate.enqueue(buffer(frames: 500, value: 0.99), hostTime: 100, at: 100.5)
        for output in gate.drain(at: 100.5, finishing: true) {
            try writer.write(output.buffer, hostTime: output.hostTime)
        }
        writer.finish()
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 500)
        let result = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 500)!
        try file.read(into: result)
        XCTAssertTrue(samples(result).allSatisfy { $0 == 0 })
    }

    private func observe(_ state: MeetingMuteState, context: String? = "meeting", at time: TimeInterval) {
        self.time = time
        gate.record(state: state, contextID: context, at: time)
    }

    private func buffer(frames: AVAudioFrameCount, value: Float = 0.5) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 1_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        buffer.floatChannelData![0].update(repeating: value, count: Int(frames))
        return buffer
    }

    private func samples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
}
