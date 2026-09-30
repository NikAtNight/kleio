import AVFoundation
import XCTest
@testable import Scribe

@MainActor
final class ImporterTests: XCTestCase {
    private var libraryRoot: URL!
    private var sourceRoot: URL!

    override func setUp() {
        super.setUp()
        libraryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("kleio-importer-lib-" + UUID().uuidString)
        sourceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("kleio-importer-src-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        Importer.makeID = { UUID() }
        try? FileManager.default.removeItem(at: libraryRoot)
        try? FileManager.default.removeItem(at: sourceRoot)
        super.tearDown()
    }

    func testBatchReportsFailedFileAndKeepsSuccessfulImport() async throws {
        let library = LibraryStore(baseURL: libraryRoot)
        let queue = makeQueue(library: library)
        let source = sourceRoot.appendingPathComponent("good.wav")
        try writeAudio(to: source)
        let importer = Importer()
        let ids = await importer.importFiles([sourceRoot.appendingPathComponent("missing.wav"), source],
                                             library: library, queue: queue)
        XCTAssertEqual(ids.count, 1)
        XCTAssertEqual(importer.errors.count, 1)
        XCTAssertTrue(importer.errors[0].contains("missing.wav"))
        XCTAssertEqual(importer.completedFiles, 2)
        XCTAssertEqual(importer.totalFiles, 2)
        XCTAssertFalse(importer.isBusy)
        try await waitFor { !queue.isBusy }
        XCTAssertEqual(library.document(id: ids[0])?.status, .ready)
    }

    func testQuitWaitsForAcceptedImportAndBlocksNewImports() async throws {
        let library = LibraryStore(baseURL: libraryRoot)
        let queue = makeQueue(library: library)
        let gate = ImportGate()
        let importer = Importer(copyMedia: { _, _ in
            await gate.wait()
            throw CocoaError(.fileReadNoSuchFile)
        })
        let operation = Task {
            await importer.importFiles([sourceRoot.appendingPathComponent("waiting.wav")], library: library, queue: queue)
        }
        try await waitFor { await gate.isWaiting }
        XCTAssertTrue(importer.isBusy)
        var quitFinished = false
        let quit = Task { await importer.prepareToQuit(); quitFinished = true }
        try await waitFor { !importer.canImport }
        XCTAssertFalse(quitFinished)
        let refused = await importer.importFiles([sourceRoot.appendingPathComponent("another.wav")], library: library, queue: queue)
        XCTAssertTrue(refused.isEmpty)
        XCTAssertEqual(importer.totalFiles, 1)
        await gate.release()
        _ = await operation.value
        await quit.value
        XCTAssertTrue(quitFinished)
        XCTAssertFalse(importer.isBusy)
        importer.resumeAfterCancelledQuit()
        XCTAssertTrue(importer.canImport)
    }

    func testBackupBlocksImportBeforeAnyFileWork() async throws {
        let library = LibraryStore(baseURL: libraryRoot)
        let queue = makeQueue(library: library)
        let importer = Importer(copyMedia: { _, _ in XCTFail("Blocked import must not copy media"); return 0 })
        importer.startBlocked = { true }
        let ids = await importer.importFiles([sourceRoot.appendingPathComponent("blocked.wav")], library: library, queue: queue)
        XCTAssertTrue(ids.isEmpty)
        XCTAssertFalse(importer.isBusy)
        XCTAssertEqual(importer.totalFiles, 0)
        XCTAssertTrue(library.documents.isEmpty)
        XCTAssertEqual(importer.errors.count, 1)
    }

    func testImportUsesInjectedLibraryFolderNotDefaultLibrary() async throws {
        let library = LibraryStore(baseURL: libraryRoot)
        let queue = makeQueue(library: library)
        let sourceURL = sourceRoot.appendingPathComponent("meeting.wav")
        try writeAudio(to: sourceURL)

        let ids = await Importer().importFiles([sourceURL], library: library, queue: queue)
        XCTAssertEqual(ids.count, 1)
        let id = try XCTUnwrap(ids.first)

        let injectedMedia = library.folder(for: id).appendingPathComponent("audio.wav")
        XCTAssertTrue(FileManager.default.fileExists(atPath: injectedMedia.path))

        // The bug this guards against wrote into the default Application Support
        // path regardless of which library was injected.
        let defaultMedia = LibraryStore.folder(for: id).appendingPathComponent("audio.wav")
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultMedia.path))

