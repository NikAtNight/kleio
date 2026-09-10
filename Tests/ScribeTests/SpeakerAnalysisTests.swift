import Foundation
import XCTest
import WhisperKit
@testable import Scribe

final class SpeakerAnalysisTests: XCTestCase {
    func testAutomaticLanguageAndWordTimingAreExplicitDecodingOptions() {
        let automatic = Transcriber.decodingOptions(language: nil, translate: false, model: "small")
        XCTAssertTrue(automatic.detectLanguage)
        XCTAssertNil(automatic.language)
        XCTAssertTrue(automatic.wordTimestamps)
        let english = Transcriber.decodingOptions(language: "", translate: false, model: "small.en")
        XCTAssertEqual(english.language, "en")
        XCTAssertFalse(english.detectLanguage)
        let french = Transcriber.decodingOptions(language: "fr", translate: true, model: "small")
        XCTAssertEqual(french.language, "fr")
        XCTAssertFalse(french.detectLanguage)
        XCTAssertEqual(french.task, .translate)
    }

    func testOverlappingVoicesRemainUncertainInsteadOfCreatingAPerson() {
        let segment = TranscriptSegment(start: 0, end: 1, text: "Talking together", source: .system)
        let intervals = [SpeakerInterval(speakerID: "A", start: 0, end: 1),
                         SpeakerInterval(speakerID: "B", start: 0, end: 1)]
        let result = SpeakerDiarizer.assignSpeakers(to: [segment], using: intervals)
        XCTAssertEqual(result.first?.speaker, "Uncertain speaker")
        XCTAssertEqual(result.first?.text, segment.text)
    }

