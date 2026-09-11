import AVFoundation
import XCTest
@testable import Scribe

final class TapInputFormatTests: XCTestCase {
    func testTapChannelsCanStartAfterHardwareOutputChannels() throws {
        try TapInputFormat.validateChannelOrder(starts: [1], counts: [2])
        try TapInputFormat.validateChannelOrder(starts: [7], counts: [2])
        try TapInputFormat.validateChannelOrder(starts: [7, 8], counts: [1, 1])
    }

    func testTapChannelOrderRejectsMissingOverlappingOrInvalidChannels() {
        for (starts, counts): ([UInt32], [UInt32]) in [([], []), ([0], [2]), ([7], []),
                                                     ([7, 7], [1, 1]), ([7, 9], [1, 1]), ([7], [0]), ([.max], [2])] {
            XCTAssertThrowsError(try TapInputFormat.validateChannelOrder(starts: starts, counts: counts))
        }
    }

    func testTimingAcceptsContinuous24And48kBuffers() throws {
        for rate in [24_000.0, 48_000.0] {
            var timing = TapTimingValidator()
            for index in 0..<20 {
                try timing.validate(frames: 480, rate: rate,
                    hostTime: 100 + Double(index * 480) / rate, sampleTime: Double(index * 480))
            }
        }
    }

    func testTimingRejectsPersistentHalfRateDeliveryInsteadOfFillingEveryOtherBlock() {
        for sampleStep in [480.0, 960.0] {
            var timing = TapTimingValidator()
            for index in 0..<5 {
                XCTAssertNoThrow(try timing.validate(frames: 480, rate: 48_000,
                    hostTime: 100 + Double(index) * 0.02, sampleTime: Double(index) * sampleStep))
            }
            XCTAssertThrowsError(try timing.validate(frames: 480, rate: 48_000,
                hostTime: 100.1, sampleTime: 5 * sampleStep))
        }
    }

    func testTimingKeepsIsolatedGapsAndRecoversAfterDeliveryResumes() throws {
        var timing = TapTimingValidator()
        for offset in [0.0, 0.02, 0.5, 0.52, 0.54, 0.56, 1.2, 1.22, 1.24] {
            try timing.validate(frames: 480, rate: 24_000,
                hostTime: 100 + offset, sampleTime: offset * 24_000)
        }
    }

    func testTimingRejectsInvalidOrNonmonotonicHostTime() throws {
        var timing = TapTimingValidator()
        XCTAssertThrowsError(try timing.validate(frames: 480, rate: 24_000, hostTime: .nan, sampleTime: nil))
        try timing.validate(frames: 480, rate: 24_000, hostTime: 100, sampleTime: nil)
        XCTAssertThrowsError(try timing.validate(frames: 480, rate: 24_000, hostTime: 100, sampleTime: nil))
    }

    func test24kInterleavedStereoKeepsTwentyMillisecondsPerBuffer() throws {
        try assertContinuousTimeline(rate: 24_000, interleaved: true, duration: 0.02)
    }

    func test24kPlanarStereoKeepsTwentyMillisecondsPerBuffer() throws {
        try assertContinuousTimeline(rate: 24_000, interleaved: false, duration: 0.02)
    }

    func test48kInterleavedStereoKeepsTenMillisecondsPerBuffer() throws {
        try assertContinuousTimeline(rate: 48_000, interleaved: true, duration: 0.01)
    }

    func test48kPlanarStereoKeepsTenMillisecondsPerBuffer() throws {
        try assertContinuousTimeline(rate: 48_000, interleaved: false, duration: 0.01)
    }

    func testSeparateMonoTapStreamsKeepBothChannels() throws {
        let mono = format(rate: 24_000, channels: 1, interleaved: false)
        let input = try TapInputFormat(streamFormats: [mono, mono])
        let left = makeBuffer(format: mono, channelOffset: 0)
        let right = makeBuffer(format: mono, channelOffset: 1)

        let copied = try withBufferList([left, right]) { list in
            try XCTUnwrap(input.copyBuffer(from: list.unsafePointer))
        }

        XCTAssertEqual(copied.frameLength, 480)
        XCTAssertEqual(copied.format.sampleRate, 24_000)
        assertSamples(copied, expected: expectedSamples(frames: 480))
    }

