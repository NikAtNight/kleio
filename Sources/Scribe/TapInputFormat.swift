import AVFoundation

/// Interprets aggregate input streams after capture has rejected devices with
/// physical inputs. Every declared stream and callback buffer must belong to the tap.
struct TapInputFormat {
    let format: AVAudioFormat
    let bufferChannels: [UInt32]

    static func validateChannelOrder(starts: [UInt32], counts: [UInt32]) throws {
        // A tap can begin after output channels in the aggregate's numbering.
        // Only its relative ordering and coverage describe the input ABL.
        guard let first = starts.first, first > 0, starts.count == counts.count else {
            throw SystemAudioTap.TapError.badFormat
        }
        var expected = first
        for (start, count) in zip(starts, counts) {
            guard start == expected, count > 0, count <= UInt32.max - expected else {
                throw SystemAudioTap.TapError.badFormat
            }
            expected += count
        }
    }

    init(streamFormats: [AVAudioFormat], tapChannels: UInt32 = 2) throws {
        var channels: UInt32 = 0
        var buffers: [UInt32] = []
        var rate: Double?
        for stream in streamFormats {
            let asbd = stream.streamDescription.pointee
            guard stream.commonFormat == .pcmFormatFloat32,
                  asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
                  asbd.mBytesPerFrame == 4 * (stream.isInterleaved ? stream.channelCount : 1),
                  stream.sampleRate.isFinite, stream.sampleRate > 0,
                  rate == nil || rate == stream.sampleRate else { throw SystemAudioTap.TapError.badFormat }
            rate = stream.sampleRate
            buffers += stream.isInterleaved ? [stream.channelCount] : Array(repeating: 1, count: Int(stream.channelCount))
            channels += stream.channelCount
        }
        guard let rate, channels == tapChannels,
              let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: tapChannels) else {
            throw SystemAudioTap.TapError.badFormat
        }
        self.format = format
        bufferChannels = buffers
    }

    /// Copy before returning from the IO callback. Byte counts describe frames
    /// at the aggregate stream's rate, not the tap's pre-aggregation rate.
    func copyBuffer(from list: UnsafePointer<AudioBufferList>) throws -> AVAudioPCMBuffer? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard buffers.count == bufferChannels.count,
              buffers.indices.allSatisfy({ buffers[$0].mNumberChannels == bufferChannels[$0] }) else {
            throw SystemAudioTap.TapError.badFormat
        }
        var frames: UInt32?
        for index in buffers.indices {
            let bytesPerFrame = 4 * bufferChannels[index]
            let bytes = buffers[index].mDataByteSize
            guard bytesPerFrame > 0, bytes % bytesPerFrame == 0,
                  frames == nil || frames == bytes / bytesPerFrame,
                  bytes == 0 || buffers[index].mData != nil else { throw SystemAudioTap.TapError.badFormat }
            frames = bytes / bytesPerFrame
        }
        guard let frames, frames > 0 else { return nil }
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let destination = output.floatChannelData else { throw SystemAudioTap.TapError.badFormat }
        output.frameLength = frames
        var channel = 0
        for index in buffers.indices {
            let source = buffers[index].mData!.assumingMemoryBound(to: Float.self)
            let channelCount = Int(bufferChannels[index])
            for localChannel in 0..<channelCount {
                for frame in 0..<Int(frames) {
                    destination[channel][frame] = source[frame * channelCount + localChannel]
                }
                channel += 1
            }
        }
        return output
    }
}

/// Detect persistent rate disagreement before it becomes a full recording of
/// inserted gaps. A single dropped callback remains a real timeline gap.
struct TapTimingValidator {
    private var previous: (frames: UInt32, host: Double, sample: Double?)?
    private var mismatches = 0

    mutating func validate(frames: UInt32, rate: Double, hostTime: Double, sampleTime: Double?) throws {
        guard hostTime.isFinite, rate.isFinite, rate > 0, frames > 0,
              sampleTime.map(\.isFinite) ?? true else { throw SystemAudioTap.TapError.inconsistentTiming }
        defer { previous = (frames, hostTime, sampleTime) }
        guard let previous else { return }
        let elapsed = hostTime - previous.host
        guard elapsed > 0 else { throw SystemAudioTap.TapError.inconsistentTiming }
        let expected = Double(previous.frames) / rate
        var mismatch = elapsed > expected * 1.5
        if let sampleTime, let priorSample = previous.sample {
            let sampleElapsed = (sampleTime - priorSample) / rate
            mismatch = mismatch || abs(sampleElapsed - elapsed) > max(0.001, elapsed * 0.05)
        }
        mismatches = mismatch ? mismatches + 1 : 0
        if mismatches >= 5 { throw SystemAudioTap.TapError.inconsistentTiming }
    }
}
