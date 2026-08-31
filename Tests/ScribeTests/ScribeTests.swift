import Foundation
import XCTest
@testable import Scribe

final class ScribeTests: XCTestCase {
    func testExistingDocumentWithoutNewAutomationFieldsStillDecodes() throws {
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

        XCTAssertEqual(document.title, "Older transcript")
        XCTAssertNil(document.knownSpeakers)
        XCTAssertNil(document.segments[0].speaker)
        XCTAssertNil(document.tracks[0].speakerName)
    }

    func testSpeakerNamesFlowIntoExports() {
        let segments = [
            TranscriptSegment(start: 0, end: 1, text: "Welcome", source: .imported, speaker: "Host"),
            TranscriptSegment(start: 1, end: 2, text: "Thanks", source: .imported, speaker: "Guest"),
        ]
        let document = ScribeDocument(
            title: "Interview",
            kind: .imported,
            status: .ready,
            segments: segments
        )

        let text = Exporter.render(document, as: .txt)
        let subtitles = Exporter.render(document, as: .srt)
        XCTAssertTrue(text.contains("Host: Welcome"))
        XCTAssertTrue(text.contains("Guest: Thanks"))
        XCTAssertTrue(subtitles.contains("Host: Welcome"))
    }

    func testDiarizationUsesFirstAppearanceLabelsAndGreatestOverlap() {
        let segments = [
            TranscriptSegment(start: 0.1, end: 1.0, text: "First"),
            TranscriptSegment(start: 2.2, end: 3.0, text: "Second"),
        ]
        let intervals = [
            SpeakerInterval(speakerID: "internal-b", start: 0, end: 1.5),
            SpeakerInterval(speakerID: "internal-a", start: 2, end: 4),
        ]

        let assigned = SpeakerDiarizer.assignSpeakers(to: segments, using: intervals)
        XCTAssertEqual(assigned.map(\.speaker), ["Speaker 1", "Speaker 2"])
    }

    @MainActor
    func testCleanupRulesRespectWholeWordsAndLiteralReplacementTemplates() {
        let store = ReplacementStore()
        store.caseSensitive = false
        store.wholeWords = true
        store.removeFillerWords = true
        store.rules = [TextReplacement(original: "Mac whisper", replacement: "MacWhisper $1")]

        let result = store.apply(to: "Um, mac whisper and mac whisperer")
        XCTAssertEqual(result, "MacWhisper $1 and mac whisperer")
    }
}
