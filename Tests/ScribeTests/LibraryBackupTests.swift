import XCTest
@testable import Scribe

final class LibraryBackupTests: XCTestCase {
    private func fixture(_ parent: URL, title: String) throws -> (URL, ScribeDocument) {
        let root = parent.appendingPathComponent(UUID().uuidString)
        let doc = ScribeDocument(title: title, kind: .recording, status: .ready, duration: 2,
                                tracks: [AudioTrack(source: .microphone, fileName: "microphone.caf")],
                                segments: [TranscriptSegment(start: 0, end: 2, text: "A saved sentence", source: .microphone)],
                                summary: "A saved summary", notes: [MeetingNote(time: 1, text: "A note")])
        let folder = root.appendingPathComponent("library/\(doc.id.uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(doc).write(to: folder.appendingPathComponent("document.json"))
        try Data("synthetic media bytes".utf8).write(to: folder.appendingPathComponent("microphone.caf"))
        try JSONEncoder().encode([SavedPerson(name: "Remote")]).write(to: root.appendingPathComponent("saved-people.json"))
        try encoder.encode([VoiceProfile(name: title + " voice", centroids: [[1, 0, 0]], sampleCount: 1,
                                         updatedAt: Date(timeIntervalSince1970: 1234))])
            .write(to: root.appendingPathComponent("voice-profiles.json"))
        return (root, doc)
    }

    func testBackupRestoresMediaNotesPeopleAndPreferencesAndKeepsPreviousLibrary() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (source, doc) = try fixture(dir, title: "Restored meeting")
        let (target, old) = try fixture(dir, title: "Previous meeting")
        let model = target.appendingPathComponent("models/kept.bin")
        try FileManager.default.createDirectory(at: model.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("model stays put".utf8).write(to: model)
        let domain = "test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.setPersistentDomain(["language": "fr", "aiAPIKey": "dummy-original-key"], forName: domain)
        let backup = dir.appendingPathComponent("snapshot.kleiobackup")
        let manifest = try LibraryBackup.create(support: source, preferences: ["language": "en", "aiAPIKey": "dummy-excluded-key"], at: backup)
        XCTAssertEqual(manifest.recordingCount, 1)
        XCTAssertEqual(try LibraryBackup.inspect(backup).entries, manifest.entries)
        let previous = try LibraryBackup.restore(backup, support: target, defaults: defaults, domain: domain)
        XCTAssertEqual(try LibraryBackup.inspect(previous).recordingCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.appendingPathComponent("data/library/\(old.id.uuidString)/document.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("library/\(old.id.uuidString)").path))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("library/\(doc.id.uuidString)/document.json")),
                       try Data(contentsOf: target.appendingPathComponent("library/\(doc.id.uuidString)/document.json")))
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("saved-people.json")), try Data(contentsOf: target.appendingPathComponent("saved-people.json")))
        XCTAssertEqual(try String(contentsOf: model, encoding: .utf8), "model stays put")
        XCTAssertEqual(defaults.string(forKey: "language"), "en")
        XCTAssertEqual(defaults.string(forKey: "aiAPIKey"), "dummy-original-key")
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: backup.appendingPathComponent("preferences.plist")), format: nil) as? [String: Any])
        XCTAssertNil(plist["aiAPIKey"])
    }

    func testChangedMediaFailsValidationBeforeReplacingAnything() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (source, doc) = try fixture(dir, title: "Meeting")
        let backup = dir.appendingPathComponent("snapshot.kleiobackup")
        try LibraryBackup.create(support: source, preferences: [:], at: backup)
        try Data("changed".utf8).write(to: backup.appendingPathComponent("data/library/\(doc.id.uuidString)/microphone.caf"))
        let domain = "test.\(UUID().uuidString)"; let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        XCTAssertThrowsError(try LibraryBackup.restore(backup, support: source, defaults: defaults, domain: domain))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("library/\(doc.id.uuidString)/document.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent(".restore-journal.json").path))
    }

    func testFailedRestoreRollsBackEveryStageIncludingPreferences() throws {
        for checkpoint in ["preserved:library", "preserved:saved-people.json", "restored:library", "restored:voice-profiles.json", "preferences"] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: dir) }
            let (source, doc) = try fixture(dir, title: "New meeting")
            let (target, old) = try fixture(dir, title: "Old meeting")
            let oldPeople = try Data(contentsOf: target.appendingPathComponent("saved-people.json"))
            let oldVoices = try Data(contentsOf: target.appendingPathComponent("voice-profiles.json"))
            let backup = dir.appendingPathComponent("snapshot.kleiobackup")
            try LibraryBackup.create(support: source, preferences: ["language": "en"], at: backup)
            let domain = "test.\(UUID().uuidString)"; let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            defer { defaults.removePersistentDomain(forName: domain) }
            defaults.set("fr", forKey: "language")
            XCTAssertThrowsError(try LibraryBackup.restore(backup, support: target, defaults: defaults, domain: domain) { step in
                if step == checkpoint { throw NSError(domain: "fixture", code: 1) }
            })
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("library/\(old.id.uuidString)/document.json").path), checkpoint)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("library/\(doc.id.uuidString)").path), checkpoint)
            XCTAssertEqual(defaults.string(forKey: "language"), "fr", checkpoint)
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("saved-people.json")), oldPeople, checkpoint)
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("voice-profiles.json")), oldVoices, checkpoint)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent(".restore-journal.json").path), checkpoint)
        }
    }

    func testBackupRejectsLinksAndRefusesToOverwriteOrNest() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (source, doc) = try fixture(dir, title: "Meeting")
        XCTAssertThrowsError(try LibraryBackup.create(support: source, preferences: [:], at: source.appendingPathComponent("nested")))
        let backup = dir.appendingPathComponent("snapshot.kleiobackup")
        try LibraryBackup.create(support: source, preferences: [:], at: backup)
        XCTAssertThrowsError(try LibraryBackup.create(support: source, preferences: [:], at: backup))
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("library/\(doc.id.uuidString)/linked"), withDestinationURL: backup)
        XCTAssertThrowsError(try LibraryBackup.create(support: source, preferences: [:], at: dir.appendingPathComponent("linked.kleiobackup")))
    }
}

