import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// Imports audio/video files into the library (copying them into the
/// document folder so originals can move/vanish) and queues transcription.
@MainActor
enum Importer {
    static let supportedTypes: [UTType] = [.audio, .movie, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .aiff, .mpeg4Audio]

    /// Overridable so tests can predict the id of a document before it is created.
    static var makeID: () -> UUID = { UUID() }

    static func isSupported(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .audiovisualContent)
    }

    /// Returns the IDs of the created documents.
    @discardableResult
    static func importFiles(
        _ urls: [URL],
        library: LibraryStore,
        queue: TranscriptionQueue,
        automaticExportDirectory: URL? = nil,
        automaticExportFormats: [ExportFormat] = []
    ) -> [UUID] {
        var ids: [UUID] = []
        for url in urls where isSupported(url) {
            var doc = ScribeDocument(
                id: makeID(),
                title: url.deletingPathExtension().lastPathComponent,
                kind: .imported,
                status: .queued
            )
            doc.originalFilePath = url.path
            doc.automaticExportDirectory = automaticExportDirectory?.path
            doc.automaticExportFormats = automaticExportFormats.map(\.rawValue)
            let folder = library.folder(for: doc.id)
            let fileName = "audio.\(url.pathExtension.lowercased())"
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(fileName))
            } catch {
                DiagLog.log("import copy failed for %@ file: %@", url.pathExtension.lowercased(), error.localizedDescription)
                try? FileManager.default.removeItem(at: folder)
                continue
            }
            doc.tracks = [AudioTrack(source: .imported, fileName: fileName)]
            doc.duration = audioDuration(of: folder.appendingPathComponent(fileName))
            guard library.add(doc) else {
                DiagLog.log("import save failed for %@ file", url.pathExtension.lowercased())
                try? FileManager.default.removeItem(at: folder)
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
    static func importPodcast(
        _ urls: [URL],
        library: LibraryStore,
        queue: TranscriptionQueue
    ) -> UUID? {
        let supported = urls.filter(isSupported)
        guard !supported.isEmpty else { return nil }

        let parentNames = Set(supported.map { $0.deletingLastPathComponent().lastPathComponent })
        let title = parentNames.count == 1
            ? (parentNames.first ?? "Podcast")
            : "Podcast, \(Date().formatted(date: .abbreviated, time: .shortened))"
        var doc = ScribeDocument(id: makeID(), title: title, kind: .imported, status: .queued)
        let folder = library.folder(for: doc.id)
        var usedNames: [String: Int] = [:]

        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (index, url) in supported.enumerated() {
                let baseName = url.deletingPathExtension().lastPathComponent
                let count = usedNames[baseName, default: 0]
                usedNames[baseName] = count + 1
                let speaker = count == 0 ? baseName : "\(baseName) \(count + 1)"
                let ext = url.pathExtension.lowercased()
                let fileName = "track-\(index + 1).\(ext)"
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(fileName))
                doc.tracks.append(AudioTrack(source: .imported, fileName: fileName, speakerName: speaker))
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            DiagLog.log("podcast import failed for %d tracks: %@", supported.count, error.localizedDescription)
            return nil
        }

        doc.knownSpeakers = doc.tracks.compactMap(\.speakerName)
        doc.originalFilePath = supported.first?.deletingLastPathComponent().path
        doc.duration = doc.tracks
            .map { audioDuration(of: folder.appendingPathComponent($0.fileName)) }
            .max() ?? 0
        guard library.add(doc) else {
            DiagLog.log("podcast import save failed for %d tracks", supported.count)
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        queue.enqueue(doc.id)
        return doc.id
    }
}
