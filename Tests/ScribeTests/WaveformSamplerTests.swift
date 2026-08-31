import AVFoundation
import Foundation
import XCTest
@testable import Scribe

final class WaveformSamplerTests: XCTestCase {
    func testSamplesNormalizeSilenceAndMergeTracks() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("microphone.caf")
        let second = directory.appendingPathComponent("system.caf")
        try writeSineBurst(to: first, burstRange: 0..<2_000)
        try writeSineBurst(to: second, burstRange: 6_000..<8_000)

        let samples = await WaveformSampler.samples(for: [first, second], bucketCount: 100)

        XCTAssertEqual(samples.count, 100)
        XCTAssertEqual(samples.prefix(25).max() ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(samples.suffix(25).max() ?? 0, 1, accuracy: 0.001)
        XCTAssertLessThan(samples[40..<60].max() ?? 1, 0.001)
    }

    func testCacheHitsThenInvalidatesWhenAudioChanges() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let audio = directory.appendingPathComponent("audio.caf")
        try writeSineBurst(to: audio, burstRange: 0..<2_000)

        let first = await WaveformSampler.samples(for: [audio], bucketCount: 64)
        let cache = directory.appendingPathComponent("waveform.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
        let firstCache = try Data(contentsOf: cache)

        let cached = await WaveformSampler.samples(for: [audio], bucketCount: 64)
        XCTAssertEqual(cached, first)
        XCTAssertEqual(try Data(contentsOf: cache), firstCache)

        try FileManager.default.removeItem(at: audio)
        try writeSineBurst(to: audio, burstRange: 6_000..<8_000)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)],
            ofItemAtPath: audio.path
        )
        let recomputed = await WaveformSampler.samples(for: [audio], bucketCount: 64)
        XCTAssertNotEqual(recomputed, first)
        XCTAssertEqual(recomputed.suffix(20).max() ?? 0, 1, accuracy: 0.001)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WaveformSamplerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeSineBurst(to url: URL, burstRange: Range<Int>) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = 8_000
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)

        let samples = buffer.floatChannelData![0]
        for frame in 0..<frameCount {
            if burstRange.contains(frame) {
                samples[frame] = 0.6 * sin(Float(frame) * 0.08)
            }
        }
        try file.write(from: buffer)
    }
}
