import AVFoundation
import Foundation

enum MeetingMuteState: Equatable, Sendable {
    case muted
    case unmuted
    case unavailable(String)
}

/// Retains a short microphone delay and admits only complete frames between
/// adjacent, fresh unmuted observations from the same meeting context.
final class MeetingMicrophoneGate: @unchecked Sendable {
    struct Output {
        let buffer: AVAudioPCMBuffer
        let hostTime: TimeInterval
    }

    static let maximumObservationGap: TimeInterval = 0.5
    static let bufferDelay: TimeInterval = 0.75
    private static let historyDuration: TimeInterval = 2
    private static let maximumEntries = 128
    private let lock = NSLock()
    private let now: () -> TimeInterval
    private var previous: (time: TimeInterval, context: String)?
    private var latestObservation: TimeInterval?
    private var resetTime: TimeInterval = -.infinity
    private var intervals: [Range<TimeInterval>] = []
    private var pending: [Output] = []
    private var pendingDuration: TimeInterval = 0

    init(now: @escaping () -> TimeInterval = { RecordingClock.now }) {
        self.now = now
    }

    func record(state: MeetingMuteState, contextID: String?, at time: TimeInterval, readStartedAt: TimeInterval? = nil) {
        lock.lock(); defer { lock.unlock() }
        let current = now()
        let readStart = readStartedAt ?? time
        prune(at: current)
        guard current.isFinite, time.isFinite, readStart.isFinite, readStart >= resetTime,
              readStart <= time, time <= current, current - readStart <= Self.maximumObservationGap,
              latestObservation.map({ time > $0 }) ?? true else {
            previous = nil
            intervals.removeAll(keepingCapacity: true)
            return
        }
        latestObservation = time
        guard state == .unmuted, let contextID,
              !contextID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            previous = nil
            return
        }
        if let previous, previous.context == contextID,
           readStart > previous.time, time - previous.time <= Self.maximumObservationGap {
            let interval = previous.time..<readStart
            if let last = intervals.last, last.upperBound == interval.lowerBound {
                intervals[intervals.count - 1] = last.lowerBound..<interval.upperBound
            } else {
                intervals.append(interval)
            }
        }
        previous = (time, contextID)
        prune(at: current)
    }

    /// Capture restarts and pause boundaries must require new observations.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        previous = nil
        latestObservation = nil
        resetTime = now()
        intervals.removeAll(keepingCapacity: true)
        pending.removeAll(keepingCapacity: true)
        pendingDuration = 0
    }

    func enqueue(_ buffer: AVAudioPCMBuffer, hostTime: TimeInterval, at time: TimeInterval) -> [Output] {
        lock.lock(); defer { lock.unlock() }
        prune(at: time)
        guard hostTime.isFinite, time.isFinite, buffer.frameLength > 0 else { return [] }
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        guard duration.isFinite, duration > 0 else { return [] }
        var output = drainLocked(at: time, finishing: false)
        // Bound raw PCM by duration and count, even if callbacks arrive late,
        // timestamps repeat, or a device delivers unusually large buffers.
        while !pending.isEmpty && (pendingDuration + duration > Self.bufferDelay || pending.count >= Self.maximumEntries) {
            output.append(removeFirst())
        }
        if duration > Self.bufferDelay || hostTime > time || hostTime + duration <= time - Self.bufferDelay {
            output.append(filtered(buffer, hostTime: hostTime, allowAudio: hostTime <= time))
        } else if let copy = copy(buffer) {
            pending.append(Output(buffer: copy, hostTime: hostTime))
            pendingDuration += duration
        }
        return output
    }

    func drain(at time: TimeInterval, finishing: Bool = false) -> [Output] {
        lock.lock(); defer { lock.unlock() }
        prune(at: time)
        return drainLocked(at: time, finishing: finishing)
    }

    func hasFreshUnmutedObservation(at time: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let previous else { return false }
        return time >= previous.time && time - previous.time <= Self.maximumObservationGap
    }

    func level(of buffer: AVAudioPCMBuffer, at time: TimeInterval) -> Float {
        lock.lock(); defer { lock.unlock() }
        guard let previous, time >= previous.time,
              time - previous.time <= Self.maximumObservationGap else { return 0 }
        return MicAudioProcessing.level(of: buffer)
    }

    // Counts expose the bounded state to hardware-free regression tests.
    var retainedState: (buffers: Int, duration: TimeInterval, intervals: Int) {
        lock.lock(); defer { lock.unlock() }
        return (pending.count, pendingDuration, intervals.count)
    }

    private func drainLocked(at time: TimeInterval, finishing: Bool) -> [Output] {
        var output: [Output] = []
        while let first = pending.first {
            let end = first.hostTime + Double(first.buffer.frameLength) / first.buffer.format.sampleRate
            guard finishing || end <= time - Self.bufferDelay else { break }
            output.append(removeFirst())
        }
        return output
    }

    private func removeFirst() -> Output {
        let first = pending.removeFirst()
        pendingDuration = max(0, pendingDuration - Double(first.buffer.frameLength) / first.buffer.format.sampleRate)
        return filtered(first.buffer, hostTime: first.hostTime)
    }

    private func prune(at time: TimeInterval) {
        intervals.removeAll { $0.upperBound < time - Self.historyDuration }
        if intervals.count > Self.maximumEntries {
            intervals.removeFirst(intervals.count - Self.maximumEntries)
        }
        if let previous, time - previous.time > Self.maximumObservationGap {
            self.previous = nil
        }
    }

    private func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in target.indices {
            memcpy(target[index].mData!, source[index].mData!, Int(target[index].mDataByteSize))
        }
        return copy
    }

    private func filtered(_ buffer: AVAudioPCMBuffer, hostTime: TimeInterval, allowAudio: Bool = true) -> Output {
        // Always preserve duration. An entirely muted recording is a valid CAF
        // containing silence, and later speech keeps its original host time.
        let result = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)!
        result.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let target = UnsafeMutableAudioBufferListPointer(result.mutableAudioBufferList)
        for entry in target {
            if let data = entry.mData { memset(data, 0, Int(entry.mDataByteSize)) }
        }
        if allowAudio {
            let rate = buffer.format.sampleRate
            let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
            for interval in intervals {
                // Round inward, so a frame crossing either boundary is silent.
                let start = Int(max(0, min(Double(buffer.frameLength), ceil((interval.lowerBound - hostTime) * rate))))
                let end = Int(max(0, min(Double(buffer.frameLength), floor((interval.upperBound - hostTime) * rate))))
                guard end > start else { continue }
                for index in target.indices {
                    memcpy(target[index].mData!.advanced(by: start * bytesPerFrame),
                           source[index].mData!.advanced(by: start * bytesPerFrame),
                           (end - start) * bytesPerFrame)
                }
            }
        }
        return Output(buffer: result, hostTime: hostTime)
    }
}
