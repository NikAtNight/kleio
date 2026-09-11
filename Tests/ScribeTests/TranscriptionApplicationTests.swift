import XCTest
@testable import Scribe

final class TranscriptionApplicationTests: XCTestCase {
    func testFirstTranscriptionSavesRawChunksAndInterleavesDisplayTurns() {
        let baseline = ScribeDocument(title: "Meeting", kind: .recording, status: .transcribing)
        let decoded = decodedFixture()
        let updated = TranscriptionQueue.applyingTranscript(decoded, to: baseline, basedOn: baseline)
        XCTAssertEqual(updated.rawSegments, decoded)
        XCTAssertEqual(updated.segments.map(\.text), ["Ready?", "Yes.", "Thanks."])
        XCTAssertEqual(updated.segments.map(\.source), [.microphone, .system, .microphone])
        XCTAssertEqual(updated.segments.first?.speakerID, updated.segments.last?.speakerID)
        XCTAssertNotEqual(updated.segments.first?.speakerID, updated.segments[1].speakerID)
    }

    func testLegacyRetranscriptionRetainsTheOriginalTextAndTiming() {
        let original = [TranscriptSegment(start: 0, end: 30, text: "My original correction.", source: .microphone)]
        let baseline = ScribeDocument(title: "Legacy", kind: .recording, status: .transcribing, segments: original)
        let updated = TranscriptionQueue.applyingTranscript(decodedFixture(), to: baseline, basedOn: baseline)
        XCTAssertEqual(updated.rawSegments, original)
        XCTAssertEqual(updated.segments.map(\.text), ["Ready?", "Yes.", "Thanks."])
        XCTAssertEqual(baseline.segments, original)
    }

    func testExistingRawTranscriptIsNotReplacedOnLaterRetranscription() {
        let raw = [TranscriptSegment(start: 0, end: 1, text: "Earliest raw text.")]
        let baseline = ScribeDocument(title: "Meeting", kind: .recording, status: .transcribing,
                                      segments: [TranscriptSegment(start: 1, end: 2, text: "Edited text.")], rawSegments: raw)
        let updated = TranscriptionQueue.applyingTranscript(decodedFixture(), to: baseline, basedOn: baseline)
        XCTAssertEqual(updated.rawSegments, raw)
    }

    func testConcurrentTextAndSpeakerEditsTakePrecedenceOverDecoding() {
        var baseline = ScribeDocument(title: "Meeting", kind: .recording, status: .transcribing, segments: decodedFixture())
        baseline.normalizeSpeakerIdentities()
        var edited = baseline
        edited.segments[0].text = "My edit while processing."
        edited.speakers?[0].name = "My saved name"
        let updated = TranscriptionQueue.applyingTranscript(decodedFixture(), to: edited, basedOn: baseline)
        XCTAssertEqual(updated.segments, edited.segments)
        XCTAssertEqual(updated.speakers, edited.speakers)
        XCTAssertEqual(updated.rawSegments, baseline.segments)
    }

    func testWarningChangesOnlyWithTheTranscriptItDescribes() {
        let priorWarning = "Previous partial transcript"
        let newWarning = "App audio was unavailable"
        let baseline = ScribeDocument(title: "Meeting", kind: .recording, status: .transcribing,
                                      segments: decodedFixture(), transcriptionWarning: priorWarning)
        let partial = TranscriptionQueue.applyingTranscript(decodedFixture(), to: baseline, basedOn: baseline,
                                                           transcriptionWarning: newWarning)
        XCTAssertEqual(partial.transcriptionWarning, newWarning)
        let complete = TranscriptionQueue.applyingTranscript(decodedFixture(), to: baseline, basedOn: baseline)
        XCTAssertNil(complete.transcriptionWarning)
        var edited = baseline
        edited.segments[0].text = "An edit while retrying"
        let preserved = TranscriptionQueue.applyingTranscript(decodedFixture(), to: edited, basedOn: baseline,
                                                              transcriptionWarning: newWarning)
        XCTAssertEqual(preserved.segments, edited.segments)
        XCTAssertEqual(preserved.transcriptionWarning, priorWarning)
        XCTAssertEqual(baseline.transcriptionWarning, priorWarning)
    }

    private func decodedFixture() -> [TranscriptSegment] {
        [TranscriptSegment(start: 0, end: 8, text: "Ready? Thanks.", source: .microphone, speaker: "You", words: [
            TranscriptWord(start: 1, end: 2, text: "Ready?"), TranscriptWord(start: 4, end: 5, text: " Thanks.")
        ]), TranscriptSegment(start: 2.5, end: 3, text: "Yes.", source: .system, speaker: "Speaker 1", words: [
            TranscriptWord(start: 2.5, end: 3, text: "Yes.")
        ])]
    }
}
