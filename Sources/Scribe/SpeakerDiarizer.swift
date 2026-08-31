import FluidAudio
import Foundation

struct SpeakerInterval: Sendable, Hashable {
    var speakerID: String
    var start: TimeInterval
    var end: TimeInterval
}

struct SpeakerDiarization: Sendable {
    var intervals: [SpeakerInterval]
    var voiceprints: [String: [Float]]
    var speakerLabels: [String: String]
}

/// Fully local "who spoke when" pass backed by FluidAudio's offline Core ML
/// pipeline. Models are lazy-loaded only when the user enables automatic
/// speaker recognition.
actor SpeakerDiarizer {
    private var manager: OfflineDiarizerManager?

    func intervals(for url: URL) async throws -> SpeakerDiarization {
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
        let intervals = result.segments.map {
            SpeakerInterval(
                speakerID: $0.speakerId,
                start: TimeInterval($0.startTimeSeconds),
                end: TimeInterval($0.endTimeSeconds)
            )
        }
        let voiceprints = result.speakerDatabase
            ?? Self.durationWeightedVoiceprints(from: result.segments)
        return SpeakerDiarization(
            intervals: intervals,
            voiceprints: voiceprints,
            speakerLabels: Self.speakerLabels(for: intervals)
        )
    }

    /// Assign each Whisper segment to the diarized speaker with the greatest
    /// overlap. IDs are relabeled by first appearance for a stable,
    /// user-friendly Speaker 1, Speaker 2… ordering.
    nonisolated static func assignSpeakers(
        to segments: [TranscriptSegment],
        using intervals: [SpeakerInterval]
    ) -> [TranscriptSegment] {
        guard !intervals.isEmpty else { return segments }
        let labels = speakerLabels(for: intervals)

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

    nonisolated static func speakerLabels(for intervals: [SpeakerInterval]) -> [String: String] {
        var orderedIDs: [String] = []
        for interval in intervals.sorted(by: { $0.start < $1.start })
            where !orderedIDs.contains(interval.speakerID) {
            orderedIDs.append(interval.speakerID)
        }
        return Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map {
            ($0.element, "Speaker \($0.offset + 1)")
        })
    }

    nonisolated static func durationWeightedVoiceprints(
        from segments: [TimedSpeakerSegment]
    ) -> [String: [Float]] {
        var weightedSums: [String: [Float]] = [:]
        var totalDurations: [String: Float] = [:]
        for segment in segments {
            let duration = max(0, segment.durationSeconds)
            guard duration > 0, !segment.embedding.isEmpty else { continue }
            if let existing = weightedSums[segment.speakerId], existing.count == segment.embedding.count {
                weightedSums[segment.speakerId] = zip(existing, segment.embedding).map {
                    $0 + $1 * duration
                }
            } else if weightedSums[segment.speakerId] == nil {
                weightedSums[segment.speakerId] = segment.embedding.map { $0 * duration }
            } else {
                continue
            }
            totalDurations[segment.speakerId, default: 0] += duration
        }
        var voiceprints: [String: [Float]] = [:]
        for (speakerID, sum) in weightedSums {
            guard let duration = totalDurations[speakerID], duration > 0 else { continue }
            voiceprints[speakerID] = sum.map { $0 / duration }
        }
        return voiceprints
    }

    private nonisolated static func overlap(
        _ segment: TranscriptSegment,
        _ interval: SpeakerInterval
    ) -> TimeInterval {
        max(0, min(segment.end, interval.end) - max(segment.start, interval.start))
    }
}
