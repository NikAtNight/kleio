import CoreML
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

enum SpeakerDetectionModel: String, CaseIterable, Identifiable, Sendable {
    case community1
    case sortformer

    var id: String { rawValue }
    var title: String {
        switch self {
        case .community1: return "Community-1"
        case .sortformer: return "Sortformer v2.1"
        }
    }

    static var selected: Self {
        Self(rawValue: UserDefaults.standard.string(forKey: "speakerDetectionModel") ?? "") ?? .community1
    }
}

/// Local analysis never starts a model download. Settings owns the explicit
/// prepare action; corrupt or missing files produce a retryable failure.
actor SpeakerDiarizer {
    enum AnalysisError: LocalizedError {
        case modelsMissing(SpeakerDetectionModel)
        case invalidSpeakerCount
        case sortformerSpeakerLimit
        case invalidPLDA

        var errorDescription: String? {
            switch self {
            case .modelsMissing(let model):
                return "Download \(model.title) in Settings to analyze speakers, then retry speaker analysis."
            case .invalidSpeakerCount:
                return "The remote speaker count must be at least one."
            case .sortformerSpeakerLimit:
                return "Sortformer supports at most four remote speakers. Set a known count from two to four, or use Community-1 for automatic counting and larger meetings."
            case .invalidPLDA:
                return "The Community-1 speaker model is incomplete or damaged."
            }
        }
    }

    private var communityModels: OfflineDiarizerModels?
    private var sortformer: SortformerDiarizer?

    nonisolated static var modelDirectory: URL {
        ModelManager.downloadBase.appendingPathComponent("diarization-models", isDirectory: true)
    }

    private nonisolated static func assets(for model: SpeakerDetectionModel) -> (Repo, Set<String>) {
        switch model {
        case .community1:
            return (.diarizer, ModelNames.OfflineDiarizer.requiredModels)
        case .sortformer:
            return (.sortformer, [ModelNames.Sortformer.Variant.balancedV2_1.fileName])
        }
    }

    nonisolated static func modelsReady(for model: SpeakerDetectionModel, directory: URL = modelDirectory) -> Bool {
        let (repo, files) = assets(for: model)
        let folder = directory.appendingPathComponent(repo.folderName)
        return files.allSatisfy { file in
            let path = folder.appendingPathComponent(file)
            let required = file.hasSuffix(".mlmodelc") ? path.appendingPathComponent("coremldata.bin") : path
            return FileManager.default.fileExists(atPath: required.path)
        }
    }

    /// Called by the user's download button, never implicitly by analysis.
    func prepareModels(for model: SpeakerDetectionModel) async throws {
        if !Self.modelsReady(for: model) {
            let (repo, _) = Self.assets(for: model)
            let variant = model == .community1 ? "offline" : ModelNames.Sortformer.Variant.balancedV2_1.fileName
            try await ModelHub.download(repo, to: Self.modelDirectory, variant: variant)
        }
        try loadCachedModels(for: model)
    }

    private func loadCachedModels(for model: SpeakerDetectionModel) throws {
        guard Self.modelsReady(for: model) else { throw AnalysisError.modelsMissing(model) }
        let (repo, _) = Self.assets(for: model)
        let folder = Self.modelDirectory.appendingPathComponent(repo.folderName)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        switch model {
        case .community1:
            guard communityModels == nil else { return }
            let parameters = try Data(contentsOf: folder.appendingPathComponent(ModelNames.OfflineDiarizer.pldaParameters))
            guard let json = try JSONSerialization.jsonObject(with: parameters) as? [String: Any],
                  let tensors = json["tensors"] as? [String: Any],
                  let psi = tensors["psi"] as? [String: Any],
                  let encoded = psi["data_base64"] as? String,
                  let bytes = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters),
                  !bytes.isEmpty, bytes.count.isMultiple(of: MemoryLayout<Float>.size) else {
                throw AnalysisError.invalidPLDA
            }
            var values = [Float](repeating: 0, count: bytes.count / MemoryLayout<Float>.size)
            _ = values.withUnsafeMutableBytes { bytes.copyBytes(to: $0) }
            let fbankConfiguration = MLModelConfiguration()
            fbankConfiguration.computeUnits = .cpuOnly
            communityModels = try OfflineDiarizerModels(
                segmentationModel: MLModel(contentsOf: folder.appendingPathComponent(ModelNames.OfflineDiarizer.segmentationPath), configuration: configuration),
                fbankModel: MLModel(contentsOf: folder.appendingPathComponent(ModelNames.OfflineDiarizer.fbankPath), configuration: fbankConfiguration),
                embeddingModel: MLModel(contentsOf: folder.appendingPathComponent(ModelNames.OfflineDiarizer.embeddingPath), configuration: configuration),
                pldaRhoModel: MLModel(contentsOf: folder.appendingPathComponent(ModelNames.OfflineDiarizer.pldaRhoPath), configuration: configuration),
                pldaPsi: values.map(Double.init), compilationDuration: 0
            )
        case .sortformer:
            guard sortformer == nil else { return }
            let config = SortformerConfig.balancedV2_1
            let model = try MLModel(contentsOf: folder.appendingPathComponent(ModelNames.Sortformer.Variant.balancedV2_1.fileName), configuration: configuration)
            let engine = SortformerDiarizer(config: config)
            engine.initialize(models: try SortformerModels(config: config, main: model))
            sortformer = engine
        }
    }

    nonisolated static func communityConfiguration(expectedSpeakerCount: Int?) throws -> OfflineDiarizerConfig {
        if let count = expectedSpeakerCount, count < 1 { throw AnalysisError.invalidSpeakerCount }
        var config = OfflineDiarizerConfig.default
        config.clustering.numSpeakers = expectedSpeakerCount
        // The dependency uses this for both embedding extraction and final
        // turns. One second removes ordinary short replies from the result.
        config.minSegmentDuration = 0.2
        config.postProcessing.exclusiveSegments = false
        return config
    }

    func intervals(
        for url: URL,
        model: SpeakerDetectionModel = .community1,
        expectedSpeakerCount: Int? = nil
    ) async throws -> SpeakerDiarization {
        if let count = expectedSpeakerCount, count < 1 { throw AnalysisError.invalidSpeakerCount }
        if model == .sortformer,
           !(expectedSpeakerCount.map { (2...4).contains($0) } ?? false) {
            throw AnalysisError.sortformerSpeakerLimit
        }
        try loadCachedModels(for: model)
        switch model {
        case .community1:
            let manager = OfflineDiarizerManager(config: try Self.communityConfiguration(expectedSpeakerCount: expectedSpeakerCount))
            guard let communityModels else { throw AnalysisError.modelsMissing(model) }
            manager.initialize(models: communityModels)
            let result = try await manager.process(url)
            let intervals = result.segments.map {
                SpeakerInterval(speakerID: $0.speakerId, start: TimeInterval($0.startTimeSeconds), end: TimeInterval($0.endTimeSeconds))
            }
            return SpeakerDiarization(intervals: intervals,
                                      voiceprints: result.speakerDatabase ?? Self.durationWeightedVoiceprints(from: result.segments),
                                      speakerLabels: Self.speakerLabels(for: intervals))
        case .sortformer:
            guard let sortformer else { throw AnalysisError.modelsMissing(model) }
            let timeline = try sortformer.processComplete(audioFileURL: url, keepingEnrolledSpeakers: false)
            let intervals = timeline.speakers.values.flatMap(\.finalizedSegments).map {
                SpeakerInterval(speakerID: String($0.speakerIndex), start: TimeInterval($0.startTime), end: TimeInterval($0.endTime))
            }
            return SpeakerDiarization(intervals: intervals, voiceprints: [:], speakerLabels: Self.speakerLabels(for: intervals))
        }
    }

    /// Timed words let a short answer keep its speaker even when Whisper puts
    /// it in the same sentence as the preceding question. Ambiguous overlap
    /// remains visible instead of choosing an arbitrary person.
    nonisolated static func assignSpeakers(
        to segments: [TranscriptSegment],
        using intervals: [SpeakerInterval],
        splitAtSpeakerChanges: Bool = true
    ) -> [TranscriptSegment] {
        let validIntervals = intervals.filter {
            $0.start.isFinite && $0.end.isFinite && $0.end > $0.start
        }
        let labels = speakerLabels(for: validIntervals)
        return segments.flatMap { segment -> [TranscriptSegment] in
            guard segment.source != .microphone else { return [segment] }
            let localIntervals = validIntervals.filter { $0.end > segment.start && $0.start < segment.end }
            guard splitAtSpeakerChanges,
                  let words = segment.words, !words.isEmpty,
                  TranscriptTiming.wordRanges(in: segment) != nil else {
                var assigned = segment
                assigned.speaker = bestSpeaker(start: segment.start, end: segment.end,
                                               intervals: localIntervals, labels: labels)
                assigned.speakerID = nil
                return [assigned]
            }
            let names = words.map {
                bestSpeaker(start: $0.start, end: $0.end, intervals: localIntervals, labels: labels)
            }
            var starts = [0]
            for index in 1..<words.count where names[index] != names[index - 1] {
                starts.append(index)
            }
            return (TranscriptTiming.split(segment, atWordIndices: starts) ?? [segment]).enumerated().map { group, piece in
                var turn = piece
                turn.speaker = names[starts[group]]
                turn.speakerID = nil
                return turn
            }
        }
    }

    private nonisolated static func bestSpeaker(
        start: TimeInterval, end: TimeInterval,
        intervals: [SpeakerInterval], labels: [String: String]
    ) -> String {
        let duration = max(0.04, end - start)
        var coverage: [String: TimeInterval] = [:]
        // Merge intersecting spans for the same speaker so duplicate model
        // intervals cannot inflate confidence.
        for (id, spans) in Dictionary(grouping: intervals, by: \.speakerID) {
            var coveredUntil = start
            for span in spans.sorted(by: { $0.start < $1.start }) {
                let lower = max(start, span.start, coveredUntil)
                let upper = min(end, span.end)
                if upper > lower {
                    coverage[id, default: 0] += upper - lower
                    coveredUntil = upper
                }
            }
        }
        let ranked = coverage.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }
        guard let best = ranked.first,
              best.value >= duration * 0.5,
              best.value - (ranked.dropFirst().first?.value ?? 0) >= duration * 0.15,
              let label = labels[best.key] else { return "Uncertain speaker" }
        return label
    }

    nonisolated static func speakerLabels(for intervals: [SpeakerInterval]) -> [String: String] {
        var orderedIDs: [String] = []
        for interval in intervals.sorted(by: { $0.start == $1.start ? $0.speakerID < $1.speakerID : $0.start < $1.start })
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

}
