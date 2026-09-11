import Foundation
import CryptoKit

/// A verified local snapshot. Restore runs before any library or background jobs open.
enum LibraryBackup {
    static let itemNames = ["library", "saved-people.json", "voice-profiles.json"]
    static let preferenceKeys: Set<String> = [
        "language", "translate", "selectedModel", "microphoneSpeakerName", "expectedRemoteSpeakerCount",
        "preferredInputDeviceUID", "automaticSpeakerRecognition", "speakerDetectionModel", "voiceRecognitionEnabled",
        "manualAutoStopEnabled", "recordingAppShortcuts", "recordingVideoEnabled", "recordingVideoMode",
        "textReplacementRules", "replacementCaseSensitive", "replacementWholeWords", "removeFillerWords",
        "dictationEnabled", "dictationCleanupEnabled", "dictationCleanupBackend", "dictationCleanupOllamaModel",
        "aiProvider", "aiModel", "aiOllamaModel", "summaryPrompt", "watchAutoTranscribe", "watchAutoExport",
        "watchExportFormats", "watchedFolders", "watchSeenSignatures", "calendarSyncEnabled", "calendarLeadMinutes",
        "calendarSelectedIDs", "calendarOnlyWithLinks", "autoRecordEnabled", "autoRecordCalendarIDs",
        "autoRecordLateJoinMinutes", "autoRecordGraceMinutes", "autoRecordSilenceMinutes", "autoRecordEventOverrides",
        "autoRecordConsentShown", "autoRecordStoreEventDetails"
    ]
    static var supportURL: URL { LibraryStore.baseURL.deletingLastPathComponent() }