    func testHardwarePrefixesAreRejectedBeforeTheirSamplesCanBeRead() throws {
        let hardwareFormat = format(rate: 24_000, channels: 1, interleaved: false)
        let tapFormat = format(rate: 24_000, channels: 2, interleaved: true)
        XCTAssertThrowsError(try TapInputFormat(streamFormats: [hardwareFormat, tapFormat]))
        let input = try TapInputFormat(streamFormats: [tapFormat])
        let hardware = makeBuffer(format: hardwareFormat)
        for index in 0..<480 { hardware.floatChannelData![0][index] = .nan }
        let tap = makeBuffer(format: tapFormat)

        try withBufferList([hardware, tap]) { list in
            XCTAssertThrowsError(try input.copyBuffer(from: list.unsafePointer))
            list[0].mData = nil
            XCTAssertThrowsError(try input.copyBuffer(from: list.unsafePointer))
        }
    }

    func testMalformedStreamDescriptionsAreRejected() {
        let mono24 = format(rate: 24_000, channels: 1, interleaved: false)
        let mono48 = format(rate: 48_000, channels: 1, interleaved: false)
        let stereo = format(rate: 24_000, channels: 2, interleaved: true)
        let integer = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000,
                                    channels: 2, interleaved: true)!

        XCTAssertThrowsError(try TapInputFormat(streamFormats: []))
        XCTAssertThrowsError(try TapInputFormat(streamFormats: [mono24]))
        XCTAssertThrowsError(try TapInputFormat(streamFormats: [stereo, mono24]))
        XCTAssertThrowsError(try TapInputFormat(streamFormats: [mono24, mono48]))
        XCTAssertThrowsError(try TapInputFormat(streamFormats: [integer]))
    }

    func testMalformedCallbackChannelsByteCountsAndMissingDataAreRejected() throws {
        let stereo = format(rate: 24_000, channels: 2, interleaved: true)
        let input = try TapInputFormat(streamFormats: [stereo])
        let buffer = makeBuffer(format: stereo)

        try withBufferList([buffer]) { list in
            let valid = list[0]
            list[0].mNumberChannels = 1
            XCTAssertThrowsError(try input.copyBuffer(from: list.unsafePointer))
            list[0] = valid

            list[0].mDataByteSize -= 1
            XCTAssertThrowsError(try input.copyBuffer(from: list.unsafePointer))
            list[0] = valid

            list[0].mData = nil
            XCTAssertThrowsError(try input.copyBuffer(from: list.unsafePointer))
        }
    }

    func testPlanarBuffersWithDifferentFrameLengthsAreRejected() throws {
        let stereo = format(rate: 24_000, channels: 2, interleaved: false)
        let input = try TapInputFormat(streamFormats: [stereo])
        let buffer = makeBuffer(format: stereo)

        try withBufferList([buffer]) { list in
            list[1].mDataByteSize -= UInt32(MemoryLayout<Float>.size)
            XCTAssertThrowsError(try input.copyBuffer(from: list.unsafePointer))
        }
    }

    func testMissingOrExtraCallbackBuffersAreRejected() throws {
        let mono = format(rate: 24_000, channels: 1, interleaved: false)
        let input = try TapInputFormat(streamFormats: [mono, mono])
        let buffer = makeBuffer(format: mono)

        try withBufferList([buffer]) { list in
            XCTAssertThrowsError(try input.copyBuffer(from: list.unsafePointer))
        }
        try withBufferList([buffer, buffer, buffer]) { list in
            XCTAssertThrowsError(try input.copyBuffer(from: list.unsafePointer))
        }
    }

    func testEmptyTapCallbackProducesNoAudio() throws {
        let stereo = format(rate: 24_000, channels: 2, interleaved: false)
        let input = try TapInputFormat(streamFormats: [stereo])
        let buffer = makeBuffer(format: stereo)

        try withBufferList([buffer]) { list in
            for index in list.indices {
                list[index].mDataByteSize = 0
                list[index].mData = nil
            }
            XCTAssertNil(try input.copyBuffer(from: list.unsafePointer))
        }
    }

    func testGenuineHostTimeGapRemainsSilence() throws {
        let stereo = format(rate: 24_000, channels: 2, interleaved: true)
        let input = try TapInputFormat(streamFormats: [stereo])
        let first = makeBuffer(format: stereo)
        let second = makeBuffer(format: stereo, frameOffset: 480)
        let result = try writeTimeline(input: input, callbacks: [[first], [second]], hostTimes: [100, 100.03])

        XCTAssertEqual(result.frameLength, 1_200)
        let firstSamples = expectedSamples(frames: 480)
        let secondSamples = expectedSamples(frames: 480, frameOffset: 480)
        assertSamples(result, expected: (0..<2).map {
            firstSamples[$0] + Array(repeating: 0, count: 240) + secondSamples[$0]
        })
    }

    private func assertContinuousTimeline(rate: Double, interleaved: Bool, duration: Double) throws {
        let stereo = format(rate: rate, channels: 2, interleaved: interleaved)
        let input = try TapInputFormat(streamFormats: [stereo])
        let first = makeBuffer(format: stereo)
        let second = makeBuffer(format: stereo, frameOffset: 480)
        let result = try writeTimeline(input: input, callbacks: [[first], [second]], hostTimes: [100, 100 + duration])

        XCTAssertEqual(input.format.sampleRate, rate)
        XCTAssertEqual(Double(first.frameLength) / input.format.sampleRate, duration, accuracy: 0.000001)
        XCTAssertEqual(result.frameLength, 960)
        XCTAssertEqual(Double(result.frameLength) / result.format.sampleRate, duration * 2, accuracy: 0.000001)
        assertSamples(result, expected: expectedSamples(frames: 960))
    }

    private func writeTimeline(input: TapInputFormat, callbacks: [[AVAudioPCMBuffer]], hostTimes: [Double]) throws -> AVAudioPCMBuffer {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try TimelineAudioWriter(url: url, format: input.format, clock: RecordingClock(start: 100))
        for (buffers, hostTime) in zip(callbacks, hostTimes) {
            let copied = try withBufferList(buffers) { list in
                try XCTUnwrap(input.copyBuffer(from: list.unsafePointer))
            }
            try writer.write(copied, hostTime: hostTime)
        }
        writer.finish()
        let file = try AVAudioFile(forReading: url)
        let result = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                  frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: result)
        return result
    }

    private func format(rate: Double, channels: UInt32, interleaved: Bool) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: interleaved)!
    }

    private func makeBuffer(format: AVAudioFormat, frameOffset: Int = 0, channelOffset: Int = 0) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<480 {
                let value = sample(frame: frame + frameOffset, channel: channel + channelOffset)
                if format.isInterleaved {
                    buffer.floatChannelData![0][frame * Int(format.channelCount) + channel] = value
                } else {
                    buffer.floatChannelData![channel][frame] = value
                }
            }
        }
        return buffer
    }

    private func sample(frame: Int, channel: Int) -> Float {
        let value = Float(frame % 31 + 1) / 32
        return channel == 0 ? value : -value
    }

    private func expectedSamples(frames: Int, frameOffset: Int = 0) -> [[Float]] {
        (0..<2).map { channel in (0..<frames).map { sample(frame: $0 + frameOffset, channel: channel) } }
    }

    private func assertSamples(_ buffer: AVAudioPCMBuffer, expected: [[Float]], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Int(buffer.format.channelCount), expected.count, file: file, line: line)
        for (channel, samples) in expected.enumerated() {
            let actual = Array(UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength)))
            XCTAssertEqual(actual, samples, file: file, line: line)
        }
    }

    private func withBufferList<T>(_ buffers: [AVAudioPCMBuffer], body: (UnsafeMutableAudioBufferListPointer) throws -> T) rethrows -> T {
        let descriptors = buffers.flatMap { Array(UnsafeMutableAudioBufferListPointer($0.mutableAudioBufferList)) }
        let list = AudioBufferList.allocate(maximumBuffers: descriptors.count)
        defer { list.unsafeMutablePointer.deallocate() }
        for (index, descriptor) in descriptors.enumerated() { list[index] = descriptor }
        return try withExtendedLifetime(buffers) { try body(list) }
    }
}