        try await waitFor { !queue.isBusy }
        XCTAssertEqual(library.document(id: id)?.status, .ready)
    }

    func testFailedManifestSaveReturnsNoIdLeavesNoMediaAndEnqueuesNothing() async throws {
        let library = LibraryStore(baseURL: libraryRoot)
        let queue = makeQueue(library: library)
        let fixedID = UUID()
        Importer.makeID = { fixedID }

        // Force the manifest write inside library.add to fail while still
        // letting the earlier media copy succeed, by pre-occupying
        // document.json with a directory.
        let folder = library.folder(for: fixedID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("document.json"), withIntermediateDirectories: false)

        let sourceURL = sourceRoot.appendingPathComponent("broken.wav")
        try writeAudio(to: sourceURL)

        let ids = await Importer().importFiles([sourceURL], library: library, queue: queue)

        XCTAssertTrue(ids.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertNil(library.document(id: fixedID))
        XCTAssertEqual(queue.pendingCount, 0)
        XCTAssertNil(queue.currentDocumentID)
    }

    func testImportPodcastCreatesOneDocumentWithAlignedTracks() async throws {
        let library = LibraryStore(baseURL: libraryRoot)
        let queue = makeQueue(library: library)
        let podcastDir = sourceRoot.appendingPathComponent("Interview", isDirectory: true)
        try FileManager.default.createDirectory(at: podcastDir, withIntermediateDirectories: true)
        let hostURL = podcastDir.appendingPathComponent("Host.wav")
        let guestURL = podcastDir.appendingPathComponent("Guest.wav")
        try writeAudio(to: hostURL)
        try writeAudio(to: guestURL)

        let importedID = await Importer().importPodcast([hostURL, guestURL], library: library, queue: queue)
        let id = try XCTUnwrap(importedID)

        let folder = library.folder(for: id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("track-1.wav").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("track-2.wav").path))
        XCTAssertEqual(library.document(id: id)?.tracks.count, 2)
        XCTAssertEqual(library.document(id: id)?.knownSpeakers, ["Host", "Guest"])

        try await waitFor { !queue.isBusy }
        XCTAssertEqual(library.document(id: id)?.status, .ready)
    }

    func testImportPodcastSaveFailureLeavesNoMediaAndReturnsNil() async throws {
        let library = LibraryStore(baseURL: libraryRoot)
        let queue = makeQueue(library: library)
        let fixedID = UUID()
        Importer.makeID = { fixedID }

        let folder = library.folder(for: fixedID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("document.json"), withIntermediateDirectories: false)

        let podcastDir = sourceRoot.appendingPathComponent("Interview", isDirectory: true)
        try FileManager.default.createDirectory(at: podcastDir, withIntermediateDirectories: true)
        let hostURL = podcastDir.appendingPathComponent("Host.wav")
        try writeAudio(to: hostURL)

        let id = await Importer().importPodcast([hostURL], library: library, queue: queue)

        XCTAssertNil(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertNil(library.document(id: fixedID))
        XCTAssertEqual(queue.pendingCount, 0)
        XCTAssertNil(queue.currentDocumentID)
    }

    private func makeQueue(library: LibraryStore) -> TranscriptionQueue {
        let queue = TranscriptionQueue(
            transcriber: StubTranscriptionEngine(),
            inferSpeakers: { _, _, _ in SpeakerDiarization(intervals: [], voiceprints: [:], speakerLabels: [:]) },
            exportAutomatically: { _ in }
        )
        queue.configure(library: library, options: { .init(model: "fixture") })
        return queue
    }

    private func writeAudio(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)!
        buffer.frameLength = 1_600
        buffer.floatChannelData![0].initialize(repeating: 0.1, count: 1_600)
        try file.write(from: buffer)
    }
}

private actor ImportGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false
    func wait() async {
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor StubTranscriptionEngine: TranscriptionEngine {
    func load(model: String) async throws {}
    nonisolated func cancelCurrent() {}
    func transcribe(file: URL, source: AudioSource, language: String?, translate: Bool,
                    onProgress: (@Sendable (Double, String) -> Void)?) async throws -> [TranscriptSegment] {
        [TranscriptSegment(start: 0, end: 1, text: "Decoded words.", source: source)]
    }
}

@MainActor
private func waitFor(_ predicate: () async -> Bool) async throws {
    for _ in 0..<2_000 {
        if await predicate() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw NSError(domain: "ImporterTests", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for controlled import job completion."])
}
