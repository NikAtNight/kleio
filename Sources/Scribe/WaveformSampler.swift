import AVFoundation
import Foundation

/// Builds compact peak data beside a document's audio so opening playback does
/// not require decoding every file again.
enum WaveformSampler {
    private static let cacheFileName = "waveform.json"
    private static let framesPerRead: AVAudioFrameCount = 65_536

    static func samples(for audioURLs: [URL], bucketCount: Int = 1_000) async -> [Float] {
        guard bucketCount > 0 else { return [] }

        return await Task.detached(priority: .utility) {
            let fingerprint = fingerprint(for: audioURLs)
            let cacheURL = cacheURL(for: audioURLs)

            if let cacheURL,
               let cached = readCache(at: cacheURL),
               cached.fingerprint == fingerprint,
               cached.samples.count == bucketCount {
                return cached.samples
            }

            var merged = Array(repeating: Float.zero, count: bucketCount)
            for url in audioURLs {
                let track = sampleTrack(at: url, bucketCount: bucketCount)
                for index in merged.indices {
                    merged[index] = max(merged[index], track[index])
                }
            }

            if let cacheURL {
                write(Cache(fingerprint: fingerprint, samples: merged), to: cacheURL)
            }
            return merged
        }.value
    }

    private static func sampleTrack(at url: URL, bucketCount: Int) -> [Float] {
        guard let file = try? AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        ), file.length > 0 else {
            return Array(repeating: .zero, count: bucketCount)
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: framesPerRead
        ) else {
            return Array(repeating: .zero, count: bucketCount)
        }

        var peaks = Array(repeating: Float.zero, count: bucketCount)
        var filePeak: Float = 0
        var frameOffset: AVAudioFramePosition = 0

        while true {
            do {
                try file.read(into: buffer, frameCount: framesPerRead)
            } catch {
                break
            }

            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else { break }
            guard let channels = buffer.floatChannelData else { break }
            let channelCount = Int(buffer.format.channelCount)

            for frame in 0..<frameLength {
                var peak: Float = 0
                for channel in 0..<channelCount {
                    peak = max(peak, abs(channels[channel][frame]))
                }
                filePeak = max(filePeak, peak)
                let position = frameOffset + AVAudioFramePosition(frame)
                let fraction = Double(position) / Double(file.length)
                let bucket = min(bucketCount - 1, Int(fraction * Double(bucketCount)))
                peaks[bucket] = max(peaks[bucket], peak)
            }
            frameOffset += AVAudioFramePosition(frameLength)
        }

        guard filePeak > 0 else { return peaks }
        return peaks.map { $0 / filePeak }
    }

    private static func fingerprint(for urls: [URL]) -> String {
        urls.sorted { $0.path < $1.path }.map { url in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -1
            let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? -1
            return "\(url.lastPathComponent)|\(size)|\(modified)"
        }.joined(separator: "\n")
    }

    private static func cacheURL(for urls: [URL]) -> URL? {
        guard let first = urls.first?.deletingLastPathComponent() else { return nil }
        let directory = first.standardizedFileURL
        guard urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == directory }) else {
            return nil
        }
        return directory.appendingPathComponent(cacheFileName)
    }

    private static func readCache(at url: URL) -> Cache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Cache.self, from: data)
    }

    private static func write(_ cache: Cache, to url: URL) {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private struct Cache: Codable {
        let fingerprint: String
        let samples: [Float]
    }
}
