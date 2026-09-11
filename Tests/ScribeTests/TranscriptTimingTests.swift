import XCTest
@testable import Scribe

final class TranscriptTimingTests: XCTestCase {
    func testReplyInsideMicrophonePauseSplitsTheSentenceIntoChronologicalTurns() {
        let mic = segment(.microphone, "Ready? Thanks.", [word(1, 2, "Ready?"), word(4, 5, " Thanks.")])
        let reply = segment(.system, "Yes.", [word(2.5, 3, "Yes.")])
        let result = TranscriptTiming.chronologicalTurns(from: [mic, reply])
        XCTAssertEqual(result.map(\.text), ["Ready?", "Yes.", "Thanks."])
        XCTAssertEqual(result.map(\.source), [.microphone, .system, .microphone])
        XCTAssertEqual(result.map(\.start), [1, 2.5, 4])
        XCTAssertEqual(result.map(\.end), [2, 3, 5])
        XCTAssertEqual(result.first?.id, mic.id)
        XCTAssertEqual(result[1].id, reply.id)
        XCTAssertEqual(Set(result.map(\.id)).count, 3)
        XCTAssertEqual(result.filter { $0.source == .microphone }.flatMap { $0.words ?? [] }, mic.words)
        XCTAssertEqual(result.filter { $0.source == .microphone }.map(\.text).joined(separator: " "), mic.text)
        XCTAssertEqual(result.first?.speakerID, mic.speakerID)
        XCTAssertEqual(result.last?.speakerID, mic.speakerID)
        XCTAssertEqual(TranscriptTiming.chronologicalTurns(from: result), result)
    }

    func testMicrophoneReplySplitsAppAudioAndSupportsMultiplePauses() {
        let remote = segment(.system, "First. Second. Third.", [word(1, 2, "First."), word(4, 5, " Second."), word(7, 8, " Third.")])
        let firstReply = segment(.microphone, "Yes.", [word(2.2, 2.4, "Yes.")])
        let secondReply = segment(.microphone, "Okay.", [word(6, 6.2, "Okay.")])
        let result = TranscriptTiming.chronologicalTurns(from: [remote, secondReply, firstReply])
        XCTAssertEqual(result.map(\.text), ["First.", "Yes.", "Second.", "Okay.", "Third."])
        XCTAssertEqual(result.filter { $0.source == .system }.flatMap { $0.words ?? [] }, remote.words)
    }

    func testTimingUsesSpokenWordsInsteadOfDecoderSilencePadding() {
        var mic = segment(.microphone, "Later.", [word(8, 9, "Later.")])
        mic.start = 0
        mic.end = 30
        let remote = segment(.system, "Earlier.", [word(4, 5, "Earlier.")])
        let result = TranscriptTiming.chronologicalTurns(from: [mic, remote])
        XCTAssertEqual(result.map(\.text), ["Earlier.", "Later."])
        XCTAssertEqual(result.map(\.start), [4, 8])
        XCTAssertEqual(result.map(\.end), [5, 9])
        XCTAssertEqual(mic.start, 0)
        XCTAssertEqual(mic.end, 30)
    }

    func testContinuousOverlapDoesNotBecomeAlternatingWordFragments() {
        let mic = segment(.microphone, "Still speaking.", [word(1, 2, "Still"), word(2.1, 3, " speaking.")])
        let remote = segment(.system, "Together.", [word(1.5, 2.5, "Together.")])
        XCTAssertEqual(TranscriptTiming.chronologicalTurns(from: [mic, remote]), [mic, remote])
    }

    func testReplyBeginningDuringLastMicrophoneWordStillSeparatesResumedSpeech() {
        let mic = segment(.microphone, "Before. After.", [word(1, 2, "Before."), word(4, 5, " After.")])
        let remote = segment(.system, "A reply.", [word(1.8, 2.2, "A"), word(2.3, 3, " reply.")])
        let result = TranscriptTiming.chronologicalTurns(from: [mic, remote])
        XCTAssertEqual(result.map(\.text), ["Before.", "A reply.", "After."])
        XCTAssertEqual(result.map(\.start), [1, 1.8, 4])
        XCTAssertEqual(result.map(\.end), [2, 3, 5])
        XCTAssertEqual(result.filter { $0.source == .microphone }.flatMap { $0.words ?? [] }, mic.words)
        XCTAssertEqual(result[1].words, remote.words)
    }

    func testSameSourceAndSilenceDoNotInventAConversationHandoff() {
        let first = segment(.microphone, "Before after.", [word(1, 2, "Before"), word(4, 5, " after.")])
        let second = segment(.microphone, "Aside.", [word(3, 3.2, "Aside.")])
        XCTAssertEqual(TranscriptTiming.chronologicalTurns(from: [first, second]), [first, second])
        XCTAssertEqual(TranscriptTiming.chronologicalTurns(from: [first]), [first])
    }

    func testLegacyAndEditedTextRemainIntactWithoutUsableWordAlignment() {
        let remote = segment(.system, "Yes.", [word(2.5, 3, "Yes.")])
        var legacy = segment(.microphone, "Before after.", [word(1, 2, "Before"), word(4, 5, " after.")])
        legacy.words = nil
        var edited = legacy
        edited.words = [word(1, 2, "Wrong"), word(4, 5, " after.")]
        for original in [legacy, edited] {
            XCTAssertEqual(TranscriptTiming.chronologicalTurns(from: [original, remote]), [original, remote])
        }
    }

