import AppKit
import AVFoundation
import ScreenCaptureKit

// The picker controls video only. Application audio remains the explicit shortcut target.
enum VideoCaptureMode: String, CaseIterable, Identifiable {
    case window, display
    var id: String { rawValue }
    var title: String { self == .window ? "Window" : "Display" }
}

@MainActor
final class ScreenCapturePicker: NSObject, SCContentSharingPickerObserver {
    private var continuation: CheckedContinuation<SCContentFilter, Error>?

    func select(_ mode: VideoCaptureMode) async throws -> SCContentFilter {
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = mode == .window ? .singleWindow : .singleDisplay
        configuration.allowsChangingSelectedContent = false
        if let id = Bundle.main.bundleIdentifier { configuration.excludedBundleIDs = [id] }
        picker.defaultConfiguration = configuration
        picker.add(self)
        picker.isActive = true
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            picker.present(using: mode == .window ? .window : .display)
        }
    }

    func cancel() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
        close()
    }

    func close() {
        SCContentSharingPicker.shared.remove(self)
        SCContentSharingPicker.shared.isActive = false
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor in self.cancel() }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            self.continuation?.resume(returning: filter)
            self.continuation = nil
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            self.continuation?.resume(throwing: error)
            self.continuation = nil
            self.close()
        }
    }
}

/// Native screen capture feeds a serial writer. The native picker owns permission selection.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private let sampleQueue = DispatchQueue(label: "Scribe.ScreenSamples", qos: .userInitiated)
    private var stream: SCStream?
    private var writer: TimelineVideoWriter?
    private var onError: (@Sendable (String) -> Void)?
    private var onFirstFrame: (@Sendable (TimeInterval) -> Void)?
    var startOffset: TimeInterval? { sampleQueue.sync { writer?.startOffset } }
    private var failure: Error?
    private var acceptingFrames = false

    func start(filter: SCContentFilter, writingTo url: URL, clock: RecordingClock,
               onError: @escaping @Sendable (String) -> Void,
               onFirstFrame: @escaping @Sendable (TimeInterval) -> Void) async throws {
        let configuration = SCStreamConfiguration()
        let pixelSize = CGSize(width: filter.contentRect.width * CGFloat(filter.pointPixelScale),
            height: filter.contentRect.height * CGFloat(filter.pointPixelScale))
        let scale = min(1, 1920 / max(1, max(pixelSize.width, pixelSize.height)))
        configuration.width = max(2, Int(pixelSize.width * scale) / 2 * 2)
        configuration.height = max(2, Int(pixelSize.height * scale) / 2 * 2)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.capturesAudio = false
        let writer = try TimelineVideoWriter(url: url, width: configuration.width, height: configuration.height, clock: clock)
        self.writer = writer
        self.onError = onError
        self.onFirstFrame = onFirstFrame
        acceptingFrames = true
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()
        } catch {
            sampleQueue.sync { acceptingFrames = false }
            _ = try? await writer.finish()
            self.stream = nil
            throw error
        }
    }

    func stop() async throws -> TimeInterval {
        if let stream {
            do { try await stream.stopCapture() }
            catch { sampleQueue.sync { if failure == nil { failure = error } } }
        }
        stream = nil
        let writer: TimelineVideoWriter? = sampleQueue.sync { acceptingFrames = false; return self.writer }
        guard let writer else { throw TimelineVideoWriter.CaptureError.noFrames }
        let duration = try await writer.finish()
        if let failure = sampleQueue.sync(execute: { self.failure }) { throw failure }
        return duration
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        sampleQueue.async { self.fail(error) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, acceptingFrames, failure == nil,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        do {
            if try writer?.append(sampleBuffer) == true, let offset = writer?.startOffset, let onFirstFrame {
                onFirstFrame(offset)
                self.onFirstFrame = nil
            }
        } catch { fail(error) }
    }

    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        onError?(error.localizedDescription)
    }
}

/// Writes fragmented H.264 movies with pauses removed and device delays preserved.
/// Append calls must be serial; finish runs only after the capture queue has drained.
final class TimelineVideoWriter {
    enum CaptureError: LocalizedError {
        case writer(String)
        case noFrames
        var errorDescription: String? {
            switch self {
            case .writer(let message): return "Video could not be saved. \(message)"
            case .noFrames: return "The selected screen or window did not deliver any video frames."
            }
        }
    }

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let clock: RecordingClock
    private var lastSample: CMSampleBuffer?
    private var backpressureStarted: TimeInterval?
    private var finished = false
    private var finalizedDuration: TimeInterval?
    private(set) var startOffset: TimeInterval?

    init(url: URL, width: Int, height: Int, clock: RecordingClock) throws {
        self.clock = clock
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000,
                AVVideoMaxKeyFrameIntervalKey: 60]
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw CaptureError.writer("Unsupported encoder configuration.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CaptureError.writer("Encoder did not start.") }
        writer.startSession(atSourceTime: .zero)
    }

    @discardableResult
    func append(_ sampleBuffer: CMSampleBuffer) throws -> Bool {
        guard !finished, sampleBuffer.isValid, sampleBuffer.imageBuffer != nil,
              let seconds = clock.captureTime(at: sampleBuffer.presentationTimeStamp.seconds) else { return false }
        let timestamp = CMTime(seconds: seconds - (startOffset ?? seconds), preferredTimescale: 60_000)
        guard lastSample.map({ timestamp > $0.presentationTimeStamp }) ?? true else { return false }
        guard input.isReadyForMoreMediaData else {
            if writer.status == .failed { throw writer.error ?? CaptureError.writer("Encoder stopped.") }
            if backpressureStarted == nil { backpressureStarted = RecordingClock.now }
            if RecordingClock.now - (backpressureStarted ?? 0) > 5 {
                throw CaptureError.writer("Encoder has stopped accepting video frames.")
            }
            return false
        }
        backpressureStarted = nil
        let sample = try Self.retime(sampleBuffer, to: timestamp)
        guard input.append(sample) else { throw writer.error ?? CaptureError.writer("Encoder rejected a frame.") }
        lastSample = sample
        if startOffset == nil { startOffset = seconds }
        return true
    }

    func finish() async throws -> TimeInterval {
        if finished {
            guard writer.status == .completed, let finalizedDuration else { throw writer.error ?? CaptureError.noFrames }
            return finalizedDuration
        }
        finished = true
        guard let lastSample else { writer.cancelWriting(); throw CaptureError.noFrames }
        let duration = max(clock.time() - (startOffset ?? 0), lastSample.presentationTimeStamp.seconds + 1 / 30)
        finalizedDuration = duration
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 60_000))
        input.markAsFinished()
        if writer.status == .writing { await writer.finishWriting() }
        guard writer.status == .completed else { throw writer.error ?? CaptureError.noFrames }
        return duration
    }

    private static func retime(_ sample: CMSampleBuffer, to timestamp: CMTime) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: timestamp, decodeTimeStamp: .invalid)
        var retimed: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &retimed)
        guard status == noErr, let retimed else { throw CaptureError.writer("Frame timing could not be stored.") }
        return retimed
    }
}
