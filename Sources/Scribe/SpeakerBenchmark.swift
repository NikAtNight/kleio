import AVFoundation
import Foundation

/// A local diagnostic entry point. Reference labels describe speech activity
/// or whole clips explicitly; this report does not claim a standard DER score.
enum SpeakerBenchmark {
    struct Reference: Codable {
        enum AnnotationKind: String, Codable { case speechActivity, clipIdentity }
        var annotationKind: AnnotationKind
        var source: String
        var turns: [Turn]
    }

    struct Turn: Codable, Equatable {
        var speaker: String
        var start: Double
        var end: Double
    }

    struct VoiceCoverage: Codable {
        var referenceSpeaker: String
        var exclusiveSpeechSeconds: Double
        var clusterOverlapSeconds: [String: Double]
    }

    struct Metrics: Codable {
        var referenceSpeakerCount: Int
        var detectedSpeakerCount: Int
        var referenceSpeechSeconds: Double
        var missedReferenceSpeechSeconds: Double
        var overlappingReferenceSpeechSeconds: Double
        var voices: [VoiceCoverage]
        var referenceVoicesWithMultipleClusters: Int
        var clustersCoveringMultipleVoices: Int
        var minimumOverlapForSplitOrMergeSeconds: Double
    }

    struct Report: Codable {
        var audioFile: String
        var durationSeconds: Double
        var model: String
        var expectedRemoteSpeakerCount: Int?
        var detectedSpeakerCount: Int
        var modelWasBypassed: Bool
        var preparationSeconds: Double?
        var analysisSecondsIncludingCachedModelLoad: Double
        var operatingSystem: String
        var annotationKind: Reference.AnnotationKind
        var referenceSource: String
        var metrics: Metrics?
        var detectedTurns: [Turn]
        var limitations: String
    }

    static func evaluate(reference: [Turn], detected: [Turn]) -> Metrics {
        let speakers = Set(reference.map(\.speaker)).sorted()
        let boundaries = Set((reference + detected).flatMap { [$0.start, $0.end] }).sorted()
        var totalSpeech = 0.0
        var missedSpeech = 0.0
        var overlappingSpeech = 0.0
        var exclusiveDurations: [String: Double] = [:]
        var overlaps: [String: [String: Double]] = [:]
        for (start, end) in zip(boundaries, boundaries.dropFirst()) {
            let midpoint = (start + end) / 2
            let referenceVoices = Set(reference.filter { $0.start <= midpoint && $0.end > midpoint }.map(\.speaker))
            guard !referenceVoices.isEmpty else { continue }
            let clusters = Set(detected.filter { $0.start <= midpoint && $0.end > midpoint }.map(\.speaker))
            let duration = end - start
            totalSpeech += duration
            if clusters.isEmpty { missedSpeech += duration }
            guard referenceVoices.count == 1, let speaker = referenceVoices.first else {
                overlappingSpeech += duration
                continue
            }
            exclusiveDurations[speaker, default: 0] += duration
            for cluster in clusters { overlaps[speaker, default: [:]][cluster, default: 0] += duration }
        }
        let minimumOverlap = 0.25
        let voices = speakers.map {
            VoiceCoverage(referenceSpeaker: $0, exclusiveSpeechSeconds: exclusiveDurations[$0] ?? 0,
                          clusterOverlapSeconds: overlaps[$0] ?? [:])
        }
        let significant = voices.map { Set($0.clusterOverlapSeconds.filter { $0.value >= minimumOverlap }.keys) }
        let clusters = Set(detected.map(\.speaker))
        return Metrics(
            referenceSpeakerCount: speakers.count, detectedSpeakerCount: clusters.count,
            referenceSpeechSeconds: totalSpeech, missedReferenceSpeechSeconds: missedSpeech,
            overlappingReferenceSpeechSeconds: overlappingSpeech, voices: voices,
            referenceVoicesWithMultipleClusters: significant.filter { $0.count > 1 }.count,
            clustersCoveringMultipleVoices: clusters.filter { cluster in significant.filter { $0.contains(cluster) }.count > 1 }.count,
            minimumOverlapForSplitOrMergeSeconds: minimumOverlap
        )
    }

