import XCTest
@testable import Scribe

final class SpeakerEditingTests: XCTestCase {
    func testOldDocumentJSONUpgradesAndRoundTripsWithStableSpeakerIDs() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "title": "Old meeting", "createdAt": 0, "kind": "recording", "status": "ready", "duration": 3,
          "tracks": [{"source":"microphone","fileName":"mic.caf"},{"source":"system","fileName":"system.caf"}],
          "segments": [
            {"id":"00000000-0000-0000-0000-000000000002","start":0,"end":1,"text":"Hi.","source":"microphone","speaker":"Wrong microphone name"},
            {"id":"00000000-0000-0000-0000-000000000003","start":1,"end":3,"text":"Hello there.","source":"system","speaker":"Speaker 1"}
          ]
        }
        """
        var document = try JSONDecoder().decode(ScribeDocument.self, from: Data(json.utf8))
        XCTAssertNil(document.speakers)
        document.normalizeSpeakerIdentities()
        XCTAssertEqual(document.speakerName(for: document.segments[0]), "You")
        XCTAssertEqual(document.segments.map(\.text), ["Hi.", "Hello there."])
        XCTAssertEqual(document.segments.map(\.start), [0, 1])
        XCTAssertEqual(document.segments.map(\.end), [1, 3])
        let encoded = try JSONEncoder().encode(document)
        let reloaded = try JSONDecoder().decode(ScribeDocument.self, from: encoded)
        XCTAssertEqual(reloaded, document)
        XCTAssertFalse(document.restoreSpeakerEdits(SpeakerEditingSnapshot(document: meeting())))
    }

    func testDetectionEvidenceSurvivesRepeatedCorrectionsAndUndo() throws {
        var document = meeting()
        document.normalizeSpeakerIdentities()
        let remote = try XCTUnwrap(document.segments[1].speakerID)
        let original = document
        let snapshot = SpeakerEditingSnapshot(document: document)
        XCTAssertTrue(document.renameSpeaker(id: remote, to: "Jordan"))
        let detected = document.detectedSpeakers
        let assignments = document.detectedSpeakerAssignments
        XCTAssertTrue(document.mergeAllRemoteSpeakers(into: remote))
        XCTAssertTrue(document.renameSpeaker(id: remote, to: "Alex"))
        XCTAssertEqual(document.detectedSpeakers, detected)
        XCTAssertEqual(document.detectedSpeakerAssignments, assignments)
        XCTAssertTrue(document.restoreSpeakerEdits(snapshot))
        XCTAssertEqual(document.segments, original.segments)
        XCTAssertEqual(document.detectedSpeakers, detected)
        XCTAssertEqual(document.detectedSpeakerAssignments, assignments)
        XCTAssertNil(document.speakerEditsApplied)
    }

    func testAddingAndReassigningOneTurnDoesNotMergeOtherTurnsWithTheSameName() throws {
        var document = meeting()
        document.normalizeSpeakerIdentities()
        let original = try XCTUnwrap(document.segments[1].speakerID)
        let person = try XCTUnwrap(document.addRemoteSpeaker(name: "Jordan"))
        XCTAssertTrue(document.assignSpeaker(to: document.segments[1].id, speakerID: person))
        XCTAssertEqual(document.segments[4].speakerID, original)
        XCTAssertTrue(document.renameSpeaker(id: original, to: "Jordan"))
        document.normalizeSpeakerIdentities()
        XCTAssertNotEqual(document.segments[1].speakerID, document.segments[4].speakerID)
        XCTAssertEqual(document.speakerName(for: document.segments[1]), "Jordan")
        XCTAssertEqual(document.speakerName(for: document.segments[4]), "Jordan")
        XCTAssertEqual(document.speakers?.filter { $0.name == "Jordan" }.count, 2)
        XCTAssertNil(document.addRemoteSpeaker(name: " \n "))
        XCTAssertFalse(document.assignSpeaker(to: UUID(), speakerID: person))
        XCTAssertFalse(document.assignSpeaker(to: document.segments[1].id, speakerID: UUID()))
    }

    func testNamingAndOneOtherPersonModeKeepIdentitiesSeparateFromNamesAndProtectMicrophone() throws {
        var document = meeting()
        document.normalizeSpeakerIdentities()
        let microphone = try XCTUnwrap(document.segments[0].speakerID)
        let remote = try XCTUnwrap(document.segments[1].speakerID)
        let secondRemote = try XCTUnwrap(document.segments[2].speakerID)
        let personID = UUID()
        let voiceprints: [String: [Float]] = ["Speaker 1": [0.8, 0.2]]
        document.speakerVoiceprints = voiceprints
        XCTAssertTrue(document.renameSpeaker(id: remote, to: "  Nikhil (Me)  ", savedPersonID: personID))
        XCTAssertEqual(document.segments[1].speakerID, remote)
        XCTAssertEqual(document.segments[0].speakerID, microphone)
        XCTAssertEqual(document.speakers?.first { $0.id == remote }?.savedPersonID, personID)
        XCTAssertEqual(document.speakerName(for: document.segments[1]), "Nikhil (Me)")

        let protected = document
        XCTAssertFalse(document.renameSpeaker(id: microphone, to: "Someone else"))
        XCTAssertFalse(document.mergeSpeaker(id: microphone, into: remote))
        XCTAssertFalse(document.mergeSpeaker(id: remote, into: microphone))
        XCTAssertFalse(document.assignSpeaker(to: document.segments[0].id, speakerID: remote))
        XCTAssertFalse(document.assignSpeaker(to: document.segments[1].id, speakerID: microphone))
        XCTAssertEqual(document, protected)

        let snapshot = SpeakerEditingSnapshot(document: document)
        XCTAssertTrue(document.mergeAllRemoteSpeakers(into: secondRemote))
        XCTAssertEqual(document.segments.filter { $0.source == .system }.map(\.speakerID), [secondRemote, secondRemote, secondRemote])
        XCTAssertEqual(document.expectedRemoteSpeakerCount, 1)
        XCTAssertEqual(document.speakerVoiceprints, voiceprints)
        XCTAssertTrue(document.restoreSpeakerEdits(snapshot))
        XCTAssertNil(document.expectedRemoteSpeakerCount)
        XCTAssertEqual(document.speakers, protected.speakers)
        XCTAssertEqual(document.segments, protected.segments)
    }

    func testMergeCombinesEveryRemoteTurnAndUndoPreservesLaterTextEdits() throws {
        var document = meeting()
        document.normalizeSpeakerIdentities()
        let before = document
        let snapshot = SpeakerEditingSnapshot(document: document)
        let target = try XCTUnwrap(document.segments[1].speakerID)
        let source = try XCTUnwrap(document.segments[2].speakerID)

        XCTAssertTrue(document.mergeSpeaker(id: source, into: target))
        XCTAssertEqual(document.speakers?.filter { !$0.isMicrophone }.count, 1)
        XCTAssertEqual(document.segments.filter { $0.source == .system }.map(\.speakerID), [target, target, target])
        XCTAssertEqual(document.segments.map(\.text), before.segments.map(\.text))
        XCTAssertEqual(document.segments.map(\.start), before.segments.map(\.start))
        XCTAssertEqual(document.segments.map(\.end), before.segments.map(\.end))
        XCTAssertEqual(document.segments.map(\.words), before.segments.map(\.words))
        XCTAssertEqual(document.segments.filter { $0.source == .microphone }, before.segments.filter { $0.source == .microphone })
        XCTAssertEqual(document.detectedSpeakers, before.speakers)
        XCTAssertEqual(document.detectedSpeakerAssignments?.first { $0.segmentID == before.segments[2].id }?.speakerID, source)

        document.segments[2].text = "Corrected wording."
        XCTAssertTrue(document.restoreSpeakerEdits(snapshot))
        XCTAssertEqual(document.speakers, before.speakers)
        XCTAssertEqual(document.segments.map(\.speakerID), before.segments.map(\.speakerID))
        XCTAssertEqual(document.segments[2].text, "Corrected wording.")
        XCTAssertEqual(document.detectedSpeakers, before.speakers)
    }

    func testLegacyLabelsBecomeStableIdentitiesWithoutCombiningMicrophoneAndRemote() throws {
        var document = meeting()
        document.segments[0].speaker = "You"
        document.segments[1].speaker = "You"
        document.normalizeSpeakerIdentities()

        let microphone = try XCTUnwrap(document.segments[0].speakerID)
        let remote = try XCTUnwrap(document.segments[1].speakerID)
        XCTAssertNotEqual(microphone, remote)
        XCTAssertEqual(document.speakerName(for: document.segments[0]), "Nikhil (Me)")
        XCTAssertTrue(try XCTUnwrap(document.speakers?.first { $0.id == microphone }).isMicrophone)
        XCTAssertFalse(try XCTUnwrap(document.speakers?.first { $0.id == remote }).isMicrophone)

        let normalized = document
        document.normalizeSpeakerIdentities()
        XCTAssertEqual(document, normalized)
    }

    func testLegacyMicrophoneNamesDoNotBecomeSpuriousRemoteSpeakers() {
        var document = meeting()
        document.segments[0].speaker = "Old microphone label"
        document.segments[3].speaker = "Old microphone label"
        document.knownSpeakers = ["Old microphone label", "Speaker 1", "Speaker 2"]
        document.normalizeSpeakerIdentities()
        XCTAssertEqual(document.speakers?.filter { !$0.isMicrophone }.map(\.name), ["Speaker 1", "Speaker 2"])
        XCTAssertEqual(document.speakers?.filter(\.isMicrophone).map(\.name), ["Nikhil (Me)"])
    }

    private func meeting() -> ScribeDocument {
        ScribeDocument(
            title: "Synthetic meeting", kind: .recording, status: .ready,
            duration: 7,
            tracks: [
                AudioTrack(source: .microphone, fileName: "mic.caf"),
                AudioTrack(source: .system, fileName: "remote.caf"),
            ],
            segments: [
                TranscriptSegment(start: 0, end: 1, text: "Hello.", source: .microphone),
                TranscriptSegment(start: 1, end: 2, text: "Morning.", source: .system, speaker: "Speaker 1",
                                  words: [TranscriptWord(start: 1, end: 2, text: "Morning.")]),
                TranscriptSegment(start: 3, end: 4, text: "Yes?", source: .system, speaker: "Speaker 2"),
                TranscriptSegment(start: 4, end: 5, text: "I agree.", source: .microphone),
                TranscriptSegment(start: 5, end: 7, text: "Let's begin.", source: .system, speaker: "Speaker 1"),
            ],
            microphoneSpeakerName: "Nikhil (Me)"
        )
    }
}
