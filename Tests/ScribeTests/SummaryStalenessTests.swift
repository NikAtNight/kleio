import Foundation
import XCTest
@testable import Scribe

@MainActor
final class SummaryStalenessTests: XCTestCase {
    func testSourceEditRetainsSummaryAndPersistsStaleMarker() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var document = fixture.document
        document.summary = "Keep this summary."
        document.summaryIsStale = false
        XCTAssertTrue(fixture.library.update(document))

        document = try XCTUnwrap(fixture.library.document(id: fixture.id))
        document.notes = [MeetingNote(time: 1, text: "A note added after summarization")]
        XCTAssertTrue(fixture.library.update(document))

        let saved = try XCTUnwrap(LibraryStore(baseURL: fixture.root).document(id: fixture.id))
        XCTAssertEqual(saved.summary, "Keep this summary.")
        XCTAssertTrue(saved.summaryIsStale == true)
        XCTAssertTrue(Exporter.render(saved, as: .md).contains("## Summary (out of date)"))
        XCTAssertTrue(Exporter.render(saved, as: .html).contains("<h2>Summary (out of date)</h2>"))
    }

    func testNonSourceEditDoesNotMarkSummaryStale() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var document = fixture.document
        document.summary = "Current summary."
        document.summaryIsStale = false
        XCTAssertTrue(fixture.library.update(document))

        document = try XCTUnwrap(fixture.library.document(id: fixture.id))
        document.failureReason = "A diagnostic that is not summary source."
        XCTAssertTrue(fixture.library.update(document))

        XCTAssertFalse(fixture.document.summaryIsStale == true)
    }

    func testRenamingARecordingKeepsItsSummaryCurrent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var document = fixture.document
        document.summary = "Current summary."
        document.summaryIsStale = false
        XCTAssertTrue(fixture.library.update(document))

        document = try XCTUnwrap(fixture.library.document(id: fixture.id))
        document.title = "Sept 23 - Meeting w/ Dan"
        XCTAssertTrue(fixture.library.update(document))

        XCTAssertEqual(fixture.document.title, "Sept 23 - Meeting w/ Dan")
        XCTAssertFalse(fixture.document.summaryIsStale == true)
    }

    func testSuccessfulSameTextRegenerationClearsStaleMarkerAndFailureDoesNot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var document = fixture.document
        document.summary = "Same valid summary."
        document.summaryIsStale = true
        XCTAssertTrue(fixture.library.update(document))
        let stale = fixture.document

        XCTAssertThrowsError(try SummaryService.applyingSummary("", to: stale, basedOn: stale))
        XCTAssertTrue(fixture.document.summaryIsStale == true)

        let regenerated = try SummaryService.applyingSummary("Same valid summary.", to: stale, basedOn: stale)
        XCTAssertEqual(regenerated.summary, stale.summary)
        XCTAssertFalse(regenerated.summaryIsStale == true)
        XCTAssertTrue(fixture.library.update(regenerated))
        XCTAssertFalse(fixture.document.summaryIsStale == true)
    }

    func testOlderDocumentWithoutStaleMarkerDecodes() throws {
        let document = fixtureDocument()
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(ScribeDocument.self, from: data)
        XCTAssertNil(decoded.summaryIsStale)
    }
}

@MainActor
private final class Fixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("kleio-summary-stale-" + UUID().uuidString, isDirectory: true)
    let library: LibraryStore
    let id: UUID

    var document: ScribeDocument { library.document(id: id)! }

    init() throws {
        library = LibraryStore(baseURL: root)
        let document = fixtureDocument()
        id = document.id
        guard library.add(document) else { throw NSError(domain: "SummaryStalenessTests", code: 1) }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func fixtureDocument() -> ScribeDocument {
    ScribeDocument(
        title: "Planning",
        kind: .recording,
        status: .ready,
        duration: 30,
        tracks: [AudioTrack(source: .microphone, fileName: "audio.caf")],
        segments: [TranscriptSegment(start: 0, end: 1, text: "Original transcript.", source: .microphone)]
    )
}
