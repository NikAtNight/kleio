import Foundation
import XCTest
@testable import Scribe

final class ExporterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ExporterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testAutomaticExportPreservesUserSidecarAndOccupiedFallback() throws {
        let doc = document(text: "New transcript")
        let original = directory.appendingPathComponent("Meeting.txt")
        let fallback = directory.appendingPathComponent("Meeting-\(doc.id.uuidString).txt")
        try Data("User sidecar".utf8).write(to: original)
        try Data("Older export".utf8).write(to: fallback)

        try Exporter.exportAutomaticallyIfNeeded(doc)

        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "User sidecar")
        XCTAssertEqual(try String(contentsOf: fallback, encoding: .utf8), "Older export")
        XCTAssertEqual(try exportedContents().sorted(), ["User sidecar", "Older export", Exporter.render(doc, as: .txt)].sorted())
    }

    func testDocumentsWithTheSameTitleBothKeepTheirExports() throws {
        let first = document(text: "First recording")
        let second = document(text: "Second recording")

        try Exporter.exportAutomaticallyIfNeeded(first)
        try Exporter.exportAutomaticallyIfNeeded(second)

        XCTAssertEqual(try exportedContents().sorted(), [Exporter.render(first, as: .txt), Exporter.render(second, as: .txt)].sorted())
    }

    func testRepeatedExportsKeepEarlierDocumentVersions() throws {
        var doc = document(text: "Original transcript")
        let original = Exporter.render(doc, as: .txt)
        try Exporter.exportAutomaticallyIfNeeded(doc)
        doc.segments[0].text = "Revised transcript"
        try Exporter.exportAutomaticallyIfNeeded(doc)
        doc.segments[0].text = "Final transcript"
        try Exporter.exportAutomaticallyIfNeeded(doc)

        XCTAssertEqual(try exportedContents().sorted(), [original, "[0:00] Revised transcript", "[0:00] Final transcript"].sorted())
    }

    func testConcurrentExportsNeverOverwriteAnotherWriter() throws {
        let documents = (0..<8).map { document(text: "Recording \($0)") }
        let lock = NSLock()
        var failures: [Error] = []
        DispatchQueue.concurrentPerform(iterations: documents.count) { index in
            do {
                try Exporter.exportAutomaticallyIfNeeded(documents[index])
            } catch {
                lock.lock()
                failures.append(error)
                lock.unlock()
            }
        }

        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertEqual(try exportedContents().sorted(), documents.map { Exporter.render($0, as: .txt) }.sorted())
    }

    func testExistingSymlinkAndItsTargetRemainUntouched() throws {
        let target = directory.appendingPathComponent("UserNotes.txt")
        let sidecar = directory.appendingPathComponent("Meeting.txt")
        try Data("User notes".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: target)
        let doc = document(text: "Transcript")

        try Exporter.exportAutomaticallyIfNeeded(doc)

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "User notes")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: sidecar.path), target.path)
        XCTAssertEqual(try exportedContents().filter { $0 == Exporter.render(doc, as: .txt) }.count, 1)
    }

    func testAllFormatsExportOnceDespiteDuplicateConfiguration() throws {
        var doc = document(text: "Transcript")
        doc.automaticExportFormats = ExportFormat.allCases.map(\.rawValue) + ["txt", "unknown"]

        try Exporter.exportAutomaticallyIfNeeded(doc)

        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, ExportFormat.allCases.count)
        for format in ExportFormat.allCases {
            let url = directory.appendingPathComponent("Meeting.\(format.rawValue)")
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), Exporter.render(doc, as: format))
        }
    }

    func testDirectoryFailureThrowsWithoutTouchingExistingFile() throws {
        let blocked = directory.appendingPathComponent("blocked")
        try Data("Keep this file".utf8).write(to: blocked)
        var doc = document(text: "Transcript")
        doc.automaticExportDirectory = blocked.path

        XCTAssertThrowsError(try Exporter.exportAutomaticallyIfNeeded(doc))
        XCTAssertEqual(try String(contentsOf: blocked, encoding: .utf8), "Keep this file")
    }

    func testMissingExportConfigurationDoesNotCreateDirectory() throws {
        let missing = directory.appendingPathComponent("unused")
        var doc = document(text: "Transcript")
        doc.automaticExportDirectory = missing.path
        doc.automaticExportFormats = []

        try Exporter.exportAutomaticallyIfNeeded(doc)

        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    private func document(text: String) -> ScribeDocument {
        ScribeDocument(title: "Meeting", kind: .imported, status: .ready,
                       segments: [TranscriptSegment(start: 0, end: 1, text: text)],
                       automaticExportDirectory: directory.path, automaticExportFormats: ["txt"])
    }

    private func exportedContents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .map { try String(contentsOf: $0, encoding: .utf8) }
    }
}
