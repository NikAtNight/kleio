import AVFoundation
import Foundation
import XCTest
@testable import Scribe

final class RecoveredTranscriptionTests: XCTestCase {
    func testRecoveredMeetingTranscribesSurvivingSourceWithoutRemovingTrackMetadata() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeAudio(to: folder.appendingPathComponent("call.caf"))
        let document = ScribeDocument(title: "Interrupted", kind: .recording, status: .queued, tracks: [
            AudioTrack(source: .microphone, fileName: "missing-mic.caf"),
            AudioTrack(source: .system, fileName: "call.caf", startOffset: 0.2),
        ], recoveredAt: Date())

        let inputs = try TranscriptionQueue.transcriptionInputs(for: document, folder: folder)

        XCTAssertEqual(inputs.tracks.map(\.source), [.system])
        XCTAssertEqual(inputs.tracks.first?.startOffset, 0.2)
        XCTAssertEqual(inputs.omitted.count, 1)
        XCTAssertTrue(inputs.omitted.first?.contains("Microphone") == true)
        XCTAssertTrue(inputs.omitted.first?.contains("missing-mic.caf") == true)
        XCTAssertEqual(document.tracks.count, 2)
    }

    func testRecoveredSourceWithCorruptAudioDoesNotBlockReadableMicrophone() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeAudio(to: folder.appendingPathComponent("mic.caf"))
        try Data("interrupted file".utf8).write(to: folder.appendingPathComponent("call.caf"))
        let document = ScribeDocument(title: "Interrupted", kind: .recording, status: .failed, tracks: [
            AudioTrack(source: .microphone, fileName: "mic.caf"),
            AudioTrack(source: .system, fileName: "call.caf"),
        ], recoveredAt: Date())

        let inputs = try TranscriptionQueue.transcriptionInputs(for: document, folder: folder)

        XCTAssertEqual(inputs.tracks.map(\.source), [.microphone])
        XCTAssertEqual(inputs.omitted, ["App audio (call.caf)"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("call.caf").path))
    }

    func testOrdinaryImportNeverSilentlySkipsAMissingTrack() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeAudio(to: folder.appendingPathComponent("host.caf"))
        let document = ScribeDocument(title: "Podcast", kind: .imported, status: .queued, tracks: [
            AudioTrack(source: .imported, fileName: "host.caf", speakerName: "Host"),
            AudioTrack(source: .imported, fileName: "guest.caf", speakerName: "Guest"),
        ])

        XCTAssertThrowsError(try TranscriptionQueue.transcriptionInputs(for: document, folder: folder)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Guest (guest.caf)"))
            XCTAssertTrue(error.localizedDescription.contains("Restore these files"))
        }
    }

    func testRecoveredRecordingWithNoUsableAudioFailsBeforeModelLoading() {
        let document = ScribeDocument(title: "Interrupted", kind: .recording, status: .queued, tracks: [
            AudioTrack(source: .microphone, fileName: "missing.caf"),
        ], recoveredAt: Date())

        XCTAssertThrowsError(try TranscriptionQueue.transcriptionInputs(for: document,
                                                                         folder: URL(fileURLWithPath: "/missing"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("No usable audio remains"))
            XCTAssertTrue(error.localizedDescription.contains("Microphone (missing.caf)"))
        }
    }

    private func writeAudio(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        for index in 0..<160 { buffer.floatChannelData![0][index] = 0.05 }
        try file.write(from: buffer)
    }
}
