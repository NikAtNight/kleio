import Foundation
import AVFoundation
import UniformTypeIdentifiers
import Combine

/// Imports audio/video files into the library (copying them into the
/// document folder so originals can move/vanish) and queues transcription.
@MainActor
final class Importer: ObservableObject {
    @Published private(set) var activeCount = 0
    @Published private(set) var completedFiles = 0
    @Published private(set) var totalFiles = 0
    @Published private(set) var errors: [String] = []
    var isBusy: Bool { activeCount > 0 }
    var startBlocked: () -> Bool = { false }
    var canImport: Bool { !preparingToQuit && !startBlocked() }
    private var preparingToQuit = false
    private let copyMedia: @Sendable (URL, URL) async throws -> TimeInterval

    init(copyMedia: @escaping @Sendable (URL, URL) async throws -> TimeInterval = { source, destination in
        try await Task.detached(priority: .userInitiated) {
            let accessed = source.startAccessingSecurityScopedResource()
            defer { if accessed { source.stopAccessingSecurityScopedResource() } }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
            return audioDuration(of: destination)
        }.value
    }) {
        self.copyMedia = copyMedia
    }

    func dismissErrors() { errors = [] }

    private func recordError(_ message: String) {
        if !errors.contains(message) { errors.append(message) }
    }

    func prepareToQuit() async {
        preparingToQuit = true
        while isBusy { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    func resumeAfterCancelledQuit() { preparingToQuit = false }

    private func begin(fileCount: Int) -> Bool {
        guard canImport else {
            recordError(preparingToQuit ? "Kleio is quitting. Wait until quit is cancelled before importing files."
                        : "Finish the backup or restore before importing files.")
            return false
        }
        if !isBusy { completedFiles = 0; totalFiles = 0 }
        totalFiles += fileCount
        activeCount += 1
        return true
    }

    private func removeIncompleteFolder(_ folder: URL) async {
        await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: folder) }.value
    }
    static let supportedTypes: [UTType] = [.audio, .movie, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .aiff, .mpeg4Audio]

    /// Overridable so tests can predict the id of a document before it is created.
    static var makeID: () -> UUID = { UUID() }

    static func isSupported(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .audiovisualContent)
    }

    /// Returns the IDs of the created documents.
    @discardableResult
    func importFiles(
        _ urls: [URL],
        library: LibraryStore,
        queue: TranscriptionQueue,
        automaticExportDirectory: URL? = nil,
        automaticExportFormats: [ExportFormat] = []
    ) async -> [UUID] {
        let supported = urls.filter(Self.isSupported)
        guard !supported.isEmpty, begin(fileCount: supported.count) else { return [] }
        defer { activeCount -= 1 }
        var ids: [UUID] = []
        for url in supported {
            defer { completedFiles += 1 }
            var doc = ScribeDocument(
                id: Self.makeID(),
                title: url.deletingPathExtension().lastPathComponent,
                kind: .imported,
                status: .queued
            )
            doc.originalFilePath = url.path
            doc.automaticExportDirectory = automaticExportDirectory?.path
            doc.automaticExportFormats = automaticExportFormats.map(\.rawValue)
            let folder = library.folder(for: doc.id)
            let fileName = "audio.\(url.pathExtension.lowercased())"
            do {
                try Task.checkCancellation()
                doc.duration = try await copyMedia(url, folder.appendingPathComponent(fileName))
                try Task.checkCancellation()
            } catch {
                recordError("\(url.lastPathComponent): \(error.localizedDescription)")
                await removeIncompleteFolder(folder)
                continue
            }
            doc.tracks = [AudioTrack(source: .imported, fileName: fileName)]
            guard library.add(doc) else {
                recordError("\(url.lastPathComponent): \(library.lastError ?? "Could not save the imported recording.")")
                await removeIncompleteFolder(folder)
                continue
            }
            queue.enqueue(doc.id)
            ids.append(doc.id)
        }
        return ids
    }

    /// Creates one document from separate podcast/interview tracks. Each
    /// filename becomes a speaker name and all tracks remain time-aligned.
    @discardableResult
    func importPodcast(
        _ urls: [URL],
        library: LibraryStore,
        queue: TranscriptionQueue
    ) async -> UUID? {
        let supported = urls.filter(Self.isSupported)
        guard !supported.isEmpty, begin(fileCount: supported.count) else { return nil }
        defer { activeCount -= 1 }

        let parentNames = Set(supported.map { $0.deletingLastPathComponent().lastPathComponent })
        let title = parentNames.count == 1
            ? (parentNames.first ?? "Podcast")
            : "Podcast, \(Date().formatted(date: .abbreviated, time: .shortened))"
        var doc = ScribeDocument(id: Self.makeID(), title: title, kind: .imported, status: .queued)
        let folder = library.folder(for: doc.id)
        var usedNames: [String: Int] = [:]

        do {
            for (index, url) in supported.enumerated() {
                try Task.checkCancellation()
                let baseName = url.deletingPathExtension().lastPathComponent
                let count = usedNames[baseName, default: 0]
                usedNames[baseName] = count + 1
                let speaker = count == 0 ? baseName : "\(baseName) \(count + 1)"
                let ext = url.pathExtension.lowercased()
                let fileName = "track-\(index + 1).\(ext)"
                let duration = try await copyMedia(url, folder.appendingPathComponent(fileName))
                try Task.checkCancellation()
                doc.duration = max(doc.duration, duration)
                doc.tracks.append(AudioTrack(source: .imported, fileName: fileName, speakerName: speaker))
                completedFiles += 1
            }
        } catch {
            completedFiles += supported.count - doc.tracks.count
            recordError("\(title): \(error.localizedDescription)")
            await removeIncompleteFolder(folder)
            return nil
        }

        doc.knownSpeakers = doc.tracks.compactMap(\.speakerName)
        doc.originalFilePath = supported.first?.deletingLastPathComponent().path
        guard library.add(doc) else {
            recordError("\(title): \(library.lastError ?? "Could not save the imported recording.")")
            await removeIncompleteFolder(folder)
            return nil
        }
        queue.enqueue(doc.id)
        return doc.id
    }
}
