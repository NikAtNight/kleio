import XCTest
import WhisperKit
@testable import Scribe

final class TranscriptionBoundsTests: XCTestCase {
    func testSegmentsWhollyOutsideAudioAreRejectedWithoutMovingThemEarlier() {
        let result = convert([
            TranscriptionSegment(start: -2, end: -1, text: "Before"),
            TranscriptionSegment(start: 1, end: 2, text: "Inside"),
            TranscriptionSegment(start: 10, end: 10, text: "At EOF"),
            TranscriptionSegment(start: 11, end: 12, text: "After"),
        ])
        XCTAssertEqual(result.map(\.text), ["Inside"])
        XCTAssertEqual(result.map(\.start), [1])
        XCTAssertEqual(result.map(\.end), [2])
    }

    func testPartialTailClampsCrossingWordAndRemovesLaterWordsFromText() throws {
        let result = try XCTUnwrap(convert([
            TranscriptionSegment(start: 8, end: 12, text: "Keep tail. Omit this.", words: [
                word("Keep", 8, 9), word(" tail.", 9, 11),
                word(" Omit", 10, 11), word(" this.", 11, 12),
            ]),
        ]).first)
        XCTAssertEqual(result.text, "Keep tail.")
        XCTAssertEqual(result.start, 8)
        XCTAssertEqual(result.end, 10)
        XCTAssertEqual(result.words?.map(\.text), ["Keep", " tail."])
        XCTAssertEqual(result.words?.map(\.start), [8, 9])
        XCTAssertEqual(result.words?.map(\.end), [9, 10])
        XCTAssertNotNil(TranscriptTiming.wordRanges(in: result))
    }

    func testStartCrossingClampsOnlyTheIntervalAndPreservesWordSpacing() throws {
        let result = try XCTUnwrap(convert([
            TranscriptionSegment(start: -2, end: 2, text: "Before start now.", words: [
                word("Before", -2, -1), word(" start", -1, 1), word(" now.", 1, 2),
            ]),
        ]).first)
        XCTAssertEqual(result.text, "start now.")
        XCTAssertEqual(result.start, 0)
        XCTAssertEqual(result.end, 2)
        XCTAssertEqual(result.words?.map(\.text), [" start", " now."])
        XCTAssertEqual(result.words?.map(\.start), [0, 1])
        XCTAssertEqual(result.words?.map(\.end), [1, 2])
    }

    func testValidWordsKeepTimesProbabilityPunctuationAndZeroLengthAlignment() throws {
        let result = try XCTUnwrap(convert([
            TranscriptionSegment(start: 0, end: 10, text: "<|0.00|>Ready? Yes.<|10.00|>", words: [
                word("Ready", 0, 1), word("?", 1, 1), word(" Yes.", 9, 10),
            ]),
        ]).first)
        XCTAssertEqual(result.text, "Ready? Yes.")
        XCTAssertEqual(result.source, .system)
        XCTAssertEqual(result.start, 0)
        XCTAssertEqual(result.end, 10)
        XCTAssertEqual(result.words?.map(\.text), ["Ready", "?", " Yes."])
        XCTAssertEqual(result.words?.map(\.start), [0, 1, 9])
        XCTAssertEqual(result.words?.map(\.end), [1, 1, 10])
        XCTAssertEqual(result.words?.map(\.probability), [0.9, 0.9, 0.9])
    }

    func testSegmentWithAllWordsOutsideAudioIsRejected() {
        XCTAssertTrue(convert([
            TranscriptionSegment(start: 9, end: 12, text: "Padded speech", words: [
                word("Padded", 11, 12), word(" speech", 12, 13),
            ]),
        ]).isEmpty)
    }

    func testMissingWordAlignmentKeepsTextAndClampsSegmentTimes() {
        let result = convert([
            TranscriptionSegment(start: -1, end: 1, text: "At start"),
            TranscriptionSegment(start: 9, end: 12, text: "At end", words: []),
        ])
        XCTAssertEqual(result.map(\.text), ["At start", "At end"])
        XCTAssertEqual(result.map(\.start), [0, 9])
        XCTAssertEqual(result.map(\.end), [1, 10])
        XCTAssertNil(result[0].words)
        XCTAssertEqual(result[1].words, [])
    }

    func testNonfiniteReversedAndNegativeOnlySegmentRangesAreRejected() {
        let ranges: [(Float, Float)] = [(.nan, 1), (0, .infinity), (-.infinity, 1),
                                        (2, 1), (-1, 0), (-1, -1)]
        XCTAssertTrue(convert(ranges.map {
            TranscriptionSegment(start: $0.0, end: $0.1, text: "Invalid")
        }).isEmpty)
    }

    func testInvalidWordRangesAreRemovedWithoutLosingValidWordText() throws {
        let result = try XCTUnwrap(convert([
            TranscriptionSegment(start: 0, end: 2, text: "Bad bad bad valid.", words: [
                word("Bad", .nan, 1), word(" bad", 1, .infinity),
                word(" bad", 2, 1), word(" valid.", 1, 2),
            ]),
        ]).first)
        XCTAssertEqual(result.text, "valid.")
        XCTAssertEqual(result.words?.map(\.text), [" valid."])
        XCTAssertEqual(result.words?.map(\.start), [1])
        XCTAssertEqual(result.words?.map(\.end), [2])
    }

    func testInvalidExplicitDurationsRejectAllOutputAndOmittedDurationKeepsExistingCallers() {
        let segments = [TranscriptionSegment(start: 1, end: 2, text: "Valid")]
        for duration in [0, -1, .nan, .infinity] as [TimeInterval] {
            XCTAssertTrue(convert(segments, duration: duration).isEmpty)
        }
        XCTAssertEqual(convert(segments, duration: nil).map(\.text), ["Valid"])
    }

    private func convert(_ segments: [TranscriptionSegment], duration: TimeInterval? = 10) -> [TranscriptSegment] {
        Transcriber.segments(from: [
            TranscriptionResult(text: "", segments: segments, language: "en", timings: TranscriptionTimings()),
        ], source: .system, duration: duration)
    }

    private func word(_ text: String, _ start: Float, _ end: Float) -> WordTiming {
        WordTiming(word: text, tokens: [], start: start, end: end, probability: 0.9)
    }
}
