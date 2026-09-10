import AVFoundation
import XCTest
@testable import Scribe

final class RecordingVideoTests: XCTestCase {
    @MainActor
    func testVideoRetainsInitialOffsetAndHoldsLastFrameUntilStop() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = RecordingClock(start: 100)
        let writer = try TimelineVideoWriter(url: url, width: 32, height: 32, clock: clock)
        let sample = try frame(at: 100.5)
        XCTAssertTrue(try writer.append(sample))
        clock.stop(at: 103)
        let duration = try await writer.finish()
        XCTAssertEqual(writer.startOffset, 0.5)
        XCTAssertEqual(duration, 2.5)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let range = try await track.load(.timeRange)
        // The stored offset supplies the leading gap when playback composes this movie.
        XCTAssertEqual(range.start.seconds, 0, accuracy: 0.04)
        XCTAssertEqual(range.end.seconds, 2.5, accuracy: 0.04)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var firstFrame: CMSampleBuffer?
        while let sample = output.copyNextSampleBuffer() {
            if sample.totalSampleSize > 0 { firstFrame = sample; break }
        }
        XCTAssertEqual(try XCTUnwrap(firstFrame).presentationTimeStamp.seconds, 0, accuracy: 0.04)
        var document = ScribeDocument(title: "Synthetic video", kind: .recording, status: .ready)
        document.videoTracks = [VideoTrack(fileName: url.lastPathComponent,
            startOffset: try XCTUnwrap(writer.startOffset), duration: duration)]
        let playback = PlaybackController()
        await playback.load(document: document, folder: url.deletingLastPathComponent())
        XCTAssertNotNil(playback.player)
        XCTAssertNil(playback.lastError)
        XCTAssertEqual(playback.duration, 3, accuracy: 0.04)
        playback.unload()
    }

    func testVideoDropsPausedFramesAndRemovesPauseFromEncodedTimestamps() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = RecordingClock(start: 100)
        let writer = try TimelineVideoWriter(url: url, width: 32, height: 32, clock: clock)
        XCTAssertTrue(try writer.append(frame(at: 100)))
        clock.pause(at: 100.1)
        clock.resume(at: 110.1)
        XCTAssertFalse(try writer.append(frame(at: 105)))
        XCTAssertTrue(try writer.append(frame(at: 110.3)))
        clock.stop(at: 110.5)
        _ = try await writer.finish()
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var timestamps: [TimeInterval] = []
        while let sample = output.copyNextSampleBuffer() {
            if sample.totalSampleSize > 0 { timestamps.append(sample.presentationTimeStamp.seconds) }
        }
        XCTAssertEqual(timestamps.count, 2)
        XCTAssertEqual(timestamps.sorted().last ?? -1, 0.3, accuracy: 0.04)
    }

    private func frame(at time: TimeInterval) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let image = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(image, [])
        memset(CVPixelBufferGetBaseAddress(image), 0, CVPixelBufferGetDataSize(image))
        CVPixelBufferUnlockBaseAddress(image, [])
        var description: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: image, formatDescriptionOut: &description), noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 60_000), decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: image, formatDescription: try XCTUnwrap(description), sampleTiming: &timing,
            sampleBufferOut: &buffer), noErr)
        return try XCTUnwrap(buffer)
    }
}
