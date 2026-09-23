import Foundation
import SwiftUI

struct SavedPerson: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
}

@MainActor
final class SavedPeopleStore: ObservableObject {
    static let shared = SavedPeopleStore(seedNames: VoiceProfileStore.shared.profiles.map(\.name))
    @Published private(set) var people: [SavedPerson] = []
    @Published private(set) var lastError: String?
    private let fileURL: URL
    private var couldNotLoad = false

    init(directory: URL? = nil, seedNames: [String] = []) {
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scribe", isDirectory: true)
        fileURL = directory.appendingPathComponent("saved-people.json")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                people = try JSONDecoder().decode([SavedPerson].self, from: data)
                guard Set(people.map(\.id)).count == people.count,
                      people.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                    throw StoreError.unreadable
                }
                people.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            } catch {
                people = []
                couldNotLoad = true
                lastError = error.localizedDescription
            }
        } else if !seedNames.isEmpty {
            var seen = Set<String>()
            let seeded = seedNames.compactMap { proposedName -> SavedPerson? in
                let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { return nil }
                return SavedPerson(name: name)
            }
            do {
                try persist(seeded)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    @discardableResult
    func add(name: String) throws -> SavedPerson {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw StoreError.emptyName }
        guard !couldNotLoad else { throw StoreError.unreadable }
        if let existing = people.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return existing
        }
        let person = SavedPerson(name: name)
        do {
            try persist(people + [person])
            lastError = nil
            return person
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    /// Removes a saved person, such as when a Recording edit that created
    /// them fails to save. A no-op if the id is not present.
    func remove(id: UUID) throws {
        guard people.contains(where: { $0.id == id }) else { return }
        guard !couldNotLoad else { throw StoreError.unreadable }
        do {
            try persist(people.filter { $0.id != id })
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    private func persist(_ proposedPeople: [SavedPerson]) throws {
        let sorted = proposedPeople.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sorted)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        people = sorted
    }

    enum StoreError: LocalizedError {
        case emptyName
        case unreadable

        var errorDescription: String? {
            switch self {
            case .emptyName: return "Enter a name to save this person."
            case .unreadable: return "Saved people could not be read. The existing file has been kept."
            }
        }
    }
}
