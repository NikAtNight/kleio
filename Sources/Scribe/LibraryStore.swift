import Foundation
import SwiftUI
import AVFoundation

/// Persistent library of documents. Each document lives in its own folder:
/// ~/Library/Application Support/Scribe/library/<uuid>/
///   document.json + one or more audio files.
/// Folder-per-document means a crash can never corrupt more than the one
/// item being written, and audio written progressively during recording
/// survives even if document.json never got its final save.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var documents: [ScribeDocument] = []

    static let baseURL: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scribe/library", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func folder(for id: UUID) -> URL {
        baseURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func url(for track: AudioTrack, in doc: ScribeDocument) -> URL {
        Self.folder(for: doc.id).appendingPathComponent(track.fileName)
    }

    init() {
        load()
        recoverCrashedRecordings()
    }

    private func load() {
        let fm = FileManager.default
        var docs: [ScribeDocument] = []
        let folders = (try? fm.contentsOfDirectory(at: Self.baseURL, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for folder in folders {
            let jsonURL = folder.appendingPathComponent("document.json")
            guard let data = try? Data(contentsOf: jsonURL),
                  let doc = try? decoder.decode(ScribeDocument.self, from: data) else { continue }
            docs.append(doc)
        }
        documents = docs.sorted { $0.createdAt > $1.createdAt }
    }

    /// A document still marked .recording/.transcribing on launch means the
    /// app died mid-flight. The progressively-written audio is intact on
    /// disk — keep it and flag it so the user can (re)transcribe.
    private func recoverCrashedRecordings() {
        for var doc in documents where doc.status == .recording || doc.status == .transcribing || doc.status == .queued {
            let folder = Self.folder(for: doc.id)
            // Drop tracks whose file never materialized.
            doc.tracks = doc.tracks.filter {
                FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.fileName).path)
            }
            if doc.tracks.isEmpty {
                delete(doc)
                continue
            }
            doc.status = .recovered
            doc.duration = doc.tracks
                .map { audioDuration(of: folder.appendingPathComponent($0.fileName)) }
                .max() ?? 0
            update(doc)
        }
    }

    func add(_ doc: ScribeDocument) {
        documents.insert(doc, at: 0)
        documents.sort { $0.createdAt > $1.createdAt }
        save(doc)
    }

    func update(_ doc: ScribeDocument) {
        if let i = documents.firstIndex(where: { $0.id == doc.id }) {
            documents[i] = doc
        } else {
            documents.insert(doc, at: 0)
        }
        save(doc)
    }

    func document(id: UUID) -> ScribeDocument? {
        documents.first { $0.id == id }
    }

    func delete(_ doc: ScribeDocument) {
        documents.removeAll { $0.id == doc.id }
        try? FileManager.default.removeItem(at: Self.folder(for: doc.id))
    }

    private func save(_ doc: ScribeDocument) {
        let folder = Self.folder(for: doc.id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(doc)
            try data.write(to: folder.appendingPathComponent("document.json"), options: .atomic)
        } catch {
            NSLog("Scribe: failed to save document %@: %@", doc.id.uuidString, error.localizedDescription)
        }
    }
}

func audioDuration(of url: URL) -> TimeInterval {
    guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return 0 }
    return Double(file.length) / file.fileFormat.sampleRate
}
