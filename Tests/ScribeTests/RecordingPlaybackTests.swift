import AVFoundation
import XCTest
@testable import Scribe

final class RecordingPlaybackTests: XCTestCase {
    @MainActor
    func testPlaybackHonorsTrackOffsetsAndReportsMissingMedia() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
        buffer.frameLength = 8_000
        for frame in 0..<8_000 { buffer.floatChannelData![0][frame] = 0.25 }
        do {
            let file = try AVAudioFile(forWriting: folder.appendingPathComponent("remote.caf"), settings: format.settings)
            try file.write(from: buffer)
        }
        var doc = ScribeDocument(title: "Meeting", kind: .recording, status: .ready)
        doc.tracks = [AudioTrack(source: .system, fileName: "remote.caf", startOffset: 2),
            AudioTrack(source: .microphone, fileName: "missing.caf")]
        let playback = PlaybackController()
        await playback.load(document: doc, folder: folder)
        XCTAssertNotNil(playback.player)
        XCTAssertEqual(playback.duration, 3, accuracy: 0.01)
        XCTAssertNotNil(playback.lastError)
        playback.seek(to: 2.5)
        XCTAssertEqual(playback.currentTime, 2.5)
        playback.unload()
    }
}
