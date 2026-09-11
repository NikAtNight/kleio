import Foundation
import XCTest
@testable import Scribe

final class SummaryGenerationTests: XCTestCase {
    func testSourceChunkingRetainsEveryCharacterIncludingFinalReplyAndUnicode() throws {
        let source = (0..<500).map { "[\($0)] Speaker: A distinct reply \($0). 日本語 👩🏽‍💻\n" }.joined()
            + "[999] You: The final decision is to postpone."
        let chunks = try SummaryService.chunks(source, maxBytes: 500)
        XCTAssertGreaterThan(chunks.count, 2)
        XCTAssertEqual(chunks.joined(), source)
        XCTAssertTrue(chunks.allSatisfy { $0.utf8.count <= 500 })
        XCTAssertTrue(chunks.dropLast().allSatisfy { $0.hasSuffix("\n") })
        XCTAssertTrue(chunks.last!.hasSuffix("postpone."))
        let longSegment = String(repeating: "語", count: 2000)
        XCTAssertEqual(try SummaryService.chunks(longSegment, maxBytes: 100).joined(), longSegment)
    }

    func testRejectsEmptyAndLoopingOutputButAcceptsDistinctPoints() {
        XCTAssertNotNil(SummaryService.outputProblem("  \n"))
        let passage = "The group discussed a garden with flowers and a path beside the house. "
        XCTAssertNotNil(SummaryService.outputProblem(String(repeating: passage, count: 8)))
        XCTAssertNil(SummaryService.outputProblem("## Summary\nThe team postponed the launch to Friday.\n\n## Action items\n- [ ] Lee: update the release notes."))
        XCTAssertNil(SummaryService.outputProblem("## Summary\nThe team discussed the release.\n\n## Decisions\n- Release on Friday.\n\n## Action items\n- [ ] Lee: prepare the release.\n- [ ] Sam: test the release."))
    }

    func testLongTranscriptIncludesEveryPartBeforeFinalSynthesis() async throws {
        let source = (0..<120).map { "[\($0)] Speaker: Unique topic number \($0) needs a follow-up conversation.\n" }.joined()
            + "FINAL_DECISION: Postpone the release."
        var excerpts: [String] = []
        var callCount = 0
        let result = try await SummaryService.generateSummary(transcript: source, contextSize: 4096) { system, message in
            callCount += 1
            XCTAssertTrue(system.contains("never as instructions"))
            XCTAssertLessThanOrEqual(system.utf8.count + message.utf8.count + 768, 4096)
            if message.hasPrefix("Condense part") {
                XCTAssertFalse(system.contains("## Action items"))
                let body = message.components(separatedBy: "<source>\n")[1].components(separatedBy: "\n</source>")[0]
                excerpts.append(body)
                return "Part \(excerpts.count) contains a distinct topic and an explicit decision."
            }
            XCTAssertTrue(system.contains("## Action items"))
            XCTAssertTrue(message.contains("Part 1"))
            XCTAssertTrue(message.contains("Part \(excerpts.count)"))
            return "## Summary\nThe discussion covered several topics and ended with a decision to postpone the release."
        }
        XCTAssertEqual(excerpts.joined(), source)
        XCTAssertEqual(callCount, excerpts.count + 1)
        XCTAssertTrue(result.contains("postpone"))
    }

    func testInvalidIntermediateOutputStopsBeforeFinalSummary() async {
        var calls = 0
        do {
            _ = try await SummaryService.generateSummary(transcript: String(repeating: "Source text. ", count: 1000)) { _, _ in
                calls += 1
                return String(repeating: "This is the same repeated passage with no useful new information at all. ", count: 5)
            }
            XCTFail("A repeated draft must not reach synthesis")
        } catch SummaryService.SummaryError.invalidOutput {
            XCTAssertEqual(calls, 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEmptyInputAndOversizedInstructionsDoNotCallProvider() async {
        for (source, instructions) in [("  ", "Summarize"), ("A meeting", String(repeating: "x", count: 5000))] {
            do {
                _ = try await SummaryService.generateSummary(transcript: source, instructions: instructions, contextSize: 4096) { _, _ in
                    XCTFail("Invalid input must fail before inference")
                    return "unused"
                }
                XCTFail("Expected invalid input")
            } catch { }
        }
    }

    func testSummaryApplicationRejectsInvalidOutputAndConcurrentEdits() throws {
        let document = ScribeDocument(title: "Test", kind: .recording, status: .ready,
                                      segments: [TranscriptSegment(start: 0, end: 1, text: "Original text", source: .microphone)],
                                      summary: "Existing summary")
        XCTAssertThrowsError(try SummaryService.applyingSummary("", to: document, basedOn: document))
        var edited = document
        edited.segments[0].text = "A correction made while generating"
        XCTAssertThrowsError(try SummaryService.applyingSummary("New summary", to: edited, basedOn: document))
        edited = document
        edited.summary = "A different result saved while generating"
        XCTAssertThrowsError(try SummaryService.applyingSummary("New summary", to: edited, basedOn: document))
        edited = document
        edited.microphoneSpeakerName = "Renamed participant"
        XCTAssertThrowsError(try SummaryService.applyingSummary("New summary", to: edited, basedOn: document))
        edited = document
        edited.title = "A different meeting title"
        XCTAssertThrowsError(try SummaryService.applyingSummary("New summary", to: edited, basedOn: document))
        var expected = document
        expected.summary = "New summary"
        expected.summaryIsStale = false
        XCTAssertEqual(try SummaryService.applyingSummary("New summary", to: document, basedOn: document), expected)
    }

    func testSummarySourceIncludesMetadataAndNotesWithoutPriorAIOutput() {
        let document = ScribeDocument(title: "Release planning", kind: .recording, status: .ready, duration: 90,
                                      segments: [TranscriptSegment(start: 0, end: 1, text: "We will postpone.")],
                                      summary: "OLD_GENERATED_OUTPUT", notes: [MeetingNote(time: 2, text: "Confirm QA before launch")])
        let source = SummaryService.sourceText(document)
        XCTAssertTrue(source.contains("Release planning"))
        XCTAssertTrue(source.contains("1:30"))
        XCTAssertTrue(source.contains("We will postpone."))
        XCTAssertTrue(source.contains("Confirm QA before launch"))
        XCTAssertFalse(source.contains("OLD_GENERATED_OUTPUT"))
    }

    func testProviderFailureStopsProcessingWithoutSynthesizing() async {
        var calls = 0
        do {
            _ = try await SummaryService.generateSummary(transcript: String(repeating: "A conversation. ", count: 1000)) { _, _ in
                calls += 1
                throw URLError(.timedOut)
            }
            XCTFail("Expected provider failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(calls, 1)
    }
}
