import Foundation
import SwiftUI

struct WatchedFolder: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

/// Polls user-selected folders for stable, newly-added media files. File
/// signatures are persisted so items added while Scribe is closed are picked
/// up at the next launch without re-importing the old contents.
@MainActor
final class WatchFolderManager: ObservableObject {
    @Published private(set) var folders: [WatchedFolder] = []
    @Published var autoTranscribe: Bool {
        didSet { defaults.set(autoTranscribe, forKey: "watchAutoTranscribe") }
    }
    @Published var autoExport: Bool {
        didSet { defaults.set(autoExport, forKey: "watchAutoExport") }
    }
    @Published var exportFormats: Set<ExportFormat> {
        didSet {
            defaults.set(exportFormats.map(\.rawValue).sorted(), forKey: "watchExportFormats")
        }
    }
    @Published private(set) var lastImportedFile: String?

    private weak var library: LibraryStore?
    private weak var queue: TranscriptionQueue?
    private var importer: Importer?
    private var scanning = false
    private var timer: Timer?
    private var seenSignatures: Set<String> = []
    private var candidates: [String: String] = [:]
    private let defaults: UserDefaults

    private static let foldersKey = "watchedFolders"
    private static let seenKey = "watchSeenSignatures"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoTranscribe = defaults.object(forKey: "watchAutoTranscribe") == nil
            ? true : defaults.bool(forKey: "watchAutoTranscribe")
        autoExport = defaults.object(forKey: "watchAutoExport") == nil
            ? true : defaults.bool(forKey: "watchAutoExport")
        let rawFormats = defaults.stringArray(forKey: "watchExportFormats") ?? [ExportFormat.txt.rawValue]
        exportFormats = Set(rawFormats.compactMap(ExportFormat.init(rawValue:)))
        if let data = defaults.data(forKey: Self.foldersKey),
           let decoded = try? JSONDecoder().decode([WatchedFolder].self, from: data) {
            folders = decoded
        }
        seenSignatures = Set(defaults.stringArray(forKey: Self.seenKey) ?? [])
    }

    func configure(library: LibraryStore, queue: TranscriptionQueue, importer: Importer) {
        self.library = library
        self.queue = queue
        self.importer = importer
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.scan() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func addFolder(_ url: URL) {
        let standardized = url.standardizedFileURL.path
        guard !folders.contains(where: { $0.path == standardized }) else { return }
        let folder = WatchedFolder(path: standardized)
        folders.append(folder)
        // Adding a folder establishes a baseline; only later additions are
        // imported. On future launches the signatures let us notice files
        // that arrived while Scribe was closed.
        for item in mediaItems(in: folder) ?? [] {
            seenSignatures.insert(item.signature)
        }
        persistFolders()
        persistSeen()
    }

    func removeFolder(_ folder: WatchedFolder) {
        folders.removeAll { $0.id == folder.id }
        candidates = candidates.filter { !isDirectChild($0.key, of: folder) }
        seenSignatures = seenSignatures.filter { !isDirectChild($0, of: folder) }
        persistFolders()
        persistSeen()
    }

    func scanNow() async {
        await scan()
    }

    private func scan() async {
        guard !scanning, autoTranscribe, let library, let queue, let importer, importer.canImport else { return }
        scanning = true
        defer { scanning = false }
        var activePaths = Set<String>()
        for folder in folders {
            // An unavailable folder keeps its history until it can be read again.
            guard let items = mediaItems(in: folder) else { continue }
            let signatures = Set(items.map(\.signature))
            seenSignatures = seenSignatures.filter { !isDirectChild($0, of: folder) || signatures.contains($0) }
            for item in items {
                activePaths.insert(item.url.path)
                if seenSignatures.contains(item.signature) {
                    candidates[item.url.path] = nil
                    continue
                }
                // Require the same size and modification time on two scans,
                // avoiding imports of files that are still being copied.
                guard candidates[item.url.path] == item.signature else {
                    candidates[item.url.path] = item.signature
                    continue
                }

                let formats = autoExport ? Array(exportFormats) : []
                guard folders.contains(folder), autoTranscribe, importer.canImport else { break }
                let ids = await importer.importFiles(
                    [item.url],
                    library: library,
                    queue: queue,
                    automaticExportDirectory: autoExport ? folder.url : nil,
                    automaticExportFormats: formats
                )
                if !ids.isEmpty, folders.contains(folder) {
                    seenSignatures.insert(item.signature)
                    candidates[item.url.path] = nil
                    lastImportedFile = item.url.lastPathComponent
                }
            }
        }
        candidates = candidates.filter { activePaths.contains($0.key) }
        persistSeen()
    }

    private func mediaItems(in folder: WatchedFolder) -> [(url: URL, signature: String)]? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder.url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return urls.compactMap { url in
            guard Importer.isSupported(url),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            let size = values.fileSize ?? 0
            let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            return (url, "\(url.standardizedFileURL.path)|\(size)|\(modified)")
        }
    }

    private func persistFolders() {
        if let data = try? JSONEncoder().encode(folders) {
            defaults.set(data, forKey: Self.foldersKey)
        }
    }

    private func isDirectChild(_ pathOrSignature: String, of folder: WatchedFolder) -> Bool {
        let prefix = folder.path == "/" ? "/" : folder.path + "/"
        guard pathOrSignature.hasPrefix(prefix) else { return false }
        return !pathOrSignature.dropFirst(prefix.count).contains("/")
    }

    private func persistSeen() {
        // Scans prune obsolete signatures, never files still in a watched folder.
        let values = seenSignatures.sorted()
        defaults.set(values, forKey: Self.seenKey)
    }
}
