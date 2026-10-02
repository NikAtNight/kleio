import XCTest
@testable import Scribe

final class ParakeetTranscriberTests: XCTestCase {
    private typealias Token = ParakeetTranscriber.Token

    func testTokensBecomeAlignedWordsAndSentenceSegments() throws {
        // FluidAudio emits sentence punctuation after the pause, right before
        // the next word, so "." must not stretch "there" to 2.4 s.
        let tokens = [
            Token(text: " Hel", start: 0.0, end: 0.2), Token(text: "lo", start: 0.2, end: 0.4),
            Token(text: " there", start: 0.5, end: 0.8), Token(text: ".", start: 2.4, end: 2.4),
            Token(text: "\u{2581}How", start: 2.5, end: 2.7), Token(text: " are", start: 2.7, end: 2.9),
            Token(text: " you", start: 2.9, end: 3.1), Token(text: "?", start: 3.1, end: 3.1),
        ]
        let segments = ParakeetTranscriber.segments(text: "Hello there. How are you?", tokens: tokens,
                                                    source: .system, duration: 4)

        XCTAssertEqual(segments.map(\.text), ["Hello there.", "How are you?"])
        XCTAssertEqual(segments.map(\.start), [0, 2.5])
        XCTAssertEqual(segments.map(\.end), [0.8, 3.1])
        XCTAssertEqual(segments[0].words?.map(\.text), ["Hello", " there."])
        XCTAssertEqual(segments[1].words?.map(\.text), [" How", " are", " you?"])
        XCTAssertTrue(segments.allSatisfy { $0.source == .system })
        // Speaker analysis and turn splitting need a complete word alignment.
        for segment in segments {
            XCTAssertNotNil(TranscriptTiming.wordRanges(in: segment), segment.text)
        }
    }

    func testLongPauseSplitsUnpunctuatedSpeech() {
        let tokens = [
            Token(text: " okay", start: 0, end: 0.3), Token(text: " so", start: 0.3, end: 0.5),
            Token(text: " next", start: 2.0, end: 2.3), Token(text: " item", start: 2.3, end: 2.6),
        ]
        let segments = ParakeetTranscriber.segments(text: "okay so next item", tokens: tokens,
                                                    source: .microphone, duration: 3)
        XCTAssertEqual(segments.map(\.text), ["okay so", "next item"])
    }

    func testSpacedPunctuationKeepsTextAligned() throws {
        let tokens = [
            Token(text: " one", start: 0, end: 0.2), Token(text: " -", start: 0.2, end: 0.3),
            Token(text: " two", start: 0.3, end: 0.5),
        ]
        let segment = try XCTUnwrap(ParakeetTranscriber.segments(text: "one - two", tokens: tokens,
                                                                 source: .imported, duration: 1).first)
        XCTAssertEqual(segment.text, "one - two")
        XCTAssertNotNil(TranscriptTiming.wordRanges(in: segment))
    }

    func testBareBoundaryTokenStartsTheNextWord() throws {
        // Captured from FluidAudio 0.17.5: digits follow a standalone space token.
        let tokens = [
            Token(text: " at", start: 8.32, end: 8.48), Token(text: " ", start: 8.48, end: 8.56),
            Token(text: "3", start: 8.56, end: 8.8), Token(text: " o", start: 8.8, end: 8.88),
            Token(text: "'", start: 8.88, end: 8.96), Token(text: "c", start: 8.96, end: 9.04),
            Token(text: "lock", start: 9.04, end: 9.28), Token(text: ".", start: 9.28, end: 9.44),
        ]
        let segment = try XCTUnwrap(ParakeetTranscriber.segments(text: "at 3 o'clock.", tokens: tokens,
                                                                 source: .imported, duration: 10).first)
        XCTAssertEqual(segment.words?.map(\.text), ["at", " 3", " o'clock."])
        XCTAssertEqual(segment.words?[1].start, 8.56)
        XCTAssertNotNil(TranscriptTiming.wordRanges(in: segment))
    }

    func testSpacedOpeningPunctuationStartsTheNextWord() throws {
        let tokens = [
            Token(text: " Muy", start: 0, end: 0.2), Token(text: " bien", start: 0.2, end: 0.4),
            Token(text: ".", start: 0.4, end: 0.5), Token(text: " ¿", start: 0.6, end: 0.7),
            Token(text: "Qué", start: 0.7, end: 0.9), Token(text: "?", start: 0.9, end: 1.0),
        ]
        let segments = ParakeetTranscriber.segments(text: "Muy bien. ¿Qué?", tokens: tokens,
                                                    source: .imported, duration: 2)
        XCTAssertEqual(segments.map(\.text), ["Muy bien.", "¿Qué?"])
        XCTAssertEqual(segments.last?.start, 0.6)
        XCTAssertTrue(segments.allSatisfy { TranscriptTiming.wordRanges(in: $0) != nil })
    }

