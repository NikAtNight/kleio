import Foundation
import SwiftUI
import Combine

/// Summary work belongs to the app so navigation cannot start duplicate jobs
/// or hide a completed result that still needs to be saved.
@MainActor
final class SummaryJobs: ObservableObject {
    @Published private(set) var runningIDs: Set<UUID> = []
    @Published private(set) var pendingSaveIDs: Set<UUID> = []
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var completionCounts: [UUID: Int] = [:]
    var isBusy: Bool { !runningIDs.isEmpty || !pendingSaveIDs.isEmpty }

    private struct Result {
        let baseline: ScribeDocument
        let summary: String
    }
    private struct Job {
        let token: UUID
        let task: Task<Void, Never>
    }
    private let generate: (ScribeDocument) async throws -> String
    private weak var library: LibraryStore?
    private var tasks: [UUID: Job] = [:]
    private var preparingToQuit = false
    private var pendingResults: [UUID: Result] = [:]
    private var libraryObservation: AnyCancellable?

    init(generate: @escaping (ScribeDocument) async throws -> String = SummaryService.summarize) {
        self.generate = generate
    }

    func configure(library: LibraryStore) {
        self.library = library
        libraryObservation = library.$documents.sink { [weak self] documents in
            self?.removeDeletedDocuments(keeping: Set(documents.map(\.id)))
        }
    }

    func start(_ documentID: UUID) {
        guard !preparingToQuit, tasks[documentID] == nil, pendingResults[documentID] == nil,
              let baseline = library?.document(id: documentID) else { return }
        guard !baseline.segments.isEmpty else {
            errors[documentID] = SummaryService.SummaryError.emptyTranscript.localizedDescription
            return
        }
        let token = UUID()
        errors[documentID] = nil
        runningIDs.insert(documentID)
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.tasks[documentID]?.token == token {
                    self.tasks[documentID] = nil
                    self.runningIDs.remove(documentID)
                }
            }
            do {
                try Task.checkCancellation()
                let summary = try await self.generate(baseline)
                try Task.checkCancellation()
                guard self.tasks[documentID]?.token == token else { return }
                self.save(Result(baseline: baseline, summary: summary))
            } catch {
                guard self.tasks[documentID]?.token == token else { return }
                self.errors[documentID] = Task.isCancelled ? "Summary generation was cancelled." : error.localizedDescription
            }
        }
        tasks[documentID] = Job(token: token, task: task)
    }

    func cancel(_ documentID: UUID) {
        tasks[documentID]?.task.cancel()
    }

    func retrySave(_ documentID: UUID) {
        guard let result = pendingResults[documentID] else { return }
        save(result)
    }

    func dismissError(_ documentID: UUID) {
        errors[documentID] = nil
    }

    func prepareToQuit() async -> Bool {
        guard !preparingToQuit else { return false }
        preparingToQuit = true
        defer { preparingToQuit = false }
        let active = tasks.values.map(\.task)
        for task in active { task.cancel() }
        for task in active { await task.value }
        for id in Array(pendingResults.keys) { retrySave(id) }
        return pendingSaveIDs.isEmpty
    }

    private func save(_ result: Result) {
        let id = result.baseline.id
        guard let library, let current = library.document(id: id) else {
            pendingResults[id] = nil
            pendingSaveIDs.remove(id)
            return
        }
        do {
            let updated = try SummaryService.applyingSummary(result.summary, to: current, basedOn: result.baseline)
            guard library.update(updated) else {
                pendingResults[id] = result
                pendingSaveIDs.insert(id)
                errors[id] = (library.lastError ?? "The summary could not be saved.")
                    + " Retry saving without generating it again. The result is retained while this save is pending."
                return
            }
            pendingResults[id] = nil
            pendingSaveIDs.remove(id)
            errors[id] = nil
            completionCounts[id, default: 0] += 1
        } catch {
            // A stale result cannot become valid by retrying the same save.
            // Release it so the user can generate from the updated transcript.
            pendingResults[id] = nil
            pendingSaveIDs.remove(id)
            errors[id] = error.localizedDescription
        }
    }

    private func removeDeletedDocuments(keeping ids: Set<UUID>) {
        for id in Set(tasks.keys).subtracting(ids) {
            tasks.removeValue(forKey: id)?.task.cancel()
            runningIDs.remove(id)
        }
        for id in pendingSaveIDs.subtracting(ids) {
            pendingResults[id] = nil
            pendingSaveIDs.remove(id)
        }
        errors = errors.filter { ids.contains($0.key) }
        completionCounts = completionCounts.filter { ids.contains($0.key) }
    }
}
