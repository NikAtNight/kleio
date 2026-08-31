import FluidAudio
import Foundation

struct SpeakerInterval: Sendable, Hashable {
    var speakerID: String
    var start: TimeInterval
    var end: TimeInterval
}

/// Fully local "who spoke when" pass backed by FluidAudio's offline Core ML
/// pipeline. Models are lazy-loaded only when the user enables automatic
/// speaker recognition.
actor SpeakerDiarizer {
    private var manager: OfflineDiarizerManager?

    func intervals(for url: URL) async throws -> [SpeakerInterval] {
        let manager: OfflineDiarizerManager
        if let existing = self.manager {
            manager = existing
        } else {
            let created = OfflineDiarizerManager()
            let modelDirectory = ModelManager.downloadBase
                .appendingPathComponent("diarization-models", isDirectory: true)
            try await created.prepareModels(directory: modelDirectory)
            self.manager = created
            manager = created
        }
        let result = try await manager.process(url)
        return result.segments.map {
            SpeakerInterval(
                speakerID: $0.speakerId,
                start: TimeInterval($0.startTimeSeconds),
                end: TimeInterval($0.endTimeSeconds)
            )
        }
    }

    /// Assign each Whisper segment to the diarized speaker with the greatest
    /// overlap. IDs are relabeled by first appearance for a stable,
    /// user-friendly Speaker 1, Speaker 2… ordering.
    nonisolated static func assignSpeakers(
        to segments: [TranscriptSegment],
        using intervals: [SpeakerInterval]
    ) -> [TranscriptSegment] {
        guard !intervals.isEmpty else { return segments }
        var orderedIDs: [String] = []
        for interval in intervals.sorted(by: { $0.start < $1.start })
            where !orderedIDs.contains(interval.speakerID) {
            orderedIDs.append(interval.speakerID)
        }
        let labels = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map {
            ($0.element, "Speaker \($0.offset + 1)")
        })

        return segments.map { segment in
            var assigned = segment
            let best = intervals.max { lhs, rhs in
                overlap(segment, lhs) < overlap(segment, rhs)
            }
            if let best, overlap(segment, best) > 0.02 {
                assigned.speaker = labels[best.speakerID]
            }
            return assigned
        }
    }

    private nonisolated static func overlap(
        _ segment: TranscriptSegment,
        _ interval: SpeakerInterval
    ) -> TimeInterval {
        max(0, min(segment.end, interval.end) - max(segment.start, interval.start))
    }
}