    func testInvalidAndUnorderedWordTimesNeverSplitOrRetimestampText() {
        let variants = [
            [word(-1, 2, "First"), word(4, 5, " last.")],
            [word(3, 2, "First"), word(4, 5, " last.")],
            [word(1, 2, "First"), word(0, 5, " last.")],
            [word(1, 8, "First"), word(4, 5, " last.")],
            [word(.infinity, .infinity, "First"), word(4, 5, " last.")],
        ]
        for words in variants {
            let original = TranscriptSegment(start: 0, end: 8, text: "First last.", source: .microphone, words: words)
            XCTAssertEqual(TranscriptTiming.chronologicalTurns(from: [original]), [original])
        }
    }

    func testPunctuationAndNonSpaceDelimitedWordsSurviveSplitting() {
        let mic = segment(.microphone, "你好。谢谢！", [word(1, 2, "你好。"), word(4, 5, "谢谢！")])
        let reply = segment(.system, "好。", [word(2.5, 3, "好。")])
        let result = TranscriptTiming.chronologicalTurns(from: [mic, reply])
        XCTAssertEqual(result.map(\.text), ["你好。", "好。", "谢谢！"])
        XCTAssertEqual(result.filter { $0.source == .microphone }.map(\.text).joined(), mic.text)
    }

    func testEqualStartTimesKeepInputOrder() {
        let first = segment(.microphone, "First.", [word(1, 2, "First.")])
        let second = segment(.system, "Second.", [word(1, 2, "Second.")])
        XCTAssertEqual(TranscriptTiming.chronologicalTurns(from: [first, second]), [first, second])
    }

    func testPlaybackNeverFallsBackToAnOlderEnclosingSegment() {
        let mic = TranscriptSegment(start: 15.64, end: 18.72, text: "Before and after", source: .microphone)
        let reply = TranscriptSegment(start: 16.44, end: 17.02, text: "Reply", source: .system)
        let segments = [mic, reply]
        XCTAssertEqual(TranscriptTiming.activeSegmentID(in: segments, at: 16), mic.id)
        XCTAssertEqual(TranscriptTiming.activeSegmentID(in: segments, at: 16.5), reply.id)
        XCTAssertNil(TranscriptTiming.activeSegmentID(in: segments, at: 17.1))
        XCTAssertNil(TranscriptTiming.activeSegmentID(in: segments, at: 18.5))
        // Seeking backward explicitly can return to the earlier turn.
        XCTAssertEqual(TranscriptTiming.activeSegmentID(in: segments, at: 16), mic.id)
    }

    func testPlaybackUsesTimeWithUnsortedArraysAndStableEqualStartTie() {
        let early = TranscriptSegment(start: 1, end: 20, text: "Early")
        let later = TranscriptSegment(start: 5, end: 6, text: "Later")
        let tied = TranscriptSegment(start: 5, end: 6, text: "Same start")
        XCTAssertEqual(TranscriptTiming.activeSegmentID(in: [later, early], at: 5.5), later.id)
        XCTAssertNil(TranscriptTiming.activeSegmentID(in: [later, early], at: 7))
        XCTAssertEqual(TranscriptTiming.activeSegmentID(in: [early, later, tied], at: 5.5), tied.id)
        XCTAssertNil(TranscriptTiming.activeSegmentID(in: [early], at: 0))
        XCTAssertNil(TranscriptTiming.activeSegmentID(in: [], at: 1))
        XCTAssertNil(TranscriptTiming.activeSegmentID(in: [early], at: .nan))
    }

    @MainActor
    func testPersistedTurnsDriveReadingOrderAndExports() throws {
        let mic = segment(.microphone, "Ready? Thanks.", [word(1, 2, "Ready?"), word(4, 5, " Thanks.")])
        let reply = segment(.system, "Yes.", [word(2.5, 3, "Yes.")])
        let original = [mic, reply]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let library = LibraryStore(baseURL: folder)
        let document = ScribeDocument(title: "Timing check", kind: .recording, status: .ready,
                                      segments: TranscriptTiming.chronologicalTurns(from: original), rawSegments: original)
        XCTAssertTrue(library.update(document))
        let reopened = try XCTUnwrap(LibraryStore(baseURL: folder).document(id: document.id))
        XCTAssertEqual(reopened.segments, document.segments)
        XCTAssertEqual(reopened.rawSegments, original)
        XCTAssertEqual(reopened.fullText, "Ready? Yes. Thanks.")
        XCTAssertEqual(TranscriptTimelineRow.merged(segments: reopened.segments, notes: []).map(\.time), [1, 2.5, 4])
        for format: ExportFormat in [.txt, .srt, .vtt, .csv] {
            let output = Exporter.render(reopened, as: format)
            let before = try XCTUnwrap(output.range(of: "Ready?"))
            let response = try XCTUnwrap(output.range(of: "Yes."))
            let after = try XCTUnwrap(output.range(of: "Thanks."))
            XCTAssertLessThan(before.lowerBound, response.lowerBound)
            XCTAssertLessThan(response.lowerBound, after.lowerBound)
        }
    }

    private func word(_ start: Double, _ end: Double, _ text: String) -> TranscriptWord {
        TranscriptWord(start: start, end: end, text: text, probability: 0.9)
    }

    private func segment(_ source: AudioSource, _ text: String, _ words: [TranscriptWord]) -> TranscriptSegment {
        TranscriptSegment(start: words[0].start, end: words.last!.end, text: text, source: source,
                          speaker: source.speakerLabel, speakerID: UUID(), words: words)
    }
}
