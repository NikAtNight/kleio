import Foundation
import AVFoundation
import XCTest
@testable import Scribe

final class SpeakerBenchmarkTests: XCTestCase {
    func testSilenceDoesNotInflateMissingSpeechOrSpeakerConfusion() {
        let result = SpeakerBenchmark.evaluate(reference: [
            .init(speaker: "A", start: 0, end: 1),
            .init(speaker: "B", start: 9, end: 10),
        ], detected: [
            .init(speaker: "one", start: 0, end: 1),
            .init(speaker: "two", start: 9, end: 10),
        ])
        XCTAssertEqual(result.referenceSpeechSeconds, 2)
        XCTAssertEqual(result.missedReferenceSpeechSeconds, 0)
        XCTAssertEqual(result.referenceVoicesWithMultipleClusters, 0)
        XCTAssertEqual(result.clustersCoveringMultipleVoices, 0)
    }

    func testOverlapIsExcludedFromIdentityPairings() {
        let result = SpeakerBenchmark.evaluate(reference: [
            .init(speaker: "A", start: 0, end: 2),
            .init(speaker: "B", start: 1, end: 3),
        ], detected: [
            .init(speaker: "one", start: 0, end: 2),
            .init(speaker: "two", start: 1, end: 3),
        ])
        XCTAssertEqual(result.referenceSpeechSeconds, 3)
        XCTAssertEqual(result.overlappingReferenceSpeechSeconds, 1)
        XCTAssertEqual(result.voices.first?.clusterOverlapSeconds, ["one": 1])
        XCTAssertEqual(result.voices.last?.clusterOverlapSeconds, ["two": 1])
        XCTAssertEqual(result.clustersCoveringMultipleVoices, 0)
    }

    func testSplitAndMergeIndicatorsUseExclusiveReferenceSpeech() {
        let split = SpeakerBenchmark.evaluate(reference: [.init(speaker: "A", start: 0, end: 2)], detected: [
            .init(speaker: "one", start: 0, end: 1), .init(speaker: "two", start: 1, end: 2),
        ])
        XCTAssertEqual(split.referenceVoicesWithMultipleClusters, 1)
        XCTAssertEqual(split.clustersCoveringMultipleVoices, 0)
        let merge = SpeakerBenchmark.evaluate(reference: [
            .init(speaker: "A", start: 0, end: 1), .init(speaker: "B", start: 1, end: 2),
        ], detected: [.init(speaker: "one", start: 0, end: 2)])
        XCTAssertEqual(merge.referenceVoicesWithMultipleClusters, 0)
        XCTAssertEqual(merge.clustersCoveringMultipleVoices, 1)
    }

    func testBenchmarkCannotOverwriteItsAudioInput() async {
        do {
            try await SpeakerBenchmark.run(arguments: ["/unused.wav", "/unused.json", "/unused.wav"])
            XCTFail("The report must not overwrite the audio")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("must not replace audio"))
        }
    }

    func testExistingOutputIsPreservedBeforeAnyAudioOrModelIsRead() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("valuable.json")
        let original = Data("Existing report must survive".utf8)
        try original.write(to: output)

        do {
            try await SpeakerBenchmark.run(arguments: ["/missing-audio.wav", "/missing-reference.json", output.path])
            XCTFail("An existing report must be rejected before reading audio or loading models")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("already exists"))
        }
        XCTAssertEqual(try Data(contentsOf: output), original)
    }

    func testOutputThroughSymlinkedParentCannotReplaceInput() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let real = folder.appendingPathComponent("real", isDirectory: true)
        let alias = folder.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let audio = real.appendingPathComponent("audio.wav")
        let original = Data("Audio must survive alias output".utf8)
        try original.write(to: audio)

        do {
            try await SpeakerBenchmark.run(arguments: [audio.path, "/missing-reference.json", alias.appendingPathComponent("audio.wav").path])
            XCTFail("An aliased existing output must be rejected before reading reference or audio")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("already exists"))
        }
        XCTAssertEqual(try Data(contentsOf: audio), original)
    }

    func testSinglePersonReportUsesTheAppBypassAndDoesNotClaimAccuracy() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("audio.caf")
        let reference = folder.appendingPathComponent("reference.json")
        let output = folder.appendingPathComponent("report.json")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        buffer.floatChannelData![0].initialize(repeating: 0, count: 160)
        do {
            let file = try AVAudioFile(forWriting: audio, settings: format.settings)
            try file.write(from: buffer)
        }
        try JSONEncoder().encode(SpeakerBenchmark.Reference(annotationKind: .speechActivity, source: "Generated fixture",
                                                            turns: [.init(speaker: "A", start: 0, end: 0.01)]))
            .write(to: reference)

        try await SpeakerBenchmark.run(arguments: [audio.path, reference.path, output.path, "--count", "1", "--model", "sortformer"])

        let report = try JSONDecoder().decode(SpeakerBenchmark.Report.self, from: Data(contentsOf: output))
        XCTAssertTrue(report.modelWasBypassed)
        XCTAssertEqual(report.detectedSpeakerCount, 1)
        XCTAssertNil(report.metrics)
        XCTAssertNil(report.preparationSeconds)
    }
}
