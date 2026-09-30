import AVFoundation
import XCTest
@testable import Scribe

@MainActor
final class WatchFolderManagerTests: XCTestCase {
    private var watchDir: URL!
    private var libraryRoot: URL!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!

    override func setUp() {
        super.setUp()
        defaultsSuite = "WatchFolderManagerTests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: defaultsSuite)!
        watchDir = FileManager.default.temporaryDirectory.appendingPathComponent("kleio-watch-dir-" + UUID().uuidString)
        libraryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("kleio-watch-lib-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: watchDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        Importer.makeID = { UUID() }
        defaults.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: watchDir)
        try? FileManager.default.removeItem(at: libraryRoot)
        super.tearDown()
    }

    func testFailedScanLeavesFileUnmarkedAndSucceedsOnALaterScan() async throws {
        let library = LibraryStore(baseURL: libraryRoot)
        let queue = makeQueue(library: library)
        let manager = WatchFolderManager(defaults: defaults)

        // Adding the folder while empty establishes the baseline; the file
        // written afterward is a "later addition" the manager should notice.
        manager.addFolder(watchDir)
        let mediaURL = watchDir.appendingPathComponent("episode.wav")
        try writeAudio(to: mediaURL)

        // A brand-new file needs its size
        // and modification time to be stable across two scans before the
        // manager attempts to import it, so this first pass just registers it.
        manager.configure(library: library, queue: queue, importer: Importer())
        await manager.scanNow()
        XCTAssertNil(library.documents.first)

        let fixedID = UUID()
        Importer.makeID = { fixedID }
        let folder = library.folder(for: fixedID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("document.json"), withIntermediateDirectories: false)

        // Second scan: the signature is now stable, so the manager attempts
        // the import, which fails because the manifest write is blocked.
        await manager.scanNow()
        XCTAssertNil(library.document(id: fixedID))
        XCTAssertNil(manager.lastImportedFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))

        // Third scan: the failed attempt's own cleanup already removed the
        // blocked folder, so this retry succeeds without any manual repair.
        await manager.scanNow()
        XCTAssertEqual(manager.lastImportedFile, "episode.wav")
        let saved = try XCTUnwrap(library.document(id: fixedID))
        XCTAssertEqual(saved.tracks.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("audio.wav").path))

        // Fourth scan: the file is now marked seen, so it must not be
        // reimported or recopied.
        await manager.scanNow()
        XCTAssertEqual(library.documents.count, 1)

        try await waitFor { !queue.isBusy }
        XCTAssertEqual(library.document(id: fixedID)?.status, .ready)
    }

    func testMoreThanFiveThousandExistingFilesStaySeenAcrossScansAndLaunches() async throws {
        for index in 0..<5_001 {
            let path = watchDir.appendingPathComponent("existing-\(index).wav").path
            XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data()))
        }
        let library = LibraryStore(baseURL: libraryRoot)
        let queue = makeQueue(library: library)
        let manager = WatchFolderManager(defaults: defaults)
        manager.addFolder(watchDir)
        manager.configure(library: library, queue: queue, importer: Importer())
        await manager.scanNow()
        await manager.scanNow()
        XCTAssertEqual(defaults.stringArray(forKey: "watchSeenSignatures")?.count, 5_001)
        XCTAssertTrue(library.documents.isEmpty)

        let reopened = WatchFolderManager(defaults: defaults)
        reopened.configure(library: library, queue: queue, importer: Importer())
        await reopened.scanNow()
        await reopened.scanNow()
        XCTAssertNil(reopened.lastImportedFile)
        XCTAssertTrue(library.documents.isEmpty)
    }

    func testUnavailableFolderKeepsConfigurationAndSeenHistoryUntilItReturns() async throws {
        let media = watchDir.appendingPathComponent("existing.wav")
        try writeAudio(to: media)
        let manager = WatchFolderManager(defaults: defaults)
        manager.addFolder(watchDir)
        let originalHistory = defaults.stringArray(forKey: "watchSeenSignatures")
        let unavailable = watchDir.appendingPathExtension("unavailable")
        try FileManager.default.moveItem(at: watchDir, to: unavailable)
        defer { try? FileManager.default.moveItem(at: unavailable, to: watchDir) }

        let library = LibraryStore(baseURL: libraryRoot)
        let queue = makeQueue(library: library)
        let reopened = WatchFolderManager(defaults: defaults)
        reopened.configure(library: library, queue: queue, importer: Importer())
        await reopened.scanNow()
        XCTAssertEqual(reopened.folders.count, 1)
        XCTAssertEqual(defaults.stringArray(forKey: "watchSeenSignatures"), originalHistory)

        try FileManager.default.moveItem(at: unavailable, to: watchDir)
        await reopened.scanNow()
        await reopened.scanNow()
        XCTAssertTrue(library.documents.isEmpty)
    }

    func testRemovedFilesLoseHistoryWhileRemainingFilesStaySeen() async throws {
        let first = watchDir.appendingPathComponent("first.wav")
        let second = watchDir.appendingPathComponent("second.wav")
        try writeAudio(to: first)
        try writeAudio(to: second)
        let manager = WatchFolderManager(defaults: defaults)
        manager.addFolder(watchDir)
        let library = LibraryStore(baseURL: libraryRoot)
        let queue = makeQueue(library: library)
        manager.configure(library: library, queue: queue, importer: Importer())
        try FileManager.default.removeItem(at: first)
        await manager.scanNow()
        XCTAssertEqual(defaults.stringArray(forKey: "watchSeenSignatures")?.count, 1)
        XCTAssertTrue(defaults.stringArray(forKey: "watchSeenSignatures")?.first?.hasPrefix(second.path + "|") == true)
    }

    func testNestedWatchedFoldersKeepIndependentHistoryWhenParentIsScannedOrRemoved() async throws {
        let child = watchDir.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try writeAudio(to: watchDir.appendingPathComponent("parent.wav"))
        try writeAudio(to: child.appendingPathComponent("child.wav"))
        let library = LibraryStore(baseURL: libraryRoot)
        let queue = makeQueue(library: library)
        let manager = WatchFolderManager(defaults: defaults)
        manager.addFolder(watchDir)
        manager.addFolder(child)
        manager.configure(library: library, queue: queue, importer: Importer())
        await manager.scanNow()
        await manager.scanNow()
        await manager.scanNow()
        XCTAssertTrue(library.documents.isEmpty)
        XCTAssertEqual(defaults.stringArray(forKey: "watchSeenSignatures")?.count, 2)
        let parent = try XCTUnwrap(manager.folders.first { $0.path == watchDir.path })
        manager.removeFolder(parent)
        await manager.scanNow()
        await manager.scanNow()
        XCTAssertTrue(library.documents.isEmpty)
        XCTAssertEqual(defaults.stringArray(forKey: "watchSeenSignatures")?.count, 1)
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
    throw NSError(domain: "WatchFolderManagerTests", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for controlled scan job completion."])
}
