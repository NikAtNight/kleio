import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// Imports audio/video files into the library (copying them into the
/// document folder so originals can move/vanish) and queues transcription.
@MainActor
enum Importer {
    static let supportedTypes: [UTType] = [.audio, .movie, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .aiff, .mpeg4Audio]

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
                title: url.deletingPathExtension().lastPathComponent,
                kind: .imported,
                status: .queued
            )
            doc.originalFilePath = url.path
            doc.automaticExportDirectory = automaticExportDirectory?.path
            doc.automaticExportFormats = automaticExportFormats.map(\.rawValue)
            let folder = LibraryStore.folder(for: doc.id)
            let fileName = "audio.\(url.pathExtension.lowercased())"
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(fileName))
            } catch {
                NSLog("Scribe: import copy failed: %@", error.localizedDescription)
                continue
            }
            doc.tracks = [AudioTrack(source: .imported, fileName: fileName)]
            doc.duration = audioDuration(of: folder.appendingPathComponent(fileName))
            library.add(doc)
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
            : "Podcast — \(Date().formatted(date: .abbreviated, time: .shortened))"
        var doc = ScribeDocument(title: title, kind: .imported, status: .queued)
        let folder = LibraryStore.folder(for: doc.id)
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
            NSLog("Scribe: podcast import failed: %@", error.localizedDescription)
            return nil
        }

        doc.knownSpeakers = doc.tracks.compactMap(\.speakerName)
        doc.originalFilePath = supported.first?.deletingLastPathComponent().path
        doc.duration = doc.tracks
            .map { audioDuration(of: folder.appendingPathComponent($0.fileName)) }
            .max() ?? 0
        library.add(doc)
        queue.enqueue(doc.id)
        return doc.id
    }
}
