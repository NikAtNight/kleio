import AVFoundation
import XCTest
@testable import Scribe

final class RecordingTimelineTests: XCTestCase {
    func testPauseRemovesOnlyPausedTimeAndRejectsDelayedPausedBuffers() {
        let clock = RecordingClock(start: 100)
        clock.pause(at: 105)
        clock.resume(at: 115)
        XCTAssertEqual(clock.time(at: 120), 10)
        XCTAssertEqual(clock.time(at: 103), 3)
        XCTAssertNil(clock.captureTime(at: 110))
        XCTAssertNil(clock.captureTime(at: 99))
        XCTAssertEqual(clock.captureTime(at: 116), 6)
    }
}

extension RecordingTimelineTests {
    func testAudioKeepsInitialAndDeviceGapsButRemovesPause() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let samples = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800)!
        samples.frameLength = 800
        for index in 0..<800 { samples.floatChannelData![0][index] = 0.5 }
        let clock = RecordingClock(start: 100)
        let writer = try TimelineAudioWriter(url: url, format: format, clock: clock)
        try writer.write(samples, hostTime: 100.1)
        clock.pause(at: 100.2)
        clock.resume(at: 110.2)
        try writer.write(samples, hostTime: 105)
        try writer.write(samples, hostTime: 110.2)
        try writer.write(samples, hostTime: 110.5)
        writer.finish()
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 4_800)
        let result = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_800)!
        try file.read(into: result)
        let channel = result.floatChannelData![0]
        XCTAssertTrue((0..<800).allSatisfy { channel[$0] == 0 })
        XCTAssertEqual(channel[1_200], 0.5)
        XCTAssertEqual(channel[2_000], 0.5)
        XCTAssertTrue((2_400..<4_000).allSatisfy { channel[$0] == 0 })
        XCTAssertEqual(channel[4_400], 0.5)
    }

    func testQueuedBufferIsClippedAtPauseAndStopBoundaries() {
        let clock = RecordingClock(start: 100)
        clock.pause(at: 102)
        clock.resume(at: 110)
        clock.stop(at: 113)
        XCTAssertEqual(clock.captureRange(at: 101.5, duration: 1)?.duration, 0.5)
        XCTAssertEqual(clock.captureRange(at: 112.5, duration: 1)?.duration, 0.5)
        XCTAssertNil(clock.captureTime(at: 114))
        XCTAssertEqual(clock.time(at: 200), 5)
    }
}
