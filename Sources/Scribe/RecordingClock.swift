import Foundation
import AVFoundation

/// Maps host-clock timestamps onto a session timeline with explicit pauses removed.
/// Audio, video, and the UI read the same clock, including after device interruptions.
final class RecordingClock: @unchecked Sendable {
    static var now: TimeInterval { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
    private let lock = NSLock()
    private let start: TimeInterval
    private var pauses: [(start: TimeInterval, end: TimeInterval?)] = []
    private var stoppedAt: TimeInterval?

    init(start: TimeInterval = RecordingClock.now) { self.start = start }

    func pause(at hostTime: TimeInterval = RecordingClock.now) {
        lock.lock(); defer { lock.unlock() }
        guard pauses.last?.end != nil || pauses.isEmpty else { return }
        pauses.append((hostTime, nil))
    }

    func resume(at hostTime: TimeInterval = RecordingClock.now) {
        lock.lock(); defer { lock.unlock() }
        guard !pauses.isEmpty, pauses[pauses.count - 1].end == nil else { return }
        pauses[pauses.count - 1].end = hostTime
    }

    func stop(at hostTime: TimeInterval = RecordingClock.now) {
        lock.lock(); defer { lock.unlock() }
        if stoppedAt == nil { stoppedAt = hostTime }
    }

    func time(at hostTime: TimeInterval = RecordingClock.now) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return elapsed(at: min(hostTime, stoppedAt ?? hostTime))
    }

    func captureTime(at hostTime: TimeInterval) -> TimeInterval? {
        captureRange(at: hostTime, duration: 0)?.start
    }

    func captureRange(at hostTime: TimeInterval, duration: TimeInterval) -> (start: TimeInterval, duration: TimeInterval)? {
        lock.lock(); defer { lock.unlock() }
        guard hostTime.isFinite, hostTime >= start, hostTime < (stoppedAt ?? .infinity),
              !pauses.contains(where: { hostTime >= $0.start && hostTime < ($0.end ?? .infinity) }) else { return nil }
        let boundary = min(stoppedAt ?? .infinity, pauses.first(where: { $0.start > hostTime })?.start ?? .infinity)
        return (elapsed(at: hostTime), max(0, min(duration, boundary - hostTime)))
    }

    private func elapsed(at hostTime: TimeInterval) -> TimeInterval {
        let removed = pauses.reduce(0) { $0 + max(0, min(hostTime, $1.end ?? hostTime) - $1.start) }
        return max(0, hostTime - start - removed)
    }
}

/// Serial-queue writer that preserves gaps as silence instead of moving later speech earlier.
/// Both microphone and app capture use this durability and alignment boundary.
final class TimelineAudioWriter {
    private var file: AVAudioFile?
    private let clock: RecordingClock

    init(url: URL, format: AVAudioFormat, clock: RecordingClock) throws {
        file = try AVAudioFile(forWriting: url, settings: format.settings,
            commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)
        self.clock = clock
    }

    func write(_ buffer: AVAudioPCMBuffer, hostTime: TimeInterval) throws {
        guard let file, let range = clock.captureRange(at: hostTime,
            duration: Double(buffer.frameLength) / buffer.format.sampleRate) else { return }
        let rate = buffer.format.sampleRate
        let destination = AVAudioFramePosition((range.start * rate).rounded())
        let length = min(Int(buffer.frameLength), Int((range.duration * rate).rounded()))
        let overlap = Int(max(0, file.length - destination))
        guard length > overlap else { return }
        // Bound scratch memory even when a disconnected device returns much later.
        if destination > file.length {
            let silence = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: 4096)!
            silence.frameLength = silence.frameCapacity
            for audioBuffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                if let data = audioBuffer.mData { memset(data, 0, Int(audioBuffer.mDataByteSize)) }
            }
            while file.length < destination {
                silence.frameLength = AVAudioFrameCount(min(4096, destination - file.length))
                try file.write(from: silence)
            }
        }
        if overlap == 0 && length == buffer.frameLength {
            try file.write(from: buffer)
        } else {
            let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(length - overlap))!
            copy.frameLength = copy.frameCapacity
            let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
            for index in target.indices {
                memcpy(target[index].mData!, source[index].mData!.advanced(by: overlap * bytesPerFrame), (length - overlap) * bytesPerFrame)
            }
            try file.write(from: copy)
        }
    }

    func finish() { file = nil }
}
