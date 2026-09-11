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
        XCTAssertEqual(clock.captureSlices(at: 101.5, duration: 1).first?.duration, 0.5)
        XCTAssertEqual(clock.captureSlices(at: 112.5, duration: 1).first?.duration, 0.5)
        XCTAssertNil(clock.captureTime(at: 114))
        XCTAssertEqual(clock.time(at: 200), 5)
    }
}

extension RecordingTimelineTests {
    func testBufferBeginningDuringPauseKeepsAudioAfterResume() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800)!
        buffer.frameLength = 800
        for frame in 0..<800 { buffer.floatChannelData![0][frame] = Float(frame) / 800 }
        let clock = RecordingClock(start: 100)
        clock.pause(at: 100)
        clock.resume(at: 100.05)
        let writer = try TimelineAudioWriter(url: url, format: format, clock: clock)
        try writer.write(buffer, hostTime: 100)
        writer.finish()
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 400)
        guard file.length == 400 else { return }
        let result = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 400)!
        try file.read(into: result)
        XCTAssertEqual(result.floatChannelData![0][0], 0.5)
        XCTAssertEqual(result.floatChannelData![0][399], 0.99875, accuracy: 0.00001)
    }
}

extension RecordingTimelineTests {
    func testInterleavedStereoBufferKeepsEveryActiveSpanAcrossTwoPauses() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8_000, channels: 2, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800)!
        buffer.frameLength = 800
        for frame in 0..<800 {
            buffer.floatChannelData![0][frame * 2] = Float(frame) / 800
            buffer.floatChannelData![0][frame * 2 + 1] = -Float(frame) / 800
        }
        let clock = RecordingClock(start: 100)
        clock.pause(at: 100.02)
        clock.resume(at: 100.04)
        clock.pause(at: 100.06)
        clock.resume(at: 100.08)
        clock.stop(at: 100.1)
        let writer = try TimelineAudioWriter(url: url, format: format, clock: clock)
        try writer.write(buffer, hostTime: 100)
        writer.finish()
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertEqual(file.length, 480)
        let result = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 480)!
        try file.read(into: result)
        for (index, value): (Int, Float) in [(0, 0), (159, 0.19875), (160, 0.4), (319, 0.59875), (320, 0.8), (479, 0.99875)] {
            XCTAssertEqual(result.floatChannelData![0][index], value, accuracy: 0.00001)
            XCTAssertEqual(result.floatChannelData![1][index], -value, accuracy: 0.00001)
        }
    }
}
