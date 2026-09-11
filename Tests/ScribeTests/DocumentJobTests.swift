import AVFoundation
import XCTest
@testable import Scribe

@MainActor
final class DocumentJobTests: XCTestCase {
    func testEnqueueSaveFailureDoesNoModelWorkAndCanRetry() async throws {
        let fixture = try JobFixture()
        defer { fixture.remove() }
        let engine = FixtureTranscriber()
        let queue = makeQueue(fixture, engine: engine)
        try fixture.blockSaves()
        queue.enqueue(fixture.id)
        XCTAssertTrue(queue.pendingSaveIDs.contains(fixture.id))
        XCTAssertTrue(queue.isBusy)
        XCTAssertEqual(fixture.document.status, .ready)
        let calls = await engine.loads
        XCTAssertEqual(calls, 0)
        try fixture.restoreSaves()
        queue.retrySave(fixture.id)
        try await waitFor { !queue.isBusy }
        XCTAssertEqual(fixture.document.status, .ready)
        XCTAssertFalse(fixture.document.segments.isEmpty)
        XCTAssertNil(queue.errors[fixture.id])
    }

    func testStartingSaveFailurePreventsModelLoad() async throws {
        let fixture = try JobFixture()
        defer { fixture.remove() }
        let engine = FixtureTranscriber()
        let queue = makeQueue(fixture, engine: engine)
        queue.enqueue(fixture.id)
        try fixture.blockSaves()
        try await waitFor { queue.currentDocumentID == nil }
        let calls = await engine.loads
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(queue.pendingSaveIDs.contains(fixture.id))
        XCTAssertEqual(fixture.document.status, .queued)
    }

    func testCompletedTranscriptWaitsForSaveAndRetryDoesNotDecodeAgain() async throws {
        let fixture = try JobFixture(source: .system)
        defer { fixture.remove() }
        let inference = InferenceCounter()
        var exports: [ScribeDocument] = []
        let engine = FixtureTranscriber { _, source, _ in
            try await fixture.blockSaves()
            return [TranscriptSegment(start: 0, end: 1, text: "Decoded words.", source: source)]
        }
        let queue = makeQueue(fixture, engine: engine, inference: inference, export: { exports.append($0) })
        queue.enqueue(fixture.id)
        try await waitFor { queue.currentDocumentID == nil }
        XCTAssertTrue(queue.pendingSaveIDs.contains(fixture.id))
        XCTAssertNil(queue.progress[fixture.id])
        XCTAssertEqual(fixture.document.status, .transcribing)
        XCTAssertTrue(exports.isEmpty)
        let firstInferences = await inference.calls
        XCTAssertEqual(firstInferences, 0)
        queue.enqueue(fixture.id)
        queue.retrySpeakerAnalysis(fixture.id)
        XCTAssertEqual(queue.pendingCount, 0)
        try fixture.restoreSaves()
        var edited = fixture.document
        edited.title = "Title edited while saving"
        edited.notes = [MeetingNote(time: 0, text: "Keep this note")]
        XCTAssertTrue(fixture.library.update(edited))
        queue.retrySave(fixture.id)
        try await waitFor { !queue.isBusy }
        let decodes = await engine.decodes
        let finalInferences = await inference.calls
        XCTAssertEqual(decodes, 1)
        XCTAssertEqual(finalInferences, 1)
        XCTAssertEqual(exports.count, 1)
        XCTAssertEqual(fixture.document.title, edited.title)
        XCTAssertEqual(fixture.document.notes, edited.notes)
        XCTAssertEqual(fixture.document.rawSegments?.first?.text, "Decoded words.")
        XCTAssertEqual(fixture.document.status, .ready)
        XCTAssertEqual(fixture.reopenedDocument()?.segments, fixture.document.segments)
    }

