import Foundation
import XCTest
@testable import Scribe

final class DocumentEditingTests: XCTestCase {
    @MainActor
    func testTextAndNoteEditsRetryAfterManifestFailureAndPreserveNewerFields() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let segment = TranscriptSegment(start: 0, end: 1, text: "Original")
        let existingNote = MeetingNote(time: 0.5, text: "Existing note")
        let document = ScribeDocument(
            title: "First title",
            kind: .recording,
            status: .ready,
            segments: [segment],
            notes: [existingNote]
        )
        let library = LibraryStore(baseURL: root)
        XCTAssertTrue(library.update(document))

        var newer = try XCTUnwrap(library.document(id: document.id))
        newer.title = "Title saved elsewhere"
        newer.summary = "Keep this summary"
        XCTAssertTrue(library.update(newer))

        let firstBackup = try blockManifest(for: document.id, in: library, suffix: "text")
        XCTAssertThrowsError(try DocumentEditing.updateSegmentText(
            "Edited", segmentID: segment.id, documentID: document.id, library: library
        ))
        XCTAssertEqual(library.document(id: document.id)?.segments[0].text, "Original")
        XCTAssertEqual(library.document(id: document.id)?.title, "Title saved elsewhere")
        try unblockManifest(for: document.id, in: library, backup: firstBackup)

        XCTAssertEqual(
            try DocumentEditing.updateSegmentText(
                "Edited", segmentID: segment.id, documentID: document.id, library: library
            ),
            "Original"
        )

        let addedNote = MeetingNote(time: 1.5, text: "Retry this note")
        let secondBackup = try blockManifest(for: document.id, in: library, suffix: "note")
        XCTAssertThrowsError(try DocumentEditing.appendNote(addedNote, documentID: document.id, library: library))
        XCTAssertEqual(library.document(id: document.id)?.notes, [existingNote])
        try unblockManifest(for: document.id, in: library, backup: secondBackup)
        XCTAssertTrue(try DocumentEditing.appendNote(addedNote, documentID: document.id, library: library))

        let thirdBackup = try blockManifest(for: document.id, in: library, suffix: "note-edit")
        XCTAssertThrowsError(try DocumentEditing.updateNoteText(
            "Edited existing note", noteID: existingNote.id, documentID: document.id, library: library
        ))
        XCTAssertEqual(library.document(id: document.id)?.notes?.first?.text, "Existing note")
        try unblockManifest(for: document.id, in: library, backup: thirdBackup)
        XCTAssertTrue(try DocumentEditing.updateNoteText(
            "Edited existing note", noteID: existingNote.id, documentID: document.id, library: library
        ))

        let fourthBackup = try blockManifest(for: document.id, in: library, suffix: "title")
        XCTAssertThrowsError(try DocumentEditing.updateTitle(
            "Retried title", documentID: document.id, library: library
        ))
        XCTAssertEqual(library.document(id: document.id)?.title, "Title saved elsewhere")
        try unblockManifest(for: document.id, in: library, backup: fourthBackup)
        XCTAssertTrue(try DocumentEditing.updateTitle("Retried title", documentID: document.id, library: library))

