import Foundation
import XCTest
@testable import Scribe

final class MeetingNotesTests: XCTestCase {
    func testMeetingNoteCodableRoundTrip() throws {
        let note = MeetingNote(time: 62.5, text: "Check the launch date")
        let decoded = try JSONDecoder().decode(MeetingNote.self, from: JSONEncoder().encode(note))

        XCTAssertEqual(decoded, note)
    }

    func testOlderDocumentWithoutNotesDecodes() throws {
        let id = UUID()
        let segmentID = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "title": "Older transcript",
          "createdAt": "2026-01-02T03:04:05Z",
          "kind": "imported",
          "status": "ready",
          "duration": 12.5,
          "tracks": [{"source":"imported","fileName":"audio.wav"}],
          "segments": [{"id":"\(segmentID.uuidString)","start":0,"end":2,"text":"Hello","source":"imported"}]
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(ScribeDocument.self, from: Data(json.utf8))

        XCTAssertNil(document.notes)
    }

    func testTimelineRowsMergeChronologically() {
        let segments = [
            TranscriptSegment(start: 10, end: 12, text: "Second"),
            TranscriptSegment(start: 30, end: 32, text: "Third"),
        ]
        let notes = [MeetingNote(time: 20, text: "Between")]

        let rows = TranscriptTimelineRow.merged(segments: segments, notes: notes)

        XCTAssertEqual(rows.map(\.time), [10, 20, 30])
        XCTAssertEqual(rows, [.segment(segments[0]), .note(notes[0]), .segment(segments[1])])
    }

    func testTextMarkdownAndHTMLExportsInterleaveNotes() {
        let document = ScribeDocument(
            title: "Planning",
            kind: .imported,
            status: .ready,
            segments: [
                TranscriptSegment(start: 5, end: 8, text: "Opening"),
                TranscriptSegment(start: 20, end: 25, text: "Closing"),
            ],
            notes: [MeetingNote(time: 12, text: "Confirm owner")]
        )

        let text = Exporter.render(document, as: .txt)
        let markdown = Exporter.render(document, as: .md)
        let html = Exporter.render(document, as: .html)

        XCTAssertTrue(text.contains("[0:12] Note: Confirm owner"))
        XCTAssertTrue(markdown.contains("> **0:12** Confirm owner"))
        XCTAssertTrue(html.contains("<strong>Note:</strong> Confirm owner"))
        XCTAssertLessThan(text.range(of: "Opening")!.lowerBound, text.range(of: "Note: Confirm owner")!.lowerBound)
        XCTAssertLessThan(text.range(of: "Note: Confirm owner")!.lowerBound, text.range(of: "Closing")!.lowerBound)
    }
}