    func testAnalysisSaveFailureRetainsResultAndRetryPreservesLaterEdits() async throws {
        let fixture = try JobFixture(source: .system)
        defer { fixture.remove() }
        let inference = InferenceCounter { try await fixture.blockSaves() }
        var exports: [ScribeDocument] = []
        let engine = FixtureTranscriber()
        let queue = makeQueue(fixture, engine: engine, inference: inference, export: { exports.append($0) })
        queue.enqueue(fixture.id)
        try await waitFor { queue.currentDocumentID == nil }
        XCTAssertTrue(queue.pendingSaveIDs.contains(fixture.id))
        XCTAssertEqual(fixture.document.status, .ready)
        XCTAssertEqual(fixture.document.speakerAnalysisStatus, .running)
        XCTAssertTrue(exports.isEmpty)
        try fixture.restoreSaves()
        var edited = fixture.document
        edited.segments[0].text = "My correction while the save was pending."
        XCTAssertTrue(fixture.library.update(edited))
        queue.retrySave(fixture.id)
        try await waitFor { !queue.isBusy }
        let calls = await inference.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(fixture.document.segments, edited.segments)
        XCTAssertEqual(fixture.document.speakerAnalysisStatus, .complete)
        XCTAssertEqual(exports.count, 1)
        XCTAssertEqual(exports.first?.segments, edited.segments)
    }

    func testSpeakerStartSaveFailureDoesNotInfer() async throws {
        let fixture = try JobFixture(source: .system, text: "Existing transcript.")
        defer { fixture.remove() }
        let inference = InferenceCounter()
        let queue = makeQueue(fixture, inference: inference)
        queue.retrySpeakerAnalysis(fixture.id)
        try fixture.blockSaves()
        try await waitFor { queue.currentDocumentID == nil }
        let calls = await inference.calls
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(queue.pendingSaveIDs.contains(fixture.id))
        XCTAssertEqual(fixture.document.segments.first?.text, "Existing transcript.")
    }

    func testCancellationIgnoresLateDecodedOutputAndClearsProgress() async throws {
        let fixture = try JobFixture(text: "Original transcript.")
        defer { fixture.remove() }
        let gate = JobGate()
        let engine = FixtureTranscriber { _, source, progress in
            progress?(0.5, "In progress")
            await gate.wait()
            return [TranscriptSegment(start: 0, end: 1, text: "Late output", source: source)]
        }
        var exported = false
        let queue = makeQueue(fixture, engine: engine, export: { _ in exported = true })
        queue.enqueue(fixture.id)
        try await waitFor { await gate.isWaiting }
        queue.cancelCurrent()
        await gate.release()
        try await waitFor { !queue.isBusy }
        XCTAssertEqual(fixture.document.status, .failed)
        XCTAssertEqual(fixture.document.segments.first?.text, "Original transcript.")
        XCTAssertNotNil(fixture.document.failureReason)
        XCTAssertNil(queue.progress[fixture.id])
        XCTAssertNil(queue.livePreview[fixture.id])
        XCTAssertFalse(exported)
    }

    func testDeletingActiveDocumentNeverRecreatesManifestFromLateOutput() async throws {
        let fixture = try JobFixture()
        defer { fixture.remove() }
        let gate = JobGate()
        let engine = FixtureTranscriber { _, source, progress in
            await gate.wait()
            progress?(1, "Late preview")
            return [TranscriptSegment(start: 0, end: 1, text: "Late output", source: source)]
        }
        let queue = makeQueue(fixture, engine: engine)
        queue.enqueue(fixture.id)
        try await waitFor { await gate.isWaiting }
        XCTAssertTrue(fixture.library.delete(fixture.document))
        await gate.release()
        try await waitFor { !queue.isBusy }
        XCTAssertNil(fixture.library.document(id: fixture.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.folder.path))
        XCTAssertNil(queue.progress[fixture.id])
        XCTAssertNil(queue.livePreview[fixture.id])
        XCTAssertNil(queue.errors[fixture.id])
    }

    func testFailureStatusSaveCanRetryWithoutRunningModelAgain() async throws {
        let fixture = try JobFixture()
        defer { fixture.remove() }
        let engine = FixtureTranscriber { _, _, _ in
            try await fixture.blockSaves()
            throw URLError(.cannotDecodeContentData)
        }
        let queue = makeQueue(fixture, engine: engine)
        queue.enqueue(fixture.id)
        try await waitFor { queue.currentDocumentID == nil }
        XCTAssertTrue(queue.pendingSaveIDs.contains(fixture.id))
        try fixture.restoreSaves()
        queue.retrySave(fixture.id)
        try await waitFor { !queue.isBusy }
        let calls = await engine.decodes
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(fixture.document.status, .failed)
        XCTAssertNotNil(fixture.document.failureReason)
    }