        let reopened = try XCTUnwrap(LibraryStore(baseURL: root).document(id: document.id))
        XCTAssertEqual(reopened.title, "Retried title")
        XCTAssertEqual(reopened.summary, "Keep this summary")
        XCTAssertEqual(reopened.segments[0].text, "Edited")
        XCTAssertEqual(reopened.notes?.map(\.text), ["Edited existing note", "Retry this note"])
    }

    @MainActor
    func testReplaceAllReportsChangesOnlyAfterManifestSave() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let note = MeetingNote(time: 2, text: "Keep note")
        let document = ScribeDocument(
            title: "Planning",
            kind: .recording,
            status: .ready,
            segments: [
                TranscriptSegment(start: 0, end: 1, text: "Alpha alpha"),
                TranscriptSegment(start: 1, end: 2, text: "No match"),
            ],
            notes: [note]
        )
        let library = LibraryStore(baseURL: root)
        XCTAssertTrue(library.update(document))

        let backup = try blockManifest(for: document.id, in: library, suffix: "replace")
        XCTAssertThrowsError(try DocumentEditing.replaceAll(
            "alpha", with: "beta", options: [.caseInsensitive], documentID: document.id, library: library
        ))
        XCTAssertEqual(library.document(id: document.id)?.segments[0].text, "Alpha alpha")
        try unblockManifest(for: document.id, in: library, backup: backup)

        XCTAssertEqual(try DocumentEditing.replaceAll(
            "alpha", with: "beta", options: [.caseInsensitive], documentID: document.id, library: library
        ), 1)
        let reopened = try XCTUnwrap(LibraryStore(baseURL: root).document(id: document.id))
        XCTAssertEqual(reopened.segments.map(\.text), ["beta beta", "No match"])
        XCTAssertEqual(reopened.notes, [note])
        XCTAssertEqual(reopened.title, "Planning")
    }

    @MainActor
    func testFailedSpeakerUndoCanRetryAndPreservesLaterDocumentEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var document = speakerDocument()
        document.normalizeSpeakerIdentities()
        let remoteID = try XCTUnwrap(document.segments[1].speakerID)
        let originalName = try XCTUnwrap(document.speakers?.first { $0.id == remoteID }?.name)
        let library = LibraryStore(baseURL: root)
        XCTAssertTrue(library.update(document))
        let undoManager = UndoManager()
        var undoFailure: String?

        XCTAssertTrue(try DocumentEditing.applySpeakerEdit(
            documentID: document.id,
            library: library,
            undoManager: undoManager,
            actionName: "Rename speaker",
            onUndoFailure: { undoFailure = $0 },
            change: { $0.renameSpeaker(id: remoteID, to: "Jordan") }
        ))
        XCTAssertTrue(undoManager.canUndo)

        var later = try XCTUnwrap(library.document(id: document.id))
        later.title = "Later title edit"
        later.segments[1].text = "Later transcript edit"
        XCTAssertTrue(library.update(later))

        let backup = try blockManifest(for: document.id, in: library, suffix: "undo")
        undoManager.undo()
        let afterFailedUndo = try XCTUnwrap(library.document(id: document.id))
        XCTAssertEqual(afterFailedUndo.speakerName(for: afterFailedUndo.segments[1]), "Jordan")
        await nextMainQueueTurn()
        XCTAssertNotNil(undoFailure)
        XCTAssertTrue(undoManager.canUndo)

        try unblockManifest(for: document.id, in: library, backup: backup)
        undoManager.undo()
        let reopened = try XCTUnwrap(LibraryStore(baseURL: root).document(id: document.id))
        XCTAssertEqual(reopened.speakerName(for: reopened.segments[1]), originalName)
        XCTAssertEqual(reopened.title, "Later title edit")
        XCTAssertEqual(reopened.segments[1].text, "Later transcript edit")
        XCTAssertTrue(undoManager.canRedo)
    }

    @MainActor
    private func blockManifest(
        for documentID: UUID, in library: LibraryStore, suffix: String
    ) throws -> URL {
        let folder = library.folder(for: documentID)
        let manifest = folder.appendingPathComponent("document.json")
        let backup = folder.appendingPathComponent("document-\(suffix).json")
        try FileManager.default.moveItem(at: manifest, to: backup)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        return backup
    }

    @MainActor
    private func unblockManifest(for documentID: UUID, in library: LibraryStore, backup: URL) throws {
        let manifest = library.folder(for: documentID).appendingPathComponent("document.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.removeItem(at: backup)
    }

    @MainActor
    private func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func speakerDocument() -> ScribeDocument {
        ScribeDocument(
            title: "Speaker edit",
            kind: .recording,
            status: .ready,
            tracks: [
                AudioTrack(source: .microphone, fileName: "mic.caf"),
                AudioTrack(source: .system, fileName: "remote.caf"),
            ],
            segments: [
                TranscriptSegment(start: 0, end: 1, text: "Hello", source: .microphone),
                TranscriptSegment(start: 1, end: 2, text: "Morning", source: .system, speaker: "Speaker 1"),
            ]
        )
    }
}
