import AVFoundation
import XCTest
@testable import Scribe

@MainActor
final class WatchFolderManagerTests: XCTestCase {
    private var watchDir: URL!
    private var libraryRoot: URL!
    private let defaultsKeys = ["watchAutoTranscribe", "watchAutoExport", "watchExportFormats",
                                "watchedFolders", "watchSeenSignatures"]
    private var savedDefaults: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        savedDefaults = [:]
        for key in defaultsKeys {
            if let value = UserDefaults.standard.object(forKey: key) {
                savedDefaults[key] = value
            }
        }
        watchDir = FileManager.default.temporaryDirectory.appendingPathComponent("kleio-watch-dir-" + UUID().uuidString)
        libraryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("kleio-watch-lib-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: watchDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        Importer.makeID = { UUID() }
        for key in defaultsKeys {
            if let value = savedDefaults[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        try? FileManager.default.removeItem(at: watchDir)
        try? FileManager.default.removeItem(at: libraryRoot)
        super.tearDown()
    }

    func testFailedScanLeavesFileUnmarkedAndSucceedsOnALaterScan() async throws {
        let library = LibraryStore(baseURL: libraryRoot)
        let queue = makeQueue(library: library)
        let manager = WatchFolderManager()

        // Adding the folder while empty establishes the baseline; the file
        // written afterward is a "later addition" the manager should notice.
        manager.addFolder(watchDir)
        let mediaURL = watchDir.appendingPathComponent("episode.wav")
        try writeAudio(to: mediaURL)

        // configure() runs an initial scan. A brand-new file needs its size
        // and modification time to be stable across two scans before the
        // manager attempts to import it, so this first pass just registers it.
        manager.configure(library: library, queue: queue)
        XCTAssertNil(library.documents.first)

        let fixedID = UUID()
        Importer.makeID = { fixedID }
        let folder = library.folder(for: fixedID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("document.json"), withIntermediateDirectories: false)

        // Second scan: the signature is now stable, so the manager attempts
        // the import, which fails because the manifest write is blocked.
        manager.scanNow()
        XCTAssertNil(library.document(id: fixedID))
        XCTAssertNil(manager.lastImportedFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))

        // Third scan: the failed attempt's own cleanup already removed the
        // blocked folder, so this retry succeeds without any manual repair.
        manager.scanNow()
        XCTAssertEqual(manager.lastImportedFile, "episode.wav")
        let saved = try XCTUnwrap(library.document(id: fixedID))
        XCTAssertEqual(saved.tracks.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("audio.wav").path))

        // Fourth scan: the file is now marked seen, so it must not be
        // reimported or recopied.
        manager.scanNow()
        XCTAssertEqual(library.documents.count, 1)

        try await waitFor { !queue.isBusy }
        XCTAssertEqual(library.document(id: fixedID)?.status, .ready)
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
