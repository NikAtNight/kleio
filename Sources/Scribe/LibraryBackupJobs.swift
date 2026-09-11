import Foundation
import Combine

/// Owns backup work across Settings navigation and normal application termination.
@MainActor
final class LibraryBackupJobs: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var message: String?
    @Published private(set) var error: String?

    private let create: (URL, [String: Any], URL) async throws -> LibraryBackup.Manifest
    private let inspect: (URL) async throws -> LibraryBackup.Manifest
    private let schedule: (URL, URL) async throws -> Void
    private var task: Task<Void, Never>?

    init(
        create: @escaping (URL, [String: Any], URL) async throws -> LibraryBackup.Manifest = { support, preferences, destination in
            try await Task.detached(priority: .utility) {
                try LibraryBackup.create(support: support, preferences: preferences, at: destination)
            }.value
        },
        inspect: @escaping (URL) async throws -> LibraryBackup.Manifest = { backup in
            try await Task.detached(priority: .utility) { try LibraryBackup.inspect(backup) }.value
        },
        schedule: @escaping (URL, URL) async throws -> Void = { backup, support in
            try await Task.detached(priority: .utility) { try LibraryBackup.scheduleRestore(backup, support: support) }.value
        }
    ) {
        self.create = create
        self.inspect = inspect
        self.schedule = schedule
    }

    func backUp(support: URL, preferences: [String: Any], to destination: URL, onCreated: @escaping (URL) -> Void = { _ in }) {
        start {
            let result = try await self.create(support, preferences, destination)
            onCreated(destination)
            return "Backed up \(result.recordingCount) recordings."
        }
    }

    func restoreNextLaunch(from backup: URL, support: URL, canRestore: @escaping () -> Bool,
                           confirm: @escaping (LibraryBackup.Manifest) -> Bool) {
        start {
            let manifest = try await self.inspect(backup)
            guard canRestore() else {
                throw LibraryBackup.BackupError.message("Finish the current recording or processing before restoring.")
            }
            guard confirm(manifest), canRestore() else { return nil }
            try await self.schedule(backup, support)
            return "Restore scheduled. Quit and reopen Kleio to finish."
        }
    }

    func dismissError() { error = nil }

    func prepareToQuit() async -> Bool {
        await task?.value
        return error == nil
    }

    private func start(_ operation: @escaping () async throws -> String?) {
        guard task == nil else { return }
        isWorking = true
        message = nil
        error = nil
        task = Task {
            defer { self.task = nil; isWorking = false }
            do { message = try await operation() }
            catch { self.error = error.localizedDescription }
        }
    }
}