    func testPartialDecodeRequiresConsentAndKeepsOriginalMediaReferences() async throws {
        let fixture = try JobFixture(source: .system)
        defer { fixture.remove() }
        try fixture.addMicrophoneTrack()
        let originalTracks = fixture.document.tracks
        let engine = FixtureTranscriber { _, source, _ in
            if source == .system { throw URLError(.cannotDecodeContentData) }
            return [TranscriptSegment(start: 0, end: 1, text: "My side.", source: source)]
        }
        let queue = makeQueue(fixture, engine: engine)
        queue.enqueue(fixture.id)
        try await waitFor { !queue.isBusy }
        XCTAssertEqual(fixture.document.status, .failed)
        XCTAssertTrue(fixture.document.segments.isEmpty)
        queue.enqueue(fixture.id, allowPartialAudio: true)
        try await waitFor { !queue.isBusy }
        XCTAssertEqual(fixture.document.status, .ready)
        XCTAssertEqual(fixture.document.tracks, originalTracks)
        XCTAssertEqual(fixture.document.segments.map(\.text), ["My side."])
        XCTAssertTrue(fixture.document.transcriptionWarning?.contains("App audio") == true)
    }

    func testCancellationDuringAnalysisPreservesSavedTranscriptAndDetection() async throws {
        let fixture = try JobFixture(source: .system, text: "Corrected words.")
        defer { fixture.remove() }
        var original = fixture.document
        original.normalizeSpeakerIdentities()
        original.detectedSpeakers = original.speakers
        original.speakerEditsApplied = true
        XCTAssertTrue(fixture.library.update(original))
        let gate = JobGate()
        let inference = InferenceCounter { await gate.wait() }
        var exported = false
        let queue = makeQueue(fixture, inference: inference, export: { _ in exported = true })
        queue.retrySpeakerAnalysis(fixture.id)
        try await waitFor { await gate.isWaiting }
        queue.cancel(fixture.id)
        await gate.release()
        try await waitFor { !queue.isBusy }
        XCTAssertEqual(fixture.document.status, .ready)
        XCTAssertEqual(fixture.document.segments, original.segments)
        XCTAssertEqual(fixture.document.detectedSpeakers, original.detectedSpeakers)
        XCTAssertEqual(fixture.document.speakerAnalysisStatus, .failed)
        XCTAssertFalse(exported)
    }

    func testEditsMadeDuringDecodingBypassAutomaticCleanupAndKeepRawTranscript() async throws {
        let fixture = try JobFixture(text: "Original transcript.")
        defer { fixture.remove() }
        let gate = JobGate()
        let engine = FixtureTranscriber { _, source, _ in
            await gate.wait()
            return [TranscriptSegment(start: 0, end: 1, text: "Fresh decoding.", source: source)]
        }
        let queue = TranscriptionQueue(transcriber: engine, exportAutomatically: { _ in })
        queue.configure(library: fixture.library, options: { .init(model: "fixture") }, cleanup: { segments in
            segments.map { segment in
                var changed = segment
                changed.text = "Automatic replacement"
                return changed
            }
        })
        queue.enqueue(fixture.id)
        try await waitFor { await gate.isWaiting }
        var edited = fixture.document
        edited.segments[0].text = "My explicit correction."
        XCTAssertTrue(fixture.library.update(edited))
        await gate.release()
        try await waitFor { !queue.isBusy }
        XCTAssertEqual(fixture.document.segments.map(\.text), ["My explicit correction."])
        XCTAssertEqual(fixture.document.rawSegments?.map(\.text), ["Original transcript."])
    }

