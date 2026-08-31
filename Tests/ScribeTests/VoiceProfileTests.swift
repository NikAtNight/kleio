import FluidAudio
import Foundation
import XCTest
@testable import Scribe

final class VoiceProfileTests: XCTestCase {
    func testCloseCentroidUsesCappedRunningAverage() {
        let centroids: [[Float]] = [[0, 1], [1, 0]]

        let updated = VoiceProfileStore.updatedCentroids(
            centroids,
            sampleCount: 2,
            adding: [0.8, 0.2]
        )

        XCTAssertEqual(updated.count, 2)
        XCTAssertEqual(updated[0], [0, 1])
        let expected = VoiceProfileStore.normalized([2.8 / 3, 0.2 / 3])
        XCTAssertEqual(updated[1][0], expected[0], accuracy: 0.0001)
        XCTAssertEqual(updated[1][1], expected[1], accuracy: 0.0001)
    }

    func testFourthDistinctCentroidEvictsOldest() {
        let centroids: [[Float]] = [
            [1, 0, 0, 0],
            [0, 1, 0, 0],
            [0, 0, 1, 0],
        ]

        let updated = VoiceProfileStore.updatedCentroids(
            centroids,
            sampleCount: 3,
            adding: [0, 0, 0, 1]
        )

        XCTAssertEqual(updated, [
            [0, 1, 0, 0],
            [0, 0, 1, 0],
            [0, 0, 0, 1],
        ])
    }

    func testMatchTiersUseStrictThresholds() {
        XCTAssertEqual(VoiceProfileStore.matchTier(for: 0.3499), .apply)
        XCTAssertEqual(VoiceProfileStore.matchTier(for: 0.35), .suggest)
        XCTAssertEqual(VoiceProfileStore.matchTier(for: 0.4499), .suggest)
        XCTAssertEqual(VoiceProfileStore.matchTier(for: 0.45), .none)
    }

    func testRenameRekeysDocumentVoiceprint() {
        var document = ScribeDocument(
            title: "Interview",
            kind: .imported,
            status: .ready,
            speakerVoiceprints: ["Speaker 1": [1, 0]]
        )

        document.rekeySpeakerVoiceprint(from: "Speaker 1", to: "Sam")

        XCTAssertNil(document.speakerVoiceprints?["Speaker 1"])
        XCTAssertEqual(document.speakerVoiceprints?["Sam"], [1, 0])
    }

    func testDocumentDecodesWithoutSpeakerVoiceprints() throws {
        let document = try decodeDocument(extraFields: "")
        XCTAssertNil(document.speakerVoiceprints)
    }

    func testDocumentDecodesWithSpeakerVoiceprints() throws {
        let document = try decodeDocument(
            extraFields: #", "speakerVoiceprints": {"Speaker 1": [0.25, 0.75]}"#
        )
        XCTAssertEqual(document.speakerVoiceprints?["Speaker 1"], [0.25, 0.75])
    }

    func testFallbackCentroidAveragesEmbeddingsByDuration() throws {
        let segments = [
            TimedSpeakerSegment(
                speakerId: "S1",
                embedding: [1, 0],
                startTimeSeconds: 0,
                endTimeSeconds: 1,
                qualityScore: 1
            ),
            TimedSpeakerSegment(
                speakerId: "S1",
                embedding: [0, 1],
                startTimeSeconds: 1,
                endTimeSeconds: 4,
                qualityScore: 1
            ),
        ]

        let voiceprints = SpeakerDiarizer.durationWeightedVoiceprints(from: segments)

        let centroid = try XCTUnwrap(voiceprints["S1"])
        XCTAssertEqual(centroid[0], 0.25, accuracy: 0.0001)
        XCTAssertEqual(centroid[1], 0.75, accuracy: 0.0001)
    }

    private func decodeDocument(extraFields: String) throws -> ScribeDocument {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "title": "Compatibility",
          "createdAt": "2026-01-02T03:04:05Z",
          "kind": "imported",
          "status": "ready",
          "duration": 1,
          "tracks": [],
          "segments": []\(extraFields)
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ScribeDocument.self, from: Data(json.utf8))
    }
}