    func testUnspacedScriptsSplitAfterSentenceEnds() {
        let tokens = [
            Token(text: "こんにち", start: 0, end: 0.5), Token(text: "は", start: 0.5, end: 0.7),
            Token(text: "。", start: 0.7, end: 0.8), Token(text: "元気", start: 0.9, end: 1.2),
            Token(text: "です", start: 1.2, end: 1.4), Token(text: "か", start: 1.4, end: 1.5),
            Token(text: "？", start: 1.5, end: 1.6),
        ]
        let segments = ParakeetTranscriber.segments(text: "こんにちは。元気ですか？", tokens: tokens,
                                                    source: .imported, duration: 2)
        XCTAssertEqual(segments.map(\.text), ["こんにちは。", "元気ですか？"])
        XCTAssertTrue(segments.allSatisfy { TranscriptTiming.wordRanges(in: $0) != nil })
    }

    func testTokensThatDoNotRebuildTheTextFallBackToOneSegment() throws {
        let tokens = [Token(text: " something", start: 0, end: 0.5)]
        let segments = ParakeetTranscriber.segments(text: "Something else entirely.", tokens: tokens,
                                                    source: .imported, duration: 5)
        let segment = try XCTUnwrap(segments.first)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segment.text, "Something else entirely.")
        XCTAssertEqual(segment.start, 0)
        XCTAssertEqual(segment.end, 5)
        XCTAssertNil(segment.words)
    }

    func testTimesAreClampedToTheFileAndStayOrdered() throws {
        let tokens = [
            Token(text: " late", start: 4.8, end: 5.6), Token(text: " early", start: 4.5, end: 4.6),
        ]
        let segment = try XCTUnwrap(ParakeetTranscriber.segments(text: "late early", tokens: tokens,
                                                                 source: .imported, duration: 5).first)
        let words = try XCTUnwrap(segment.words)
        XCTAssertEqual(words.map(\.end), [5, 5])
        XCTAssertLessThanOrEqual(words[0].start, words[1].start)
        XCTAssertNotNil(TranscriptTiming.wordRanges(in: segment))
    }

    func testEmptyTextOrAudioProducesNoSegments() {
        XCTAssertTrue(ParakeetTranscriber.segments(text: "  ", tokens: [], source: .imported, duration: 3).isEmpty)
        XCTAssertTrue(ParakeetTranscriber.segments(text: "Hi", tokens: [], source: .imported, duration: 0).isEmpty)
    }

    func testShortClipsArePaddedToTheMinimumLength() {
        XCTAssertEqual(ParakeetTranscriber.padded([0.5, 0.5]).count, 24_000)
        XCTAssertEqual(ParakeetTranscriber.padded([0.5, 0.5]).prefix(2), [0.5, 0.5])
        let long = [Float](repeating: 0.1, count: 30_000)
        XCTAssertEqual(ParakeetTranscriber.padded(long), long)
    }

    func testRequestsParakeetCannotHonorFailBeforeDecoding() {
        XCTAssertThrowsError(try ParakeetTranscriber.validate(model: "parakeet-tdt-0.6b-v3", language: nil, translate: true))
        XCTAssertThrowsError(try ParakeetTranscriber.validate(model: "parakeet-tdt-0.6b-v3", language: "ja", translate: false))
        XCTAssertThrowsError(try ParakeetTranscriber.validate(model: "parakeet-tdt-0.6b-v2", language: "fr", translate: false))
        XCTAssertNoThrow(try ParakeetTranscriber.validate(model: "parakeet-tdt-0.6b-v3", language: "fr", translate: false))
        XCTAssertNoThrow(try ParakeetTranscriber.validate(model: "parakeet-tdt-0.6b-v2", language: nil, translate: false))
        XCTAssertNoThrow(try ParakeetTranscriber.validate(model: "parakeet-tdt-0.6b-ja", language: "", translate: false))
    }

    func testCatalogParakeetEntriesMatchTheEngine() {
        let variants = ModelManager.catalog.map(\.variant)
        XCTAssertEqual(Set(variants).count, variants.count, "catalog ids must be unique")
        let parakeet = Set(ModelManager.catalog.filter { $0.engine == .parakeet }.map(\.variant))
        XCTAssertEqual(parakeet, Set(ParakeetTranscriber.models.keys))
        XCTAssertEqual(parakeet, Set(ParakeetTranscriber.supportedLanguages.keys))
        XCTAssertTrue(ModelManager.catalog.filter { $0.engine == .whisper }
            .allSatisfy { !ParakeetTranscriber.isParakeet($0.variant) })
        XCTAssertEqual(ModelManager.displayName(for: "parakeet-tdt-0.6b-v3"), "Parakeet v3")
        XCTAssertEqual(ModelManager.displayName(for: "custom-model"), "custom-model")
    }

    func testCancelHandlerRunsWhenFlagIsSetEvenIfRegisteredLate() {
        let flag = CancelFlag()
        let fired = expectation(description: "handler ran")
        fired.expectedFulfillmentCount = 2
        flag.onSet { fired.fulfill() }
        flag.set()
        flag.onSet { fired.fulfill() }
        wait(for: [fired], timeout: 1)
    }
}