    func testQueueDeduplicatesAndContinuesNextDocumentAfterCancellation() async throws {
        let fixture = try JobFixture()
        defer { fixture.remove() }
        var second = fixture.document
        second.id = UUID()
        second.title = "Second generated document"
        XCTAssertTrue(fixture.library.add(second))
        try FileManager.default.copyItem(at: fixture.folder.appendingPathComponent("audio.caf"),
                                         to: fixture.library.folder(for: second.id).appendingPathComponent("audio.caf"))
        let gate = JobGate()
        let firstID = fixture.id
        let engine = FixtureTranscriber { file, source, _ in
            if file.path.contains(firstID.uuidString) { await gate.wait() }
            return [TranscriptSegment(start: 0, end: 1, text: "Decoded words.", source: source)]
        }
        var exported: [UUID] = []
        let queue = makeQueue(fixture, engine: engine, export: { exported.append($0.id) })
        queue.enqueue(fixture.id)
        queue.enqueue(fixture.id)
        queue.enqueue(second.id)
        try await waitFor { await gate.isWaiting }
        XCTAssertEqual(queue.pendingCount, 1)
        queue.cancelCurrent()
        await gate.release()
        try await waitFor { !queue.isBusy }
        XCTAssertEqual(fixture.document.status, .failed)
        XCTAssertEqual(fixture.library.document(id: second.id)?.status, .ready)
        XCTAssertEqual(exported, [second.id])
        let loads = await engine.loads
        XCTAssertEqual(loads, 2)
    }

    func testCancellingQueuedDocumentLeavesActiveTranscriptionRunning() async throws {
        let fixture = try JobFixture()
        defer { fixture.remove() }
        var queued = fixture.document
        queued.id = UUID()
        XCTAssertTrue(fixture.library.add(queued))
        let gate = JobGate()
        let engine = FixtureTranscriber { _, source, _ in
            await gate.wait()
            return [TranscriptSegment(start: 0, end: 1, text: "Finished active recording", source: source)]
        }
        let queue = makeQueue(fixture, engine: engine)
        queue.enqueue(fixture.id)
        queue.enqueue(queued.id)
        try await waitFor { await gate.isWaiting }
        queue.cancel(queued.id)
        XCTAssertEqual(queue.currentDocumentID, fixture.id)
        XCTAssertEqual(queue.pendingCount, 0)
        XCTAssertEqual(fixture.library.document(id: queued.id)?.status, .failed)
        await gate.release()
        try await waitFor { !queue.isBusy }
        XCTAssertEqual(fixture.document.status, .ready)
        let calls = await engine.decodes
        XCTAssertEqual(calls, 1)
    }

    func testQuitRetriesCompletedTranscriptWithoutStartingSpeakerModel() async throws {
        let fixture = try JobFixture(source: .system)
        defer { fixture.remove() }
        let inference = InferenceCounter()
        let engine = FixtureTranscriber { _, source, _ in
            try await fixture.blockSaves()
            return [TranscriptSegment(start: 0, end: 1, text: "Completed before quit.", source: source)]
        }
        let queue = makeQueue(fixture, engine: engine, inference: inference)
        queue.enqueue(fixture.id)
        try await waitFor { queue.currentDocumentID == nil }
        let blocked = await queue.prepareToQuit()
        XCTAssertFalse(blocked)
        XCTAssertTrue(queue.pendingSaveIDs.contains(fixture.id))
        try fixture.restoreSaves()
        let saved = await queue.prepareToQuit()
        XCTAssertTrue(saved)
        XCTAssertFalse(queue.isBusy)
        let decodes = await engine.decodes
        let inferences = await inference.calls
        XCTAssertEqual(decodes, 1)
        XCTAssertEqual(inferences, 0)
        XCTAssertEqual(fixture.reopenedDocument()?.segments.first?.text, "Completed before quit.")
    }

    func testQuitCancelsActiveAndQueuedWorkWithoutPumpingAnotherModel() async throws {
        let fixture = try JobFixture()
        defer { fixture.remove() }
        var second = fixture.document
        second.id = UUID()
        second.title = "Queued at quit"
        XCTAssertTrue(fixture.library.add(second))
        let gate = JobGate()
        let engine = FixtureTranscriber { _, source, _ in
            await gate.wait()
            return [TranscriptSegment(start: 0, end: 1, text: "Ignored after quit", source: source)]
        }
        let queue = makeQueue(fixture, engine: engine)
        queue.enqueue(fixture.id)
        queue.enqueue(second.id)
        try await waitFor { await gate.isWaiting }
        let quitting = Task { await queue.prepareToQuit() }
        try await waitFor { queue.pendingCount == 0 }
        await gate.release()
        let saved = await quitting.value
        XCTAssertTrue(saved)
        XCTAssertFalse(queue.isBusy)
        XCTAssertEqual(fixture.document.status, .failed)
        XCTAssertEqual(fixture.library.document(id: second.id)?.status, .failed)
        let loads = await engine.loads
        XCTAssertEqual(loads, 1)
    }

