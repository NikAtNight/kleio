import Foundation
import SwiftUI
import WhisperKit

/// One entry in the curated model catalog.
struct WhisperModelInfo: Identifiable, Hashable {
    let variant: String
    let displayName: String
    let detail: String
    let approxSizeMB: Int
    var id: String { variant }

    var sizeString: String {
        approxSizeMB >= 1000
            ? String(format: "%.1f GB", Double(approxSizeMB) / 1000)
            : "\(approxSizeMB) MB"
    }
}

/// Downloads, deletes, and selects WhisperKit CoreML models. Models live in
/// ~/Library/Application Support/Scribe/models/argmaxinc/whisperkit-coreml/.
/// (~/Documents is deliberately avoided: iCloud "Optimize Mac Storage" can
/// evict model files into dataless stubs — the mysterious-failure lesson
/// learned in LocalFlow.)
@MainActor
final class ModelManager: ObservableObject {
    nonisolated static let downloadBase: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scribe", isDirectory: true)
    }()

    nonisolated static let modelsFolder = downloadBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)

    static let catalog: [WhisperModelInfo] = [
        .init(variant: "openai_whisper-tiny", displayName: "Tiny", detail: "Fastest, lowest accuracy · multilingual", approxSizeMB: 80),
        .init(variant: "openai_whisper-tiny.en", displayName: "Tiny (English)", detail: "Fastest, lowest accuracy · English only", approxSizeMB: 80),
        .init(variant: "openai_whisper-base", displayName: "Base", detail: "Fast · multilingual", approxSizeMB: 150),
        .init(variant: "openai_whisper-base.en", displayName: "Base (English)", detail: "Fast · English only", approxSizeMB: 150),
        .init(variant: "openai_whisper-small", displayName: "Small", detail: "Good balance · multilingual", approxSizeMB: 490),
        .init(variant: "openai_whisper-small.en", displayName: "Small (English)", detail: "Good balance · English only", approxSizeMB: 490),
        .init(variant: "openai_whisper-medium", displayName: "Medium", detail: "High accuracy, slower · multilingual", approxSizeMB: 1500),
        .init(variant: "openai_whisper-medium.en", displayName: "Medium (English)", detail: "High accuracy, slower · English only", approxSizeMB: 1500),
        .init(variant: "openai_whisper-large-v3", displayName: "Large v3", detail: "Best accuracy, slowest · multilingual", approxSizeMB: 3100),
        .init(variant: "openai_whisper-large-v3-v20240930", displayName: "Large v3 Turbo", detail: "Near-best accuracy, much faster · multilingual", approxSizeMB: 1600),
        .init(variant: "distil-whisper_distil-large-v3", displayName: "Distil Large v3", detail: "Large-class accuracy at small-class speed · English only", approxSizeMB: 1500),
    ]

    @Published private(set) var downloadedVariants: Set<String> = []
    @Published private(set) var downloadProgress: [String: Double] = [:]
    @Published var selectedVariant: String {
        didSet { UserDefaults.standard.set(selectedVariant, forKey: "selectedModel") }
    }

    init() {
        selectedVariant = UserDefaults.standard.string(forKey: "selectedModel") ?? "openai_whisper-small.en"
        Self.seedFromLocalFlowIfAvailable()
        refresh()
        // If the stored selection was deleted on disk, fall back to any
        // downloaded model rather than forcing a surprise download.
        if !downloadedVariants.contains(selectedVariant), let first = downloadedVariants.first {
            selectedVariant = first
        }
    }

    func refresh() {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(atPath: Self.modelsFolder.path)) ?? []
        downloadedVariants = Set(contents.filter { name in
            // A model dir is complete when its MelSpectrogram compile input
            // exists; a bare folder can be a partial download.
            fm.fileExists(atPath: Self.modelsFolder.appendingPathComponent("\(name)/config.json").path)
                || fm.fileExists(atPath: Self.modelsFolder.appendingPathComponent("\(name)/MelSpectrogram.mlmodelc").path)
        })
    }

    func isDownloaded(_ variant: String) -> Bool {
        downloadedVariants.contains(variant)
    }

    func download(_ variant: String) async {
        guard downloadProgress[variant] == nil else { return }
        downloadProgress[variant] = 0
        do {
            _ = try await WhisperKit.download(
                variant: variant,
                downloadBase: Self.downloadBase,
                from: "argmaxinc/whisperkit-coreml",
                progressCallback: { progress in
                    Task { @MainActor [weak self] in
                        self?.downloadProgress[variant] = progress.fractionCompleted
                    }
                }
            )
            downloadProgress[variant] = nil
            refresh()
        } catch {
            DiagLog.log("model download failed for %@: %@", variant, error.localizedDescription)
            downloadProgress[variant] = nil
            refresh()
        }
    }

    func delete(_ variant: String) {
        try? FileManager.default.removeItem(at: Self.modelsFolder.appendingPathComponent(variant))
        refresh()
        if selectedVariant == variant, let first = downloadedVariants.first {
            selectedVariant = first
        }
    }

    /// LocalFlow (the user's dictation app) already has small.en downloaded —
    /// copy it over on first run so Scribe works instantly with no download.
    /// Static so the headless --transcribe path can seed too.
    nonisolated static func seedFromLocalFlowIfAvailable() {
        let fm = FileManager.default
        let localFlow = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalFlow/models/argmaxinc/whisperkit-coreml", isDirectory: true)
        guard let variants = try? fm.contentsOfDirectory(atPath: localFlow.path) else { return }
        for variant in variants where variant.hasPrefix("openai_") || variant.hasPrefix("distil-") {
            let dest = modelsFolder.appendingPathComponent(variant)
            guard !fm.fileExists(atPath: dest.path) else { continue }
            try? fm.createDirectory(at: modelsFolder, withIntermediateDirectories: true)
            do {
                try fm.copyItem(at: localFlow.appendingPathComponent(variant), to: dest)
                DiagLog.log("seeded model %@ from LocalFlow", variant)
            } catch {
                DiagLog.log("model seed failed for %@: %@", variant, error.localizedDescription)
            }
        }
    }
}