    func testCorrectedTextWithoutMatchingWordAlignmentIsNeverReplacedOrSplit() {
        let segment = TranscriptSegment(start: 0, end: 2, text: "Corrected name.", source: .system, words: [
            TranscriptWord(start: 0, end: 1, text: "Incorrect"),
            TranscriptWord(start: 1, end: 2, text: " name."),
        ])
        let result = SpeakerDiarizer.assignSpeakers(to: [segment], using: [
            SpeakerInterval(speakerID: "A", start: 0, end: 1),
            SpeakerInterval(speakerID: "B", start: 1, end: 2),
        ])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.text, "Corrected name.")
        XCTAssertEqual(result.first?.words, segment.words)
    }

    func testSpeakerRetryKeepsTextAndAssignmentsWhileSavingNewDetection() async {
        var document = meetingFixture()
        document.normalizeSpeakerIdentities()
        document.segments[1].speaker = "Ajay"
        document.segments[1].text = "Corrected transcript"
        let remoteID = document.segments[1].speakerID!
        document.speakers?[1].name = "Ajay"
        document.speakerEditsApplied = true
        document.rawSegments = [TranscriptSegment(start: 0, end: 2, text: "Original ASR", source: .system)]
        let original = document
        let analysis = await SpeakerAnalysis.run(document, folder: URL(fileURLWithPath: "/unused"), model: .community1,
                                                 analyzeImports: false, splitAtSpeakerChanges: false) { _, _, _ in
            SpeakerDiarization(intervals: [SpeakerInterval(speakerID: "new", start: 0, end: 5)],
                               voiceprints: [:], speakerLabels: ["new": "Speaker 1"])
        }
        let updated = SpeakerAnalysis.applying(analysis, to: document, basedOn: original)
        XCTAssertEqual(updated.segments, original.segments)
        XCTAssertEqual(updated.speakers, original.speakers)
        XCTAssertEqual(updated.rawSegments, original.rawSegments)
        XCTAssertEqual(updated.segments[1].speakerID, remoteID)
        XCTAssertEqual(updated.speakerAnalysisStatus, .complete)
        XCTAssertEqual(Set(updated.detectedSpeakerAssignments?.map(\.segmentID) ?? []), Set(original.segments.map(\.id)))
        XCTAssertTrue(updated.detectedSpeakers?.contains(where: { $0.name == "Speaker 1" }) == true)
    }

    func testTextEditDuringAnalysisKeepsItsTextAndDetectionReferencesExistingTurns() async {
        var baseline = meetingFixture()
        baseline.segments[1].text = "First second"
        baseline.segments[1].words = [TranscriptWord(start: 1, end: 1.4, text: "First"),
                                      TranscriptWord(start: 1.5, end: 2, text: " second")]
        baseline.normalizeSpeakerIdentities()
        let analysis = await SpeakerAnalysis.run(baseline, folder: URL(fileURLWithPath: "/unused"), model: .community1,
                                                 analyzeImports: false) { _, _, _ in
            SpeakerDiarization(intervals: [SpeakerInterval(speakerID: "A", start: 1, end: 1.4),
                                           SpeakerInterval(speakerID: "B", start: 1.5, end: 2)],
                               voiceprints: [:], speakerLabels: ["A": "Speaker 1", "B": "Speaker 2"])
        }
        var edited = baseline
        edited.segments[1].text = "My correction"
        let updated = SpeakerAnalysis.applying(analysis, to: edited, basedOn: baseline)
        XCTAssertEqual(updated.segments, edited.segments)
        XCTAssertEqual(Set(updated.detectedSpeakerAssignments?.map(\.segmentID) ?? []), Set(edited.segments.map(\.id)))
    }

    func testRemoteTrackOffsetIsAppliedBeforeSpeakerAssignment() async {
        var document = meetingFixture()
        document.tracks[1].startOffset = 3
        document.segments[1].start = 3
        document.segments[1].end = 4
        let analysis = await SpeakerAnalysis.run(document, folder: URL(fileURLWithPath: "/unused"), model: .community1,
                                                 analyzeImports: false) { _, _, _ in
            SpeakerDiarization(intervals: [SpeakerInterval(speakerID: "A", start: 0, end: 1)],
                               voiceprints: [:], speakerLabels: ["A": "Speaker 1"])
        }
        XCTAssertEqual(analysis.segments[1].speaker, "Speaker 1")
        XCTAssertEqual(analysis.segments[1].start, 3)
    }

    func testCancelledAnalysisPreservesCorrectedTranscriptAndOriginalEvidence() async {
        var document = meetingFixture()
        document.normalizeSpeakerIdentities()
        document.speakerEditsApplied = true
        document.detectedSpeakers = document.speakers
        let analysis = await SpeakerAnalysis.run(document, folder: URL(fileURLWithPath: "/unused"), model: .community1,
                                                 analyzeImports: false) { _, _, _ in
            throw CancellationError()
        }
        let updated = SpeakerAnalysis.applying(analysis, to: document, basedOn: document)
        XCTAssertEqual(updated.segments, document.segments)
        XCTAssertEqual(updated.detectedSpeakers, document.detectedSpeakers)
        XCTAssertEqual(updated.speakerAnalysisStatus, .failed)
        XCTAssertNotNil(updated.speakerAnalysisError)
    }

    func testSpeakerFailurePreservesReadyTranscriptAndPreviousDetection() async {
        var document = meetingFixture()
        document.normalizeSpeakerIdentities()
        document.detectedSpeakers = document.speakers
        document.speakerEditsApplied = true
        let analysis = await SpeakerAnalysis.run(document, folder: URL(fileURLWithPath: "/unused"), model: .community1,
                                                 analyzeImports: false) { _, _, _ in
            throw NSError(domain: "Model unavailable", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Model file missing"])
        }
        let updated = SpeakerAnalysis.applying(analysis, to: document, basedOn: document)
        XCTAssertEqual(updated.status, .ready)
        XCTAssertEqual(updated.segments, document.segments)
        XCTAssertEqual(updated.speakers, document.speakers)
        XCTAssertEqual(updated.detectedSpeakers, document.detectedSpeakers)
        XCTAssertEqual(updated.speakerAnalysisStatus, .failed)
        XCTAssertEqual(updated.speakerAnalysisError, "Model file missing")
    }

    func testCommunityCountIsAnExplicitConstraintAndShortRepliesAreRetained() throws {
        let automatic = try SpeakerDiarizer.communityConfiguration(expectedSpeakerCount: nil)
        XCTAssertNil(automatic.clustering.numSpeakers)
        let four = try SpeakerDiarizer.communityConfiguration(expectedSpeakerCount: 4)
        XCTAssertEqual(four.clustering.numSpeakers, 4)
        XCTAssertLessThanOrEqual(four.minSegmentDuration, 0.2)
        XCTAssertFalse(four.postProcessing.exclusiveSegments)
        XCTAssertThrowsError(try SpeakerDiarizer.communityConfiguration(expectedSpeakerCount: 0))
    }

    func testSortformerRejectsUnknownAndLargeCountsBeforeReadingAudioOrModels() async {
        let diarizer = SpeakerDiarizer()
        for count: Int? in [nil, 5] {
            do {
                _ = try await diarizer.intervals(for: URL(fileURLWithPath: "/does-not-exist"), model: .sortformer,
                                                  expectedSpeakerCount: count)
                XCTFail("The four-slot model must reject unsupported counts")
            } catch SpeakerDiarizer.AnalysisError.sortformerSpeakerLimit {
                // This guard must run before any file or model loading.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func meetingFixture() -> ScribeDocument {
        ScribeDocument(title: "Meeting", kind: .recording, status: .ready, tracks: [
            AudioTrack(source: .microphone, fileName: "mic.caf"),
            AudioTrack(source: .system, fileName: "call.caf"),
        ], segments: [
            TranscriptSegment(start: 0, end: 0.3, text: "Yes", source: .microphone),
            TranscriptSegment(start: 1, end: 2, text: "Hello", source: .system),
        ], microphoneSpeakerName: "Nikhil (Me)")
    }

    func testOneOtherPersonNeverInvokesAModelAndKeepsMicrophoneSeparate() async {
        let original = ScribeDocument(title: "One-to-one", kind: .recording, status: .ready, tracks: [
            AudioTrack(source: .microphone, fileName: "mic.caf"),
            AudioTrack(source: .system, fileName: "call.caf"),
        ], segments: [
            TranscriptSegment(start: 0, end: 0.3, text: "Yes", source: .microphone),
            TranscriptSegment(start: 1, end: 2, text: "Hello", source: .system),
            TranscriptSegment(start: 2, end: 3, text: "Different pitch", source: .system),
        ], microphoneSpeakerName: "Nikhil (Me)", expectedRemoteSpeakerCount: 1)
        let result = await SpeakerAnalysis.run(original, folder: URL(fileURLWithPath: "/unused"), model: .sortformer,
                                               analyzeImports: false) { _, _, _ in
            XCTFail("A one-to-one meeting must not load or invoke the diarization model")
            throw NSError(domain: "Unexpected model call", code: 1)
        }
        XCTAssertEqual(result.segments.map(\.speaker), ["Nikhil (Me)", "Speaker 1", "Speaker 1"])
        XCTAssertEqual(result.speakers?.count, 2)
        XCTAssertEqual(result.speakerAnalysisStatus, .complete)
        XCTAssertEqual(result.segments.map(\.id), original.segments.map(\.id))
        XCTAssertEqual(result.rawSegments, original.segments)
    }

    func testWhisperWordTimesAndProbabilitySurviveConversion() async {
        let decoded = TranscriptionResult(text: "Hello there.", segments: [
            TranscriptionSegment(start: 0, end: 1, text: "<|0.00|>Hello there.<|1.00|>", words: [
                WordTiming(word: "Hello", tokens: [], start: 0.1, end: 0.4, probability: 0.9),
                WordTiming(word: " there.", tokens: [], start: 0.5, end: 1, probability: 0.8),
            ]),
        ], language: "en", timings: TranscriptionTimings())
        let result = await Transcriber.segments(from: [decoded], source: .system)
        XCTAssertEqual(result[0].words?.count, 2)
        XCTAssertEqual(result[0].words?.last?.text, " there.")
        XCTAssertEqual(result[0].words?.last?.probability, 0.8)
        XCTAssertEqual(result[0].words?.last?.end, 1)
    }

    func testSpeakerChangeWithinSentenceKeepsEveryWordAndShortReply() {
        let words = [
            TranscriptWord(start: 0, end: 0.4, text: "Ready"),
            TranscriptWord(start: 0.4, end: 0.8, text: " now?"),
            TranscriptWord(start: 0.9, end: 1.1, text: " Yes."),
        ]
        let segment = TranscriptSegment(start: 0, end: 1.1, text: "Ready now? Yes.", source: .system, words: words)
        let result = SpeakerDiarizer.assignSpeakers(to: [segment], using: [
            SpeakerInterval(speakerID: "host", start: 0, end: 0.85),
            SpeakerInterval(speakerID: "guest", start: 0.9, end: 1.1),
        ])

        XCTAssertEqual(result.map(\.text), ["Ready now?", "Yes."])
        XCTAssertEqual(result.map(\.speaker), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(result.flatMap { $0.words ?? [] }, words)
        XCTAssertEqual(result.first?.id, segment.id)
        XCTAssertEqual(result.last?.start, 0.9)
        XCTAssertEqual(result.last?.end, 1.1)
    }
}