    private func makeQueue(_ fixture: JobFixture, engine: FixtureTranscriber = FixtureTranscriber(),
                           inference: InferenceCounter = InferenceCounter(),
                           export: @escaping (ScribeDocument) -> Void = { _ in }) -> TranscriptionQueue {
        let queue = TranscriptionQueue(transcriber: engine,
                                       inferSpeakers: { _, _, _ in try await inference.run() },
                                       exportAutomatically: export)
        queue.configure(library: fixture.library, options: { .init(model: "fixture") })
        return queue
    }
}

@MainActor
final class SummaryJobTests: XCTestCase {
    func testOneAppOwnedJobSurvivesRepeatedStartsAndReportsPersistedCompletion() async throws {
        let fixture = try JobFixture(text: "Original transcript.")
        defer { fixture.remove() }
        let gate = JobGate()
        var calls = 0
        let jobs = SummaryJobs { _ in
            calls += 1
            await gate.wait()
            return "A concise summary."
        }
        jobs.configure(library: fixture.library)
        jobs.start(fixture.id)
        jobs.start(fixture.id)
        try await waitFor { await gate.isWaiting }
        jobs.start(fixture.id)
        XCTAssertTrue(jobs.runningIDs.contains(fixture.id))
        XCTAssertTrue(jobs.isBusy)
        XCTAssertEqual(calls, 1)
        await gate.release()
        try await waitFor { !jobs.isBusy }
        XCTAssertEqual(jobs.completionCounts[fixture.id], 1)
        XCTAssertEqual(fixture.reopenedDocument()?.summary, "A concise summary.")
    }

    func testFailedSummarySaveRetainsResultForRetryWithoutRegeneration() async throws {
        let fixture = try JobFixture(text: "Original transcript.")
        defer { fixture.remove() }
        var calls = 0
        let jobs = SummaryJobs { _ in
            calls += 1
            try fixture.blockSaves()
            return "A retained summary."
        }
        jobs.configure(library: fixture.library)
        jobs.start(fixture.id)
        try await waitFor { jobs.runningIDs.isEmpty }
        XCTAssertTrue(jobs.pendingSaveIDs.contains(fixture.id))
        XCTAssertNil(fixture.document.summary)
        XCTAssertNil(jobs.completionCounts[fixture.id])
        jobs.start(fixture.id)
        XCTAssertEqual(calls, 1)
        try fixture.restoreSaves()
        jobs.retrySave(fixture.id)
        XCTAssertFalse(jobs.isBusy)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(jobs.completionCounts[fixture.id], 1)
        XCTAssertEqual(fixture.reopenedDocument()?.summary, "A retained summary.")
    }

    func testRetryOfRetainedSummaryRejectsNewTranscriptAndAllowsRegeneration() async throws {
        let fixture = try JobFixture(text: "Original transcript.")
        defer { fixture.remove() }
        let jobs = SummaryJobs { _ in
            try fixture.blockSaves()
            return "A stale summary."
        }
        jobs.configure(library: fixture.library)
        jobs.start(fixture.id)
        try await waitFor { jobs.runningIDs.isEmpty }
        try fixture.restoreSaves()
        var edited = fixture.document
        edited.segments[0].text = "Changed while the save was pending."
        XCTAssertTrue(fixture.library.update(edited))
        jobs.retrySave(fixture.id)
        XCTAssertFalse(jobs.isBusy)
        XCTAssertNil(fixture.document.summary)
        XCTAssertNil(jobs.completionCounts[fixture.id])
        XCTAssertTrue(jobs.errors[fixture.id]?.contains("changed") == true)
    }

    func testDeletionDuringSummaryGenerationIgnoresLateResult() async throws {
        let fixture = try JobFixture(text: "Original transcript.")
        defer { fixture.remove() }
        let gate = JobGate()
        let jobs = SummaryJobs { _ in
            await gate.wait()
            return "Late summary."
        }
        jobs.configure(library: fixture.library)
        jobs.start(fixture.id)
        try await waitFor { await gate.isWaiting }
        XCTAssertTrue(fixture.library.delete(fixture.document))
        await gate.release()
        await Task.yield()
        XCTAssertFalse(jobs.isBusy)
        XCTAssertNil(fixture.library.document(id: fixture.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.folder.path))
        XCTAssertNil(jobs.errors[fixture.id])
        XCTAssertNil(jobs.completionCounts[fixture.id])
    }

