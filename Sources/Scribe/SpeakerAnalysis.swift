import Foundation

/// Runs the model boundary separately from transcription so retries never
/// decode audio again or replace a user's corrected transcript.
enum SpeakerAnalysis {
    typealias Inference = @Sendable (URL, SpeakerDetectionModel, Int?) async throws -> SpeakerDiarization

    static func run(
        _ document: ScribeDocument,
        folder: URL,
        model: SpeakerDetectionModel,
        analyzeImports: Bool,
        splitAtSpeakerChanges: Bool = true,
        infer: Inference
    ) async -> ScribeDocument {
        var result = document
        result.rawSegments = document.rawSegments ?? document.segments
        result.speakerAnalysisError = nil
        result.speakerModelUsed = nil
        var attempted = false
        var errors: [String] = []
        var analyzedSources = Set<AudioSource>()
        var voiceprints: [String: [Float]] = [:]

        for track in document.tracks {
            // A microphone has one known source identity, including mic-only
            // recordings. Named podcast tracks also need no voice inference.
            guard track.source != .microphone, track.speakerName == nil,
                  track.source == .system || analyzeImports,
                  analyzedSources.insert(track.source).inserted else { continue }
            let sourceSegments = result.segments.filter { $0.source == track.source }
            guard !sourceSegments.isEmpty else { continue }
            attempted = true
            if document.expectedRemoteSpeakerCount == 1 {
                for index in result.segments.indices where result.segments[index].source == track.source {
                    result.segments[index].speaker = "Speaker 1"
                    result.segments[index].speakerID = nil
                }
                result.speakerModelUsed = "single-remote-speaker"
                continue
            }
            do {
                try Task.checkCancellation()
                let detection = try await infer(folder.appendingPathComponent(track.fileName), model, document.expectedRemoteSpeakerCount)
                try Task.checkCancellation()
                guard !detection.intervals.isEmpty else {
                    throw NSError(domain: "Scribe.SpeakerAnalysis", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "No speaker turns were detected. The transcript is preserved; try another speaker model or set the remote speaker count."])
                }
                let offset = track.startOffset ?? 0
                let intervals = detection.intervals.map {
                    SpeakerInterval(speakerID: $0.speakerID, start: $0.start + offset, end: $0.end + offset)
                }
                let assigned = SpeakerDiarizer.assignSpeakers(
                    to: sourceSegments, using: intervals, splitAtSpeakerChanges: splitAtSpeakerChanges
                )
                result.segments.removeAll { $0.source == track.source }
                result.segments.append(contentsOf: assigned)
                for (id, embedding) in detection.voiceprints {
                    if let label = detection.speakerLabels[id] { voiceprints[label] = embedding }
                }
                result.speakerModelUsed = model.rawValue
            } catch {
                errors.append(error.localizedDescription)
                for index in result.segments.indices where result.segments[index].source == track.source {
                    result.segments[index].speaker = "Unanalyzed audio"
                    result.segments[index].speakerID = nil
                }
            }
        }
        result.segments.sort { $0.start < $1.start }
        // Only names attached to actual tracks/turns belong in detection.
        // Calendar names remain optional suggestions in the queue.
        result.speakers = document.speakers?.filter(\.isMicrophone)
        result.knownSpeakers = nil
        result.normalizeSpeakerIdentities()
        result.speakerAnalysisStatus = !errors.isEmpty ? .failed : attempted ? .complete : .notRequested
        result.speakerAnalysisError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        result.speakerVoiceprints = voiceprints.isEmpty ? nil : voiceprints
        result.detectedSpeakers = result.speakers
        result.detectedSpeakerAssignments = result.segments.compactMap { segment in
            segment.speakerID.map { SpeakerAssignment(segmentID: segment.id, speakerID: $0) }
        }
        return result
    }

    /// Reconcile with the latest saved document after asynchronous work. A
    /// changed transcript or speaker list takes precedence over model output.
    static func applying(_ analysis: ScribeDocument, to current: ScribeDocument, basedOn baseline: ScribeDocument) -> ScribeDocument {
        var updated = current
        updated.speakerAnalysisStatus = analysis.speakerAnalysisStatus
        updated.speakerAnalysisError = analysis.speakerAnalysisError
        updated.speakerModelUsed = analysis.speakerModelUsed
        updated.rawSegments = current.rawSegments ?? analysis.rawSegments
        guard analysis.speakerAnalysisStatus != .failed else { return updated }
        updated.detectedSpeakers = analysis.detectedSpeakers
        updated.detectedSpeakerAssignments = analysis.detectedSpeakerAssignments
        let hasEdits = current.speakerEditsApplied == true
            || current.segments != baseline.segments || current.speakers != baseline.speakers
            || current.microphoneSpeakerName != baseline.microphoneSpeakerName
        if !hasEdits {
            updated.segments = analysis.segments
            updated.speakers = analysis.speakers
            updated.speakerVoiceprints = analysis.speakerVoiceprints
            updated.knownSpeakers = analysis.knownSpeakers
        } else {
            // The analysis may have split a turn while the user was editing
            // it. Detection evidence must reference the turns still on screen.
            updated.detectedSpeakerAssignments = current.segments.compactMap { segment in
                var durations: [UUID: TimeInterval] = [:]
                for detected in analysis.segments where detected.source == segment.source {
                    guard let id = detected.speakerID else { continue }
                    let overlap = max(0, min(segment.end, detected.end) - max(segment.start, detected.start))
                    if overlap > 0 { durations[id, default: 0] += overlap }
                }
                let winner = durations.sorted {
                    $0.value == $1.value ? $0.key.uuidString < $1.key.uuidString : $0.value > $1.value
                }.first?.key
                let matchingID = analysis.segments.first(where: { $0.id == segment.id })?.speakerID
                return (winner ?? matchingID).map { SpeakerAssignment(segmentID: segment.id, speakerID: $0) }
            }
        }
        return updated
    }
}