    static func run(arguments: [String]) async throws {
        let usage = "Usage: Kleio --benchmark-speakers <audio> <reference.json> <report.json> [--count N] [--model community1|sortformer] [--download-models]"
        @Sendable func invalid(_ message: String) -> Error {
            NSError(domain: "Scribe.SpeakerBenchmark", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message + "\n" + usage])
        }
        guard arguments.count >= 3 else { throw invalid("Audio, reference annotations and output report are required.") }
        let audio = URL(fileURLWithPath: arguments[0])
        let referenceURL = URL(fileURLWithPath: arguments[1])
        let output = URL(fileURLWithPath: arguments[2])
        guard output.standardizedFileURL != audio.standardizedFileURL,
              output.standardizedFileURL != referenceURL.standardizedFileURL else {
            throw invalid("The output report must not replace audio or reference annotations.")
        }
        if FileManager.default.fileExists(atPath: output.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: output.path)) != nil {
            throw invalid("The output report already exists. Choose a new report filename.")
        }
        var count: Int?
        var model = SpeakerDetectionModel.community1
        var download = false
        var index = 3
        while index < arguments.count {
            switch arguments[index] {
            case "--download-models": download = true
            case "--count":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                    throw invalid("The expected count must be a positive integer.")
                }
                count = value
            case "--model":
                index += 1
                guard index < arguments.count, let value = SpeakerDetectionModel(rawValue: arguments[index]) else {
                    throw invalid("Unknown speaker model.")
                }
                model = value
            default: throw invalid("Unknown argument: \(arguments[index])")
            }
            index += 1
        }
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: referenceURL))
        let file = try AVAudioFile(forReading: audio)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration.isFinite, duration > 0, !reference.turns.isEmpty,
              reference.turns.allSatisfy({
                  !$0.speaker.isEmpty && $0.start.isFinite && $0.end.isFinite
                      && $0.start >= 0 && $0.end > $0.start && $0.end <= duration + 0.05
              }) else { throw invalid("Reference intervals must describe valid spans within the audio.") }
        let diarizer = SpeakerDiarizer()
        var preparationSeconds: Double?
        if download, count != 1 {
            let start = Date()
            try await diarizer.prepareModels(for: model)
            preparationSeconds = Date().timeIntervalSince(start)
        }
        let started = Date()
        let turns: [Turn]
        if count == 1 {
            let document = ScribeDocument(title: "Benchmark", kind: .recording, status: .ready,
                                         tracks: [AudioTrack(source: .system, fileName: audio.lastPathComponent)],
                                         segments: [TranscriptSegment(start: 0, end: duration, text: "Remote audio", source: .system)],
                                         expectedRemoteSpeakerCount: 1)
            let result = await SpeakerAnalysis.run(document, folder: audio.deletingLastPathComponent(), model: model,
                                                   analyzeImports: false) { _, _, _ in
                throw invalid("The single-person path unexpectedly invoked a model.")
            }
            guard result.speakerAnalysisStatus == .complete else {
                throw invalid(result.speakerAnalysisError ?? "The single-person assignment failed.")
            }
            turns = result.segments.map { Turn(speaker: $0.speaker ?? "Unknown", start: $0.start, end: $0.end) }
        } else {
            let result = try await diarizer.intervals(for: audio, model: model, expectedSpeakerCount: count)
            turns = result.intervals.map { Turn(speaker: $0.speakerID, start: $0.start, end: $0.end) }
        }
        let report = Report(
            audioFile: audio.lastPathComponent, durationSeconds: duration, model: model.rawValue,
            expectedRemoteSpeakerCount: count, detectedSpeakerCount: Set(turns.map(\.speaker)).count,
            modelWasBypassed: count == 1, preparationSeconds: preparationSeconds,
            analysisSecondsIncludingCachedModelLoad: Date().timeIntervalSince(started),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            annotationKind: reference.annotationKind, referenceSource: reference.source,
            metrics: count != 1 && reference.annotationKind == .speechActivity
                ? evaluate(reference: reference.turns, detected: turns) : nil,
            detectedTurns: turns,
            limitations: count == 1
                ? "One remote label is assigned by policy. No speech detector or diarization model ran, so no accuracy score is reported."
                : "Identity overlap uses only reference spans with one active speaker. Silence is excluded; overlapping reference speech is reported separately. Split/merge indicators require at least 0.25 seconds per pairing and are not DER. Clip-identity annotations receive no speech-accuracy metrics because they may include silence."
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Exclusive creation also protects files created after the preflight.
        try encoder.encode(report).write(to: output, options: .withoutOverwriting)
        print("Speaker report saved to \(output.path)")
    }
}