    func testCancellationBeforeTaskStartsDoesNotCallGenerator() async throws {
        let fixture = try JobFixture(text: "Original transcript.")
        defer { fixture.remove() }
        var calls = 0
        let jobs = SummaryJobs { _ in
            calls += 1
            return "Unnecessary generation."
        }
        jobs.configure(library: fixture.library)
        jobs.start(fixture.id)
        jobs.cancel(fixture.id)
        try await waitFor { !jobs.isBusy }
        XCTAssertEqual(calls, 0)
        XCTAssertNil(fixture.document.summary)
    }

    func testCancellationKeepsPriorSummaryAndRejectsLateGeneratorResult() async throws {
        let fixture = try JobFixture(text: "Original transcript.")
        defer { fixture.remove() }
        var document = fixture.document
        document.summary = "Keep the saved summary."
        XCTAssertTrue(fixture.library.update(document))
        let gate = JobGate()
        let jobs = SummaryJobs { _ in
            await gate.wait()
            return "Late summary."
        }
        jobs.configure(library: fixture.library)
        jobs.start(fixture.id)
        try await waitFor { await gate.isWaiting }
        jobs.cancel(fixture.id)
        await gate.release()
        try await waitFor { !jobs.isBusy }
        XCTAssertEqual(fixture.document.summary, document.summary)
        XCTAssertNil(jobs.completionCounts[fixture.id])
        XCTAssertTrue(jobs.errors[fixture.id]?.contains("cancelled") == true)
    }

    func testQuitRetriesRetainedSummaryAndBlocksWhileItsSaveStillFails() async throws {
        let fixture = try JobFixture(text: "Original transcript.")
        defer { fixture.remove() }
        var calls = 0
        let jobs = SummaryJobs { _ in
            calls += 1
            try fixture.blockSaves()
            return "Retained before quit."
        }
        jobs.configure(library: fixture.library)
        jobs.start(fixture.id)
        try await waitFor { jobs.runningIDs.isEmpty }
        let blocked = await jobs.prepareToQuit()
        XCTAssertFalse(blocked)
        XCTAssertTrue(jobs.pendingSaveIDs.contains(fixture.id))
        try fixture.restoreSaves()
        let saved = await jobs.prepareToQuit()
        XCTAssertTrue(saved)
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(jobs.isBusy)
        XCTAssertEqual(fixture.reopenedDocument()?.summary, "Retained before quit.")
    }

    func testConcurrentNotesAndInvalidGenerationNeverReplaceExistingSummary() async throws {
        let fixture = try JobFixture(text: "Original transcript.")
        defer { fixture.remove() }
        let gate = JobGate()
        let jobs = SummaryJobs { _ in
            await gate.wait()
            return "Stale summary."
        }
        jobs.configure(library: fixture.library)
        jobs.start(fixture.id)
        try await waitFor { await gate.isWaiting }
        var document = fixture.document
        document.notes = [MeetingNote(time: 1, text: "A later note")]
        XCTAssertTrue(fixture.library.update(document))
        await gate.release()
        try await waitFor { !jobs.isBusy }
        XCTAssertNil(fixture.document.summary)
        XCTAssertNotNil(jobs.errors[fixture.id])
        let invalid = SummaryJobs { _ in "" }
        invalid.configure(library: fixture.library)
        invalid.start(fixture.id)
        try await waitFor { !invalid.isBusy }
        XCTAssertNotNil(invalid.errors[fixture.id])
        XCTAssertNil(fixture.document.summary)
    }

