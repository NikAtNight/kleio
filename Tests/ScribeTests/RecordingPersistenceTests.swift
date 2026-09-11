import XCTest
@testable import Scribe

final class RecordingPersistenceTests: XCTestCase {
    @MainActor
    func testFailedSaveDoesNotPublishUnpersistedDocument() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("occupied".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(baseURL: root)
        let document = ScribeDocument(title: "Meeting", kind: .recording, status: .recording)
        XCTAssertFalse(library.add(document))
        XCTAssertNil(library.document(id: document.id))
        XCTAssertNotNil(library.lastError)
    }
}

extension RecordingPersistenceTests {
    @MainActor
    func testActiveDocumentCannotBeDeletedUsingStaleReadyCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(baseURL: root)
        let active = ScribeDocument(title: "Meeting", kind: .recording, status: .recording)
        XCTAssertTrue(library.add(active))
        var stale = active
        stale.status = .ready
        XCTAssertFalse(library.delete(stale))
        XCTAssertNotNil(library.document(id: active.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.folder(for: active.id).appendingPathComponent("document.json").path))
    }
}

extension RecordingPersistenceTests {
    @MainActor
    func testStartWithUnwritableManifestNeverEntersRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("occupied".utf8).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(baseURL: root)
        let session = RecordingSession()
        // System-only setup reaches manifest persistence before any permission or capture API.
        await session.start(mode: .systemOnly, library: library)
        XCTAssertFalse(session.isRecording)
        XCTAssertFalse(session.isStarting)
        XCTAssertNil(session.activeDocumentID)
        XCTAssertNotNil(session.lastError)
        XCTAssertTrue(library.documents.isEmpty)
    }

    @MainActor
    func testInterruptedEmptyCaptureKeepsItsManifestForRecovery() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = ScribeDocument(title: "Meeting", kind: .recording, status: .recording,
            tracks: [AudioTrack(source: .microphone, fileName: "microphone.caf")])
        XCTAssertTrue(LibraryStore(baseURL: root).add(document))
        let recovered = LibraryStore(baseURL: root)
        XCTAssertEqual(recovered.document(id: document.id)?.status, .recovered)
        XCTAssertEqual(recovered.document(id: document.id)?.tracks.count, 1)
        XCTAssertNotNil(recovered.document(id: document.id)?.failureReason)
    }
}

extension RecordingPersistenceTests {
    @MainActor
    func testOrphanMediaIsReportedAndPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let orphan = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        let media = orphan.appendingPathComponent("microphone.caf")
        try Data("synthetic placeholder".utf8).write(to: media)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(baseURL: root)
        XCTAssertNotNil(library.lastError)
        XCTAssertTrue(library.lastError?.contains(orphan.path) == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.path))
    }

    @MainActor
    func testInterruptedSpeakerAnalysisPreservesReadyTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var document = ScribeDocument(title: "Meeting", kind: .recording, status: .ready,
            segments: [TranscriptSegment(start: 0, end: 1, text: "Hello")])
        document.speakerAnalysisStatus = .running
        XCTAssertTrue(LibraryStore(baseURL: root).add(document))
        let recovered = try XCTUnwrap(LibraryStore(baseURL: root).document(id: document.id))
        XCTAssertEqual(recovered.status, .ready)
        XCTAssertEqual(recovered.segments, document.segments)
        XCTAssertEqual(recovered.speakerAnalysisStatus, .failed)
        XCTAssertNotNil(recovered.speakerAnalysisError)
    }
}

extension RecordingPersistenceTests {
    @MainActor
    func testFailedFinalSaveIsRecoverableAndCanBeRetried() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = LibraryStore(baseURL: root)
        let active = ScribeDocument(title: "Meeting", kind: .recording, status: .recording)
        XCTAssertTrue(library.add(active))
        let manifest = library.folder(for: active.id).appendingPathComponent("document.json")
        let original = library.folder(for: active.id).appendingPathComponent("original.json")
        try FileManager.default.moveItem(at: manifest, to: original)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        var final = active
        final.status = .queued
        final.duration = 5
        XCTAssertFalse(library.finalizeRecording(final))
        let visible = try XCTUnwrap(library.document(id: active.id))
        XCTAssertEqual(visible.status, .recovered)
        XCTAssertEqual(visible.duration, 5)
        XCTAssertNotNil(visible.failureReason)
        XCTAssertFalse(library.delete(visible))
        XCTAssertFalse(library.delete(final))
        try FileManager.default.removeItem(at: manifest)
        XCTAssertTrue(library.finalizeRecording(final))
        XCTAssertEqual(LibraryStore(baseURL: root).document(id: final.id)?.duration, 5)
        XCTAssertTrue(library.delete(final))
    }
}

extension RecordingPersistenceTests {
    @MainActor
    func testRestartShowsRecoveredStateWhenManifestCannotBeUpdated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let active = ScribeDocument(title: "Interrupted meeting", kind: .recording, status: .recording)
        var analyzing = ScribeDocument(title: "Interrupted analysis", kind: .recording, status: .ready)
        analyzing.speakerAnalysisStatus = .running
        let initial = LibraryStore(baseURL: root)
        XCTAssertTrue(initial.add(active))
        XCTAssertTrue(initial.add(analyzing))
        let folders = [initial.folder(for: active.id), initial.folder(for: analyzing.id)]
        defer {
            for folder in folders { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
            try? FileManager.default.removeItem(at: root)
        }
        for folder in folders { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path) }
        let recovered = LibraryStore(baseURL: root)
        XCTAssertEqual(recovered.document(id: active.id)?.status, .recovered)
        XCTAssertEqual(recovered.document(id: analyzing.id)?.status, .ready)
        XCTAssertEqual(recovered.document(id: analyzing.id)?.speakerAnalysisStatus, .failed)
        XCTAssertNotNil(recovered.lastError)
        for folder in folders { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        let document = try XCTUnwrap(recovered.document(id: active.id))
        XCTAssertTrue(recovered.update(document))
        XCTAssertEqual(LibraryStore(baseURL: root).document(id: active.id)?.status, .recovered)
    }
}
