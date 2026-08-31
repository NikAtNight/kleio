import AVFoundation
import XCTest
@testable import Scribe

final class MicRecorderFormatTests: XCTestCase {
    func testConvertsMonoAcrossSampleRates() throws {
        let source = makeBuffer(sampleRate: 44_100, channels: 1, frames: 441) { frame, _ in
            sin(Float(frame) * 0.08) * 0.5
        }

        let converted = try MicAudioProcessing.convert(source)

        XCTAssertEqual(converted.format.channelCount, 1)
        XCTAssertEqual(converted.format.sampleRate, 48_000)
        XCTAssertEqual(converted.frameLength, 480, accuracy: 2)
        XCTAssertGreaterThan(MicAudioProcessing.level(of: converted), 0.7)
    }

    func testConvertsStereoToMono() throws {
        let source = makeBuffer(sampleRate: 48_000, channels: 2, frames: 480) { _, channel in
            channel == 0 ? 0.5 : 0.25
        }

        let converted = try MicAudioProcessing.convert(source)

        XCTAssertEqual(converted.format.channelCount, 1)
        XCTAssertEqual(converted.frameLength, 480)
        XCTAssertGreaterThan(converted.floatChannelData![0][100], 0.25)
        XCTAssertLessThan(converted.floatChannelData![0][100], 0.5)
    }

    func testLevelUsesRMSAndClampsToUnitRange() {
        XCTAssertEqual(MicAudioProcessing.level(of: [Float](repeating: 0, count: 64)), 0)
        XCTAssertEqual(MicAudioProcessing.level(of: [Float](repeating: 1, count: 64)), 1)
        XCTAssertEqual(
            MicAudioProcessing.level(of: [Float](repeating: 0.1, count: 64)),
            0.6,
            accuracy: 0.001
        )
    }

    private func makeBuffer(
        sampleRate: Double,
        channels: AVAudioChannelCount,
        frames: AVAudioFrameCount,
        sample: (Int, Int) -> Float
    ) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) {
                buffer.floatChannelData![channel][frame] = sample(frame, channel)
            }
        }
        return buffer
    }
}