extension LibraryBackupTests {
    func testNextLaunchRollsBackRestoreInterruptedByProcessExit() async throws {
        let environment = ProcessInfo.processInfo.environment
        if let source = environment["KLEIO_RESTORE_FIXTURE_SOURCE"],
           let target = environment["KLEIO_RESTORE_FIXTURE_TARGET"],
           let domain = environment["KLEIO_RESTORE_FIXTURE_DOMAIN"] {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            _ = try LibraryBackup.restore(URL(fileURLWithPath: source), support: URL(fileURLWithPath: target), defaults: defaults, domain: domain) { step in
                if step == environment["KLEIO_RESTORE_FIXTURE_STEP"] { _exit(0) }
            }
            XCTFail("Fixture must exit during restore")
            return
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (source, restored) = try fixture(dir, title: "Restored meeting")
        let (target, original) = try fixture(dir, title: "Original meeting")
        let backup = dir.appendingPathComponent("snapshot.kleiobackup")
        try LibraryBackup.create(support: source, preferences: ["language": "en"], at: backup)
        let domain = "test.\(UUID().uuidString)"; let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("fr", forKey: "language"); defaults.synchronize()
        try await interruptRestore(backup: backup, target: target, domain: domain, at: "restored:library")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent(".restore-journal.json").path))
        try LibraryBackup.recoverInterruptedRestore(support: target, defaults: defaults, domain: domain)
        try LibraryBackup.recoverInterruptedRestore(support: target, defaults: defaults, domain: domain)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("library/\(original.id.uuidString)/document.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("library/\(restored.id.uuidString)").path))
        XCTAssertEqual(defaults.string(forKey: "language"), "fr")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: nil).contains { $0.lastPathComponent.hasPrefix(".restore-stage-") })
    }

    func testNextLaunchFinishesCommittedRestoreWithoutRollingBack() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (source, restored) = try fixture(dir, title: "Restored meeting")
        let (target, original) = try fixture(dir, title: "Previous meeting")
        let backup = dir.appendingPathComponent("snapshot.kleiobackup")
        try LibraryBackup.create(support: source, preferences: [:], at: backup)
        let domain = "test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try await interruptRestore(backup: backup, target: target, domain: domain, at: "committed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent(".restore-journal.json").path))
        try LibraryBackup.restoreOnLaunch(support: target, defaults: defaults, domain: domain)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("library/\(restored.id.uuidString)/document.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("library/\(original.id.uuidString)").path))
        let previous = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: target.appendingPathComponent("Backups"), includingPropertiesForKeys: nil).first)
        XCTAssertEqual(try LibraryBackup.inspect(previous).recordingCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: previous.appendingPathComponent("data/library/\(original.id.uuidString)/document.json").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: nil).contains { $0.lastPathComponent.hasPrefix(".restore-") })
    }

    func testBackupRejectsHashConsistentButInvalidLibraryAndPeople() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        for corruption in ["library-file", "duplicate-people", "invalid-voice"] {
            let (source, _) = try fixture(dir, title: corruption)
            switch corruption {
            case "library-file":
                try FileManager.default.removeItem(at: source.appendingPathComponent("library"))
                try Data("not a directory".utf8).write(to: source.appendingPathComponent("library"))
            case "duplicate-people":
                let person = SavedPerson(name: "Duplicate")
                try JSONEncoder().encode([person, person]).write(to: source.appendingPathComponent("saved-people.json"))
            default:
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                let invalid = VoiceProfile(name: " ", centroids: [[]], sampleCount: -1, updatedAt: Date())
                try encoder.encode([invalid]).write(to: source.appendingPathComponent("voice-profiles.json"))
            }
            let backup = dir.appendingPathComponent(corruption + ".kleiobackup")
            XCTAssertThrowsError(try LibraryBackup.create(support: source, preferences: [:], at: backup), corruption)
            XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        }
    }

    private func interruptRestore(backup: URL, target: URL, domain: String, at step: String) async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "ScribeTests.LibraryBackupTests/testNextLaunchRollsBackRestoreInterruptedByProcessExit", Bundle(for: Self.self).bundleURL.path]
        child.environment = ["KLEIO_RESTORE_FIXTURE_SOURCE": backup.path, "KLEIO_RESTORE_FIXTURE_TARGET": target.path,
                             "KLEIO_RESTORE_FIXTURE_DOMAIN": domain, "KLEIO_RESTORE_FIXTURE_STEP": step]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run()
        let deadline = Date().addingTimeInterval(8)
        while child.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit(); XCTFail("Restore fixture exceeded eight seconds"); return }
        XCTAssertEqual(child.terminationStatus, 0)
    }

    func testScheduledRestoreRunsOnceBeforeOpeningTheLibrary() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (source, doc) = try fixture(dir, title: "Backup meeting")
        let (target, _) = try fixture(dir, title: "Current meeting")
        let backup = dir.appendingPathComponent("snapshot.kleiobackup")
        try LibraryBackup.create(support: source, preferences: [:], at: backup)
        try LibraryBackup.scheduleRestore(backup, support: target)
        let domain = "test.\(UUID().uuidString)"; let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        try LibraryBackup.restoreOnLaunch(support: target, defaults: defaults, domain: domain)
        try LibraryBackup.restoreOnLaunch(support: target, defaults: defaults, domain: domain)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: target.appendingPathComponent("Backups"), includingPropertiesForKeys: nil).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("library/\(doc.id.uuidString)/document.json").path))
    }
}
