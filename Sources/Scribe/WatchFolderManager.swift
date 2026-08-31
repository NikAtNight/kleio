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
        didSet { UserDefaults.standard.set(autoTranscribe, forKey: "watchAutoTranscribe") }
    }
    @Published var autoExport: Bool {
        didSet { UserDefaults.standard.set(autoExport, forKey: "watchAutoExport") }
    }
    @Published var exportFormats: Set<ExportFormat> {
        didSet {
            UserDefaults.standard.set(exportFormats.map(\.rawValue).sorted(), forKey: "watchExportFormats")
        }
    }
    @Published private(set) var lastImportedFile: String?

    private weak var library: LibraryStore?
    private weak var queue: TranscriptionQueue?
    private var timer: Timer?
    private var seenSignatures: Set<String> = []
    private var candidates: [String: String] = [:]

    private static let foldersKey = "watchedFolders"
    private static let seenKey = "watchSeenSignatures"

    init() {
        let defaults = UserDefaults.standard
        autoTranscribe = defaults.object(forKey: "watchAutoTranscribe") == nil
            ? true : defaults.bool(forKey: "watchAutoTranscribe")
        autoExport = defaults.object(forKey: "watchAutoExport") == nil
            ? true : defaults.bool(forKey: "watchAutoExport")
        let rawFormats = defaults.stringArray(forKey: "watchExportFormats") ?? [ExportFormat.txt.rawValue]
        exportFormats = Set(rawFormats.compactMap(ExportFormat.init(rawValue:)))
        if let data = defaults.data(forKey: Self.foldersKey),
           let decoded = try? JSONDecoder().decode([WatchedFolder].self, from: data) {
            folders = decoded.filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        seenSignatures = Set(defaults.stringArray(forKey: Self.seenKey) ?? [])
    }

    func configure(library: LibraryStore, queue: TranscriptionQueue) {
        self.library = library
        self.queue = queue
        guard timer == nil else { return }
        scan()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
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
        for item in mediaItems(in: folder) {
            seenSignatures.insert(item.signature)
        }
        persistFolders()
        persistSeen()
    }

    func removeFolder(_ folder: WatchedFolder) {
        folders.removeAll { $0.id == folder.id }
        candidates = candidates.filter { !$0.key.hasPrefix(folder.path + "/") }
        persistFolders()
    }

    func scanNow() {
        scan()
    }

    private func scan() {
        guard autoTranscribe, let library, let queue else { return }
        var activePaths = Set<String>()
        for folder in folders {
            for item in mediaItems(in: folder) {
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
                let ids = Importer.importFiles(
                    [item.url],
                    library: library,
                    queue: queue,
                    automaticExportDirectory: autoExport ? folder.url : nil,
                    automaticExportFormats: formats
                )
                if !ids.isEmpty {
                    seenSignatures.insert(item.signature)
                    candidates[item.url.path] = nil
                    lastImportedFile = item.url.lastPathComponent
                }
            }
        }
        candidates = candidates.filter { activePaths.contains($0.key) }
        persistSeen()
    }

    private func mediaItems(in folder: WatchedFolder) -> [(url: URL, signature: String)] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder.url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
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
            UserDefaults.standard.set(data, forKey: Self.foldersKey)
        }
    }

    private func persistSeen() {
        // Keep preferences bounded even for long-running newsroom workflows.
        let values = Array(seenSignatures.suffix(5_000))
        seenSignatures = Set(values)
        UserDefaults.standard.set(values, forKey: Self.seenKey)
    }
}
