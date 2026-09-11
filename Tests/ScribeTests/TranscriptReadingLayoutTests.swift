import XCTest
@testable import Scribe

final class TranscriptReadingLayoutTests: XCTestCase {
    func testSameDisplayNameDoesNotCombineDifferentIdentitiesOrAudioSources() {
        let sharedID = UUID()
        let first = TranscriptSegment(start: 0, end: 1, text: "Hello.", source: .system, speaker: "Jordan", speakerID: sharedID)
        let differentIdentity = TranscriptSegment(start: 1, end: 2, text: "Hi.", source: .system, speaker: "Jordan", speakerID: UUID())
        let microphone = TranscriptSegment(start: 2, end: 3, text: "Morning.", source: .microphone, speaker: "Jordan", speakerID: sharedID)
        let remote = TranscriptSegment(start: 3, end: 4, text: "Ready?", source: .system, speaker: "Jordan", speakerID: sharedID)

        XCTAssertEqual(
            transcriptSpeakerGroupStarts(in: [.segment(first), .segment(differentIdentity), .segment(microphone), .segment(remote)]),
            [first.id, differentIdentity.id, microphone.id, remote.id]
        )
    }

    func testNoteStartsANewReadingGroupAndLegacyNamesRemainReadable() {
        let first = TranscriptSegment(start: 0, end: 1, text: "First.", source: .system, speaker: "Speaker 1")
        let continued = TranscriptSegment(start: 1, end: 2, text: "Continued.", source: .system, speaker: "Speaker 1")
        let note = MeetingNote(time: 3, text: "Follow up on this point.")
        let afterNote = TranscriptSegment(start: 4, end: 5, text: "After the note.", source: .system, speaker: "Speaker 1")
        let other = TranscriptSegment(start: 5, end: 6, text: "Reply.", source: .system, speaker: "Speaker 2")

        XCTAssertEqual(
            transcriptSpeakerGroupStarts(in: [.segment(first), .segment(continued), .note(note), .segment(afterNote), .segment(other)]),
            [first.id, afterNote.id, other.id]
        )
    }

    func testConsecutiveTurnsShareOneHeadingWithoutChangingTranscriptContent() {
        let speaker = UUID()
        let first = TranscriptSegment(start: 0, end: 2, text: "First sentence.", source: .system, speaker: "Jordan", speakerID: speaker)
        let second = TranscriptSegment(start: 2, end: 4, text: "Second sentence.", source: .system, speaker: "Jordan", speakerID: speaker)
        let other = TranscriptSegment(start: 5, end: 6, text: "Yes.", source: .microphone, speaker: "Me", speakerID: UUID())
        let rows: [TranscriptTimelineRow] = [.segment(first), .segment(second), .segment(other)]

        XCTAssertEqual(transcriptSpeakerGroupStarts(in: rows), [first.id, other.id])
        XCTAssertEqual(rows, [.segment(first), .segment(second), .segment(other)])
    }
}