    func testSummaryCompletingBeforeRetranscriptionIsRetainedAsStale() async throws {
        let fixture = try JobFixture(text: "Original transcript.")
        defer { fixture.remove() }
        let summaryGate = JobGate()
        let decodeGate = JobGate()
        let summaries = SummaryJobs { _ in
            await summaryGate.wait()
            return "Summary of the original transcript."
        }
        summaries.configure(library: fixture.library)
        let engine = FixtureTranscriber { _, source, _ in
            await decodeGate.wait()
            return [TranscriptSegment(start: 0, end: 1, text: "Replacement transcript.", source: source)]
        }
        let queue = makeQueue(fixture, engine: engine)

        summaries.start(fixture.id)
        try await waitFor { await summaryGate.isWaiting }
        queue.enqueue(fixture.id)
        try await waitFor { await decodeGate.isWaiting }
        await summaryGate.release()
        try await waitFor { !summaries.isBusy }
        XCTAssertEqual(fixture.document.summary, "Summary of the original transcript.")
        XCTAssertFalse(fixture.document.summaryIsStale == true)

        await decodeGate.release()
        try await waitFor { !queue.isBusy }
        XCTAssertEqual(fixture.document.segments.map(\.text), ["Replacement transcript."])
        XCTAssertEqual(fixture.document.summary, "Summary of the original transcript.")
        XCTAssertTrue(fixture.document.summaryIsStale == true)
    }

    func testRetranscriptionCompletingBeforeSummaryRejectsLateResultAndRegenerationClearsStale() async throws {
        let fixture = try JobFixture(text: "Original transcript.")
        defer { fixture.remove() }
        var document = fixture.document
        document.summary = "Prior summary."
        document.summaryIsStale = false
        XCTAssertTrue(fixture.library.update(document))
        let summaryGate = JobGate()
        let summaries = SummaryJobs { _ in
            await summaryGate.wait()
            return "Late replacement summary."
        }
        summaries.configure(library: fixture.library)
        let engine = FixtureTranscriber { _, source, _ in
            [TranscriptSegment(start: 0, end: 1, text: "Replacement transcript.", source: source)]
        }
        let queue = makeQueue(fixture, engine: engine)

        summaries.start(fixture.id)
        try await waitFor { await summaryGate.isWaiting }
        queue.enqueue(fixture.id)
        try await waitFor { !queue.isBusy }
        XCTAssertEqual(fixture.document.summary, "Prior summary.")
        XCTAssertTrue(fixture.document.summaryIsStale == true)

        await summaryGate.release()
        try await waitFor { !summaries.isBusy }
        XCTAssertEqual(fixture.document.summary, "Prior summary.")
        XCTAssertTrue(fixture.document.summaryIsStale == true)
        XCTAssertTrue(summaries.errors[fixture.id]?.contains("changed") == true)

        let regeneration = SummaryJobs { _ in "Prior summary." }
        regeneration.configure(library: fixture.library)
        regeneration.start(fixture.id)
        try await waitFor { !regeneration.isBusy }
        XCTAssertEqual(fixture.document.summary, "Prior summary.")
        XCTAssertFalse(fixture.document.summaryIsStale == true)
    }

    func testTranscriptAndSummaryPendingResultsRetryWithoutLosingEitherResult() async throws {
        let fixture = try JobFixture(text: "Original transcript.")
        defer { fixture.remove() }
        var document = fixture.document
        document.summary = "Prior summary."
        document.summaryIsStale = false
        XCTAssertTrue(fixture.library.update(document))
        let summaryGate = JobGate()
        let decodeGate = JobGate()
        var summaryCalls = 0
        let summaries = SummaryJobs { _ in
            summaryCalls += 1
            await summaryGate.wait()
            return "Retained generated summary."
        }
        summaries.configure(library: fixture.library)
        let engine = FixtureTranscriber { _, source, _ in
            await decodeGate.wait()
            return [TranscriptSegment(start: 0, end: 1, text: "Retained decoded transcript.", source: source)]
        }
        let queue = makeQueue(fixture, engine: engine)

        summaries.start(fixture.id)
        try await waitFor { await summaryGate.isWaiting }
        queue.enqueue(fixture.id)
        try await waitFor { await decodeGate.isWaiting }
        try fixture.blockSaves()
        await summaryGate.release()
        await decodeGate.release()
        try await waitFor { summaries.pendingSaveIDs.contains(fixture.id) }
        try await waitFor { queue.pendingSaveIDs.contains(fixture.id) && queue.currentDocumentID == nil }

        try fixture.restoreSaves()
        summaries.retrySave(fixture.id)
        queue.retrySave(fixture.id)
        try await waitFor { !queue.isBusy }

        let decodeCalls = await engine.decodes
        XCTAssertEqual(summaryCalls, 1)
        XCTAssertEqual(decodeCalls, 1)
        XCTAssertFalse(summaries.isBusy)
        XCTAssertEqual(fixture.document.summary, "Retained generated summary.")
        XCTAssertEqual(fixture.document.segments.map(\.text), ["Retained decoded transcript."])
        XCTAssertTrue(fixture.document.summaryIsStale == true)
    }

