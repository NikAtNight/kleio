import XCTest
@testable import Scribe

final class SavedPeopleStoreTests: XCTestCase {
    @MainActor
    func testUnreadableSavedPeopleFileIsKeptAndBlocksWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("saved-people.json")
        let original = Data("incomplete json".utf8)
        try original.write(to: file)

        let store = SavedPeopleStore(directory: directory, seedNames: ["Must not replace the old file"])
        XCTAssertNotNil(store.lastError)
        XCTAssertThrowsError(try store.add(name: "Jordan"))
        XCTAssertTrue(store.people.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    @MainActor
    func testFailedSaveDoesNotPublishAPersonAndCanBeRetried() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blockedDirectory = directory.appendingPathComponent("not-a-directory")
        try Data("fixture".utf8).write(to: blockedDirectory)
        let store = SavedPeopleStore(directory: blockedDirectory)
        XCTAssertThrowsError(try store.add(name: "Jordan"))
        XCTAssertTrue(store.people.isEmpty)
        XCTAssertNotNil(store.lastError)

        try FileManager.default.removeItem(at: blockedDirectory)
        let saved = try store.add(name: "Jordan")
        XCTAssertEqual(store.people, [saved])
        XCTAssertEqual(SavedPeopleStore(directory: blockedDirectory).people, [saved])
        XCTAssertNil(store.lastError)
    }

    @MainActor
    func testSeedingNamesCopiesNamesWithoutTouchingVoiceProfiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let voiceFile = directory.appendingPathComponent("voice-profiles.json")
        let profile = VoiceProfile(name: "Jordan", centroids: [[0.8, 0.2]], sampleCount: 3, updatedAt: Date(timeIntervalSince1970: 0))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let original = try encoder.encode([profile])
        try original.write(to: voiceFile)
        let voices = VoiceProfileStore(fileURL: voiceFile)
        let people = SavedPeopleStore(directory: directory, seedNames: voices.profiles.map(\.name) + ["jordan", " "])
        XCTAssertEqual(people.people.map(\.name), ["Jordan"])
        XCTAssertEqual(voices.profiles, [profile])
        XCTAssertEqual(try Data(contentsOf: voiceFile), original)
        XCTAssertEqual(SavedPeopleStore(directory: directory, seedNames: ["New seed must not overwrite"]).people, people.people)
    }

    @MainActor
    func testExplicitlySavedNamesPersistWithStableIDsAndDocumentCorrectionsDoNotRenameThem() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SavedPeopleStore(directory: directory)
        let person = try store.add(name: "  Jordan  ")
        XCTAssertEqual(person.name, "Jordan")
        XCTAssertEqual(try store.add(name: "jordan").id, person.id)

        let reloaded = SavedPeopleStore(directory: directory)
        XCTAssertEqual(reloaded.people, [person])
        let speaker = DocumentSpeaker(name: "Speaker 1")
        var document = ScribeDocument(
            title: "Fixture", kind: .recording, status: .ready,
            segments: [TranscriptSegment(start: 0, end: 1, text: "Hello", source: .system, speakerID: speaker.id)],
            speakers: [speaker]
        )
        document.normalizeSpeakerIdentities()
        XCTAssertTrue(document.renameSpeaker(id: speaker.id, to: person.name, savedPersonID: person.id))
        XCTAssertTrue(document.renameSpeaker(id: speaker.id, to: "Different name"))
        XCTAssertEqual(SavedPeopleStore(directory: directory).people, [person])
        XCTAssertEqual(store.people, [person])
    }
}
