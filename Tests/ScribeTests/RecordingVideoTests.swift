import AVFoundation
import AppKit
import Darwin
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

    func testFinalizingVeryShortVideoTwiceReturnsTheSavedDuration() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = RecordingClock(start: 100)
        let writer = try TimelineVideoWriter(url: url, width: 32, height: 32, clock: clock)
        XCTAssertTrue(try writer.append(frame(at: 100)))
        clock.stop(at: 100.001)
        let firstDuration = try await writer.finish()
        let repeatedDuration = try await writer.finish()
        let savedDuration = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertEqual(repeatedDuration, firstDuration)
        XCTAssertEqual(firstDuration, savedDuration, accuracy: 0.001)
    }

    func testInterruptedVideoRetainsClosedFragments() async throws {
        if let output = ProcessInfo.processInfo.environment["SCRIBE_CAPTURE_CRASH_OUTPUT"] {
            let clock = RecordingClock(start: 100)
            let writer = try TimelineVideoWriter(url: URL(fileURLWithPath: output), width: 32, height: 32, clock: clock)
            for index in 0..<60 {
                let sample = try frame(at: 100 + Double(index) / 30)
                var attempts = 0
                while !(try writer.append(sample)) {
                    attempts += 1
                    guard attempts < 200 else { _exit(2) }
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
            }
            try await Task.sleep(nanoseconds: 300_000_000)
            // Exit only the dedicated fixture process, without finishing or deinitializing its writer.
            _exit(0)
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "ScribeTests.RecordingVideoTests/testInterruptedVideoRetainsClosedFragments",
            Bundle(for: Self.self).bundleURL.path]
        child.environment = ["SCRIBE_CAPTURE_CRASH_OUTPUT": url.path]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        let deadline = Date().addingTimeInterval(8)
        while child.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        if child.isRunning {
            kill(child.processIdentifier, SIGKILL)
            child.waitUntilExit()
            XCTFail("The synthetic movie process did not exit within eight seconds.")
            return
        }
        XCTAssertEqual(child.terminationStatus, 0)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            if sample.imageBuffer != nil { frames += 1 }
        }
        XCTAssertGreaterThanOrEqual(frames, 25)
        XCTAssertEqual(reader.status, .completed)
    }

    @MainActor
    func testComposedAudioVideoAndNoteStayAlignedAfterPause() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = RecordingClock(start: 100)
        let format = AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1)!
        let mic = try TimelineAudioWriter(url: folder.appendingPathComponent("mic.caf"), format: format, clock: clock)
        let remote = try TimelineAudioWriter(url: folder.appendingPathComponent("remote.caf"), format: format, clock: clock)
        let video = try TimelineVideoWriter(url: folder.appendingPathComponent("screen.mov"), width: 32, height: 32, clock: clock)
        let micBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 400)!
        let remoteBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 400)!
        micBuffer.frameLength = 400
        remoteBuffer.frameLength = 400
        for index in 0..<400 {
            micBuffer.floatChannelData![0][index] = 0.25
            remoteBuffer.floatChannelData![0][index] = 0.5
        }
        try mic.write(micBuffer, hostTime: 100.25)
        try remote.write(remoteBuffer, hostTime: 100.5)
        XCTAssertTrue(try video.append(frame(at: 100.25, color: (255, 0, 0))))
        clock.pause(at: 100.6)
        clock.resume(at: 101.6)
        try mic.write(micBuffer, hostTime: 101.75)
        try remote.write(remoteBuffer, hostTime: 101.9)
        XCTAssertTrue(try video.append(frame(at: 101.75, color: (0, 255, 0))))
        clock.stop(at: 102)
        mic.finish()
        remote.finish()
        let videoDuration = try await video.finish()
        var doc = ScribeDocument(title: "Synthetic meeting", kind: .recording, status: .ready)
        doc.tracks = [AudioTrack(source: .microphone, fileName: "mic.caf"), AudioTrack(source: .system, fileName: "remote.caf")]
        doc.videoTracks = [VideoTrack(fileName: "screen.mov", startOffset: try XCTUnwrap(video.startOffset), duration: videoDuration)]
        doc.notes = [MeetingNote(time: 0.76, text: "Synthetic note after resume")]
        let playback = PlaybackController()
        await playback.load(document: doc, folder: folder)
        defer { playback.unload() }
        XCTAssertNil(playback.lastError)
        XCTAssertEqual(playback.duration, 1, accuracy: 0.001)
        let asset = try XCTUnwrap(playback.player?.currentItem?.asset)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 8_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var mixed = [Float](repeating: 0, count: 8_000)
        while let sample = output.copyNextSampleBuffer() {
            guard sample.numSamples > 0, sample.presentationTimeStamp.seconds.isFinite,
                  let data = sample.dataBuffer else { continue }
            var chunk = [Float](repeating: 0, count: sample.numSamples)
            let status = chunk.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            XCTAssertEqual(status, noErr)
            let first = Int((sample.presentationTimeStamp.seconds * 8_000).rounded())
            for index in chunk.indices where mixed.indices.contains(first + index) { mixed[first + index] = chunk[index] }
        }
        XCTAssertEqual(reader.status, .completed)
        for (time, amplitude): (Double, Float) in [(0.1, 0), (0.26, 0.25), (0.51, 0.5), (0.65, 0), (0.76, 0.25), (0.91, 0.5)] {
            XCTAssertEqual(mixed[Int(time * 8_000)], amplitude, accuracy: 0.001)
        }
        playback.seek(to: try XCTUnwrap(doc.notes?.first).time)
        XCTAssertEqual(playback.currentTime, 0.76)
        let images = AVAssetImageGenerator(asset: asset)
        images.requestedTimeToleranceBefore = .zero
        images.requestedTimeToleranceAfter = .zero
        let before = try await images.image(at: CMTime(seconds: 0.3, preferredTimescale: 600))
        let after = try await images.image(at: CMTime(seconds: 0.8, preferredTimescale: 600))
        let blue = try XCTUnwrap(NSBitmapImageRep(cgImage: before.image).colorAt(x: 8, y: 8)?.usingColorSpace(.deviceRGB))
        let green = try XCTUnwrap(NSBitmapImageRep(cgImage: after.image).colorAt(x: 8, y: 8)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(blue.blueComponent, blue.greenComponent)
        XCTAssertGreaterThan(green.greenComponent, green.blueComponent)
    }

    private func frame(at time: TimeInterval, color: (blue: UInt8, green: UInt8, red: UInt8) = (0, 0, 0)) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let image = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(image, [])
        let bytes = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
        for row in 0..<32 {
            for column in 0..<32 {
                let index = row * CVPixelBufferGetBytesPerRow(image) + column * 4
                bytes[index] = color.blue
                bytes[index + 1] = color.green
                bytes[index + 2] = color.red
                bytes[index + 3] = 255
            }
        }
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