    struct Entry: Codable, Equatable {
        let path: String
        let bytes: Int64
        let sha256: String
    }
    struct Manifest: Codable {
        var version = 1
        let createdAt: Date
        let entries: [Entry]
        var recordingCount: Int { entries.filter { $0.path.hasSuffix("/document.json") }.count }
        var totalBytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }
    }
    private struct RestoreJournal: Codable {
        let stageName: String
        let previousName: String
        let originals: [String]
        var committed: Bool = false
    }
    enum BackupError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }

    static func selectedPreferences(_ values: [String: Any]) -> [String: Any] {
        values.filter { preferenceKeys.contains($0.key) }
    }

    @discardableResult
    static func create(support: URL, preferences: [String: Any], at destination: URL) throws -> Manifest {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path), !isInside(destination, support) else {
            throw BackupError.message("Choose a new backup folder outside Kleio's data folder.")
        }
        let before = try sourceEntries(support)
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".kleio-backup-\(UUID().uuidString)")
        try fm.createDirectory(at: stage.appendingPathComponent("data"), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: stage) }
        for name in itemNames where fm.fileExists(atPath: support.appendingPathComponent(name).path) {
            try fm.copyItem(at: support.appendingPathComponent(name), to: stage.appendingPathComponent("data/\(name)"))
        }
        try writePreferences(preferences, to: stage.appendingPathComponent("preferences.plist"))
        let copied = try sourceEntries(stage.appendingPathComponent("data"))
        guard before == copied, before == (try sourceEntries(support)) else {
            throw BackupError.message("The library changed during backup. Try again after recording and edits finish.")
        }
        let manifest = try seal(stage)
        _ = try inspect(stage)
        try fm.moveItem(at: stage, to: destination)
        return manifest
    }

    static func inspect(_ backup: URL) throws -> Manifest {
        let fm = FileManager.default
        try requireDirectory(backup)
        let rootItems = try fm.contentsOfDirectory(at: backup, includingPropertiesForKeys: nil)
        guard rootItems.allSatisfy({ ["backup.json", "data", "preferences.plist"].contains($0.lastPathComponent) }) else {
            throw BackupError.message("The backup contains unexpected items.")
        }
        let manifestURL = backup.appendingPathComponent("backup.json")
        try requireRegularFile(manifestURL)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.version == 1, Set(manifest.entries.map(\.path)).count == manifest.entries.count else {
            throw BackupError.message("This backup format is unsupported or its file list is invalid.")
        }
        let expected = manifest.entries.sorted { $0.path < $1.path }
        let actual = try payloadEntries(backup)
        guard expected == actual else {
            throw BackupError.message("The backup is incomplete or a file has changed. Your current library has not been replaced.")
        }
        _ = try readPreferences(backup.appendingPathComponent("preferences.plist"))
        let library = backup.appendingPathComponent("data/library")
        if fm.fileExists(atPath: library.path) { try requireDirectory(library) }
        for entry in actual where entry.path.hasSuffix("/document.json") {
            let url = backup.appendingPathComponent(entry.path)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let doc = try decoder.decode(ScribeDocument.self, from: Data(contentsOf: url))
            guard url.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath() == library.resolvingSymlinksInPath(),
                  url.deletingLastPathComponent().lastPathComponent == doc.id.uuidString,
                  (doc.tracks.map(\.fileName) + (doc.videoTracks ?? []).map(\.fileName)).allSatisfy(safeFileName),
                  Set(doc.segments.map(\.id)).count == doc.segments.count,
                  Set((doc.speakers ?? []).map(\.id)).count == (doc.speakers ?? []).count else {
                throw BackupError.message("A recording in this backup has invalid file references or identifiers.")
            }
        }
        let people = backup.appendingPathComponent("data/saved-people.json")
        if fm.fileExists(atPath: people.path) {
            let saved = try JSONDecoder().decode([SavedPerson].self, from: Data(contentsOf: people))
            guard Set(saved.map(\.id)).count == saved.count,
                  saved.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw BackupError.message("The saved people list is invalid.")
            }
        }
        let voices = backup.appendingPathComponent("data/voice-profiles.json")
        if fm.fileExists(atPath: voices.path) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let profiles = try decoder.decode([VoiceProfile].self, from: Data(contentsOf: voices))
            guard profiles.allSatisfy({ profile in
                !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && profile.sampleCount >= 0
                    && profile.centroids.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isFinite) }
            }) else { throw BackupError.message("The saved voice profiles are invalid.") }
        }
        return manifest
    }

    /// Returns the retained previous library. A journal allows the next launch to undo interruption.
    @discardableResult
    static func restore(_ backup: URL, support: URL, defaults: UserDefaults, domain: String,
                        checkpoint: (String) throws -> Void = { _ in }) throws -> URL {
        let fm = FileManager.default
        _ = try inspect(backup)
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        try recoverInterruptedRestore(support: support, defaults: defaults, domain: domain)
        let stageName = ".restore-stage-\(UUID().uuidString)"
        let previousName = "Before restore \(UUID().uuidString).kleiobackup"
        let stage = support.appendingPathComponent(stageName)
        let previous = support.appendingPathComponent("Backups/\(previousName)")
        try fm.copyItem(at: backup, to: stage)
        defer { try? fm.removeItem(at: stage) }
        _ = try inspect(stage)
        try fm.createDirectory(at: previous.appendingPathComponent("data"), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try writePreferences(defaults.persistentDomain(forName: domain) ?? [:], to: previous.appendingPathComponent("preferences.plist"))
        var journal = RestoreJournal(stageName: stageName, previousName: previousName,
                                     originals: itemNames.filter { fm.fileExists(atPath: support.appendingPathComponent($0).path) })
        let journalURL = support.appendingPathComponent(".restore-journal.json")
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        do {
            for name in journal.originals {
                try fm.moveItem(at: support.appendingPathComponent(name), to: previous.appendingPathComponent("data/\(name)"))
                try checkpoint("preserved:\(name)")
            }
            _ = try seal(previous)
            for name in itemNames where fm.fileExists(atPath: stage.appendingPathComponent("data/\(name)").path) {
                try fm.moveItem(at: stage.appendingPathComponent("data/\(name)"), to: support.appendingPathComponent(name))
                try checkpoint("restored:\(name)")
            }
            applyPreferences(try readPreferences(stage.appendingPathComponent("preferences.plist")), defaults: defaults, domain: domain)
            try checkpoint("preferences")
            journal.committed = true
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        } catch {
            do { try recoverInterruptedRestore(support: support, defaults: defaults, domain: domain) }
            catch { throw BackupError.message("Restore stopped and needs recovery before Kleio can open. Preserved files are in \(previous.path). \(error.localizedDescription)") }
            throw error
        }
        try checkpoint("committed")
        // Remove the stage before its journal so an interrupted cleanup can resume next launch.
        try? recoverInterruptedRestore(support: support, defaults: defaults, domain: domain)
        return previous
    }

    static func recoverInterruptedRestore(support: URL, defaults: UserDefaults, domain: String) throws {
        let fm = FileManager.default
        let url = support.appendingPathComponent(".restore-journal.json")
        guard fm.fileExists(atPath: url.path) else { return }
        let journal = try JSONDecoder().decode(RestoreJournal.self, from: Data(contentsOf: url))
        guard safeFileName(journal.stageName), journal.stageName.hasPrefix(".restore-stage-"),
              safeFileName(journal.previousName), journal.previousName.hasSuffix(".kleiobackup"),
              journal.originals.allSatisfy(itemNames.contains) else { throw BackupError.message("The restore recovery record is invalid.") }
        if !journal.committed {
            let previous = support.appendingPathComponent("Backups/\(journal.previousName)")
            let rejected = previous.appendingPathComponent("interrupted-restored-files")
            for name in itemNames {
                let old = previous.appendingPathComponent("data/\(name)")
                let current = support.appendingPathComponent(name)
                if fm.fileExists(atPath: old.path) || !journal.originals.contains(name) {
                    if fm.fileExists(atPath: current.path) {
                        try fm.createDirectory(at: rejected, withIntermediateDirectories: true)
                        try fm.moveItem(at: current, to: rejected.appendingPathComponent("\(UUID().uuidString)-\(name)"))
                    }
                    if fm.fileExists(atPath: old.path) { try fm.moveItem(at: old, to: current) }
                }
            }
            applyPreferences(try readPreferences(previous.appendingPathComponent("preferences.plist")), defaults: defaults, domain: domain)
        }
        let stage = support.appendingPathComponent(journal.stageName)
        if fm.fileExists(atPath: stage.path) {
            try requireDirectory(stage)
            try fm.removeItem(at: stage)
        }
        try fm.removeItem(at: url)
    }

    static func scheduleRestore(_ backup: URL, support: URL) throws {
        _ = try inspect(backup)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data(backup.standardizedFileURL.path.utf8).write(to: support.appendingPathComponent(".restore-on-launch"), options: .atomic)
    }

    static func restoreOnLaunch(support: URL, defaults: UserDefaults, domain: String) throws {
        try recoverInterruptedRestore(support: support, defaults: defaults, domain: domain)
        let request = support.appendingPathComponent(".restore-on-launch")
        guard FileManager.default.fileExists(atPath: request.path) else { return }
        let path = try String(contentsOf: request, encoding: .utf8)
        // Consume first so a failed validation cannot trap the next launch in a restore loop.
        try FileManager.default.removeItem(at: request)
        _ = try restore(URL(fileURLWithPath: path), support: support, defaults: defaults, domain: domain)
    }

    private static func seal(_ backup: URL) throws -> Manifest {
        let manifest = Manifest(createdAt: Date(), entries: try payloadEntries(backup))
        try JSONEncoder().encode(manifest).write(to: backup.appendingPathComponent("backup.json"), options: .atomic)
        return manifest
    }
    private static func sourceEntries(_ support: URL) throws -> [Entry] {
        var result: [Entry] = []
        for name in itemNames {
            let url = support.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { result += try entries(url, relativeTo: support) }
        }
        return result.sorted { $0.path < $1.path }
    }
    private static func payloadEntries(_ backup: URL) throws -> [Entry] {
        let data = backup.appendingPathComponent("data")
        try requireDirectory(data)
        let children = try FileManager.default.contentsOfDirectory(at: data, includingPropertiesForKeys: nil)
        guard children.allSatisfy({ itemNames.contains($0.lastPathComponent) }) else { throw BackupError.message("The backup contains unsupported library items.") }
        return try (entries(data, relativeTo: backup) + entries(backup.appendingPathComponent("preferences.plist"), relativeTo: backup)).sorted { $0.path < $1.path }
    }
    private static func entries(_ url: URL, relativeTo root: URL) throws -> [Entry] {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
        guard values.isSymbolicLink != true else { throw BackupError.message("Backups cannot contain symbolic links.") }
        if values.isDirectory == true {
            return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .flatMap { try entries($0, relativeTo: root) }
        }
        try requireRegularFile(url)
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256(); var bytes: Int64 = 0
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data); bytes += Int64(data.count) }
        let rootComponents = root.resolvingSymlinksInPath().pathComponents
        let fileComponents = url.resolvingSymlinksInPath().pathComponents
        guard fileComponents.starts(with: rootComponents) else { throw BackupError.message("A backup file is outside the library.") }
        let path = fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
        return [Entry(path: path, bytes: bytes, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())]
    }
    private static func writePreferences(_ values: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: selectedPreferences(values), format: .binary, options: 0).write(to: url, options: .atomic)
    }
    private static func readPreferences(_ url: URL) throws -> [String: Any] {
        try requireRegularFile(url)
        guard let values = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any],
              Set(values.keys).isSubset(of: preferenceKeys) else { throw BackupError.message("The backup preferences are invalid.") }
        return values
    }
    private static func applyPreferences(_ values: [String: Any], defaults: UserDefaults, domain: String) {
        var merged = defaults.persistentDomain(forName: domain) ?? [:]
        for key in preferenceKeys { merged.removeValue(forKey: key) }
        merged.merge(values) { _, restored in restored }
        defaults.setPersistentDomain(merged, forName: domain)
        defaults.synchronize()
    }
    private static func safeFileName(_ name: String) -> Bool { !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") }
    private static func isInside(_ child: URL, _ parent: URL) -> Bool {
        let c = child.resolvingSymlinksInPath().path; let p = parent.resolvingSymlinksInPath().path
        return c == p || c.hasPrefix(p + "/")
    }
    private static func requireRegularFile(_ url: URL) throws {
        let value = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard value.isRegularFile == true, value.isSymbolicLink != true else { throw BackupError.message("A backup file is missing or is not a regular file.") }
    }
    private static func requireDirectory(_ url: URL) throws {
        let value = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard value.isDirectory == true, value.isSymbolicLink != true else { throw BackupError.message("Choose a complete Kleio backup folder.") }
    }
}