    private func makeQueue(_ fixture: JobFixture, engine: FixtureTranscriber) -> TranscriptionQueue {
        let queue = TranscriptionQueue(
            transcriber: engine,
            inferSpeakers: { _, _, _ in SpeakerDiarization(intervals: [], voiceprints: [:], speakerLabels: [:]) },
            exportAutomatically: { _ in }
        )
        queue.configure(library: fixture.library, options: { .init(model: "fixture") })
        return queue
    }
}

@MainActor
private func waitFor(_ predicate: () async -> Bool) async throws {
    for _ in 0..<2_000 {
        if await predicate() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    throw NSError(domain: "DocumentJobTests", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for controlled job completion."])
}

private actor JobGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            isWaiting = true
        }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor FixtureTranscriber: TranscriptionEngine {
    typealias Decode = @Sendable (URL, AudioSource, (@Sendable (Double, String) -> Void)?) async throws -> [TranscriptSegment]
    private let decode: Decode
    private(set) var loads = 0
    private(set) var decodes = 0
    init(decode: @escaping Decode = { _, source, _ in
        [TranscriptSegment(start: 0, end: 1, text: "Decoded words.", source: source)]
    }) { self.decode = decode }
    func load(model: String) async throws { loads += 1 }
    nonisolated func cancelCurrent() {}
    func transcribe(file: URL, source: AudioSource, language: String?, translate: Bool,
                    onProgress: (@Sendable (Double, String) -> Void)?) async throws -> [TranscriptSegment] {
        decodes += 1
        return try await decode(file, source, onProgress)
    }
}

private actor InferenceCounter {
    private let action: @Sendable () async throws -> Void
    private(set) var calls = 0
    init(action: @escaping @Sendable () async throws -> Void = {}) { self.action = action }
    func run() async throws -> SpeakerDiarization {
        calls += 1
        try await action()
        return SpeakerDiarization(intervals: [SpeakerInterval(speakerID: "one", start: 0, end: 2)],
                                  voiceprints: [:], speakerLabels: ["one": "Speaker 1"])
    }
}

@MainActor
private final class JobFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kleio-job-test-" + UUID().uuidString)
    let library: LibraryStore
    let id: UUID
    var document: ScribeDocument { library.document(id: id)! }
    var folder: URL { library.folder(for: id) }
    private var manifest: URL { folder.appendingPathComponent("document.json") }
    private var savedManifest: URL { folder.appendingPathComponent("saved-document.json") }

    init(source: AudioSource = .microphone, text: String? = nil) throws {
        library = LibraryStore(baseURL: root)
        let doc = ScribeDocument(title: "Generated fixture", kind: .recording, status: .ready,
                                tracks: [AudioTrack(source: source, fileName: "audio.caf")],
                                segments: text.map { [TranscriptSegment(start: 0, end: 1, text: $0, source: source)] } ?? [])
        id = doc.id
        guard library.add(doc) else { throw NSError(domain: "JobFixture", code: 1) }
        try writeAudio(folder.appendingPathComponent("audio.caf"))
    }
    func addMicrophoneTrack() throws {
        var doc = document
        doc.tracks.append(AudioTrack(source: .microphone, fileName: "microphone.caf"))
        guard library.update(doc) else { throw NSError(domain: "JobFixture", code: 2) }
        try writeAudio(folder.appendingPathComponent("microphone.caf"))
    }
    func blockSaves() throws {
        try FileManager.default.moveItem(at: manifest, to: savedManifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
    }
    func restoreSaves() throws {
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.moveItem(at: savedManifest, to: manifest)
    }
    func reopenedDocument() -> ScribeDocument? {
        LibraryStore(baseURL: root).document(id: id)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    private func writeAudio(_ url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600)!
        buffer.frameLength = 1_600
        buffer.floatChannelData![0].initialize(repeating: 0.1, count: 1_600)
        try file.write(from: buffer)
    }
}
