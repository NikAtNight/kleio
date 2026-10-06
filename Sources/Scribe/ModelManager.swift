import Foundation
import SwiftUI
import WhisperKit

enum TranscriptionModelEngine: String, CaseIterable {
    case parakeet, whisper

    var title: String {
        switch self {
        case .parakeet: return "Parakeet"
        case .whisper: return "Whisper"
        }
    }

    var summary: String {
        switch self {
        case .parakeet: return "NVIDIA Parakeet through FluidAudio. Many times faster than Whisper, with punctuation. No vocabulary hints or translation."
        case .whisper: return "OpenAI Whisper through WhisperKit. Widest language coverage, vocabulary hints, and translation to English."
        }
    }
}

/// One entry in the curated model catalog.
struct TranscriptionModelInfo: Identifiable, Hashable {
    let variant: String
    let engine: TranscriptionModelEngine
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

/// Downloads, deletes, and selects transcription models. WhisperKit models
/// live in ~/Library/Application Support/Scribe/models/argmaxinc/whisperkit-coreml/
/// and Parakeet models in .../Scribe/models/FluidAudio/.
/// (~/Documents is deliberately avoided: iCloud "Optimize Mac Storage" can
/// evict model files into dataless stubs — the mysterious-failure lesson
/// learned in Walkie.)
@MainActor
final class ModelManager: ObservableObject {
    nonisolated static let downloadBase: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scribe", isDirectory: true)
    }()

    nonisolated static let modelsFolder = downloadBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)

    nonisolated static let catalog: [TranscriptionModelInfo] = [
        parakeet("parakeet-tdt-0.6b-v3", "Parakeet v3", "Fastest, high accuracy · 25 European languages", 485),
        parakeet("parakeet-tdt-0.6b-v2", "Parakeet v2 (English)", "Fastest, best Parakeet accuracy for English", 465),
        parakeet("parakeet-tdt-ctc-110m", "Parakeet 110M (English)", "Smallest and fastest · English only", 230),
        parakeet("parakeet-tdt-0.6b-ja", "Parakeet (Japanese)", "Fast · Japanese only", 625),
        whisper("openai_whisper-tiny", "Tiny", "Fastest, lowest accuracy · multilingual", 80),
        whisper("openai_whisper-tiny.en", "Tiny (English)", "Fastest, lowest accuracy · English only", 80),
        whisper("openai_whisper-base", "Base", "Fast · multilingual", 150),
        whisper("openai_whisper-base.en", "Base (English)", "Fast · English only", 150),
        whisper("openai_whisper-small_216MB", "Small (compressed)", "Good balance, smaller download · multilingual", 217),
        whisper("openai_whisper-small", "Small", "Good balance · multilingual", 490),
        whisper("openai_whisper-small.en_217MB", "Small (English, compressed)", "Good balance, smaller download · English only", 218),
        whisper("openai_whisper-small.en", "Small (English)", "Good balance · English only", 490),
        whisper("openai_whisper-medium", "Medium", "High accuracy, slower · multilingual", 1500),
        whisper("openai_whisper-medium.en", "Medium (English)", "High accuracy, slower · English only", 1500),
        whisper("openai_whisper-large-v3_947MB", "Large v3 (compressed)", "Best accuracy, slowest, smaller download · multilingual", 948),
        whisper("openai_whisper-large-v3", "Large v3", "Best accuracy, slowest · multilingual", 3100),
        whisper("openai_whisper-large-v3-v20240930_626MB", "Large v3 Turbo (compressed)", "Near-best accuracy, much faster, smaller download · multilingual", 627),
        whisper("openai_whisper-large-v3-v20240930", "Large v3 Turbo", "Near-best accuracy, much faster · multilingual", 1600),
        whisper("openai_whisper-large-v3-v20240930_turbo", "Large v3 Turbo (Argmax build)", "Large v3 Turbo with Argmax's faster encoder · multilingual", 1640),
        whisper("distil-whisper_distil-large-v3_594MB", "Distil Large v3 (compressed)", "Large-class accuracy at small-class speed, smaller download · English only", 595),
        whisper("distil-whisper_distil-large-v3", "Distil Large v3", "Large-class accuracy at small-class speed · English only", 1500),
    ]

    nonisolated static func info(for variant: String) -> TranscriptionModelInfo? {
        catalog.first { $0.variant == variant }
    }

    nonisolated static func displayName(for variant: String) -> String {
        info(for: variant)?.displayName ?? variant
    }

    private nonisolated static func parakeet(_ variant: String, _ name: String, _ detail: String, _ sizeMB: Int) -> TranscriptionModelInfo {
        TranscriptionModelInfo(variant: variant, engine: .parakeet, displayName: name, detail: detail, approxSizeMB: sizeMB)
    }

    private nonisolated static func whisper(_ variant: String, _ name: String, _ detail: String, _ sizeMB: Int) -> TranscriptionModelInfo {
        TranscriptionModelInfo(variant: variant, engine: .whisper, displayName: name, detail: detail, approxSizeMB: sizeMB)
    }

    @Published private(set) var downloadedVariants: Set<String> = []
    @Published private(set) var downloadProgress: [String: Double] = [:]
    @Published var selectedVariant: String {
        didSet { UserDefaults.standard.set(selectedVariant, forKey: "selectedModel") }
    }

    init() {
        selectedVariant = UserDefaults.standard.string(forKey: "selectedModel") ?? "openai_whisper-small.en"
        Self.seedFromWalkieIfAvailable()
        refresh()
        // If the stored selection was deleted on disk, fall back to any
        // downloaded model rather than forcing a surprise download.
        if !downloadedVariants.contains(selectedVariant), let fallback = fallbackVariant() {
            selectedVariant = fallback
        }
    }

    /// A downloaded model from the same engine first, so a Whisper user
    /// keeps translation and vocabulary hints, then Whisper, in catalog
    /// order. Seeding can add Parakeet models the user never chose.
    private func fallbackVariant() -> String? {
        let engine = Self.info(for: selectedVariant)?.engine ?? .whisper
        let ordered = Self.catalog.filter { $0.engine == engine } + Self.catalog.filter { $0.engine == .whisper }
        return ordered.map(\.variant).first(where: downloadedVariants.contains)
            ?? downloadedVariants.sorted().first
    }

    func refresh() {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(atPath: Self.modelsFolder.path)) ?? []
        downloadedVariants = Set(contents.filter { name in
            // A model dir is complete when its MelSpectrogram compile input
            // exists; a bare folder can be a partial download.
            fm.fileExists(atPath: Self.modelsFolder.appendingPathComponent("\(name)/config.json").path)
                || fm.fileExists(atPath: Self.modelsFolder.appendingPathComponent("\(name)/MelSpectrogram.mlmodelc").path)
        }).union(Self.catalog.filter { $0.engine == .parakeet && ParakeetTranscriber.isDownloaded($0.variant) }.map(\.variant))
    }

    func isDownloaded(_ variant: String) -> Bool {
        downloadedVariants.contains(variant)
    }

    func download(_ variant: String) async {
        guard downloadProgress[variant] == nil else { return }
        downloadProgress[variant] = 0
        do {
            if ParakeetTranscriber.isParakeet(variant) {
                try await ParakeetTranscriber.download(variant) { [weak self] fraction in
                    Task { @MainActor in
                        self?.downloadProgress[variant] = fraction
                    }
                }
            } else {
                _ = try await WhisperKit.download(
                    variant: variant,
                    downloadBase: Self.downloadBase,
                    from: "argmaxinc/whisperkit-coreml",
                    progressCallback: { [weak self] progress in
                        Task { @MainActor in
                            self?.downloadProgress[variant] = progress.fractionCompleted
                        }
                    }
                )
            }
            downloadProgress[variant] = nil
            refresh()
        } catch {
            DiagLog.log("model download failed for %@: %@", variant, error.localizedDescription)
            downloadProgress[variant] = nil
            refresh()
        }
    }

    func delete(_ variant: String) {
        if ParakeetTranscriber.isParakeet(variant) {
            ParakeetTranscriber.delete(variant)
        } else {
            try? FileManager.default.removeItem(at: Self.modelsFolder.appendingPathComponent(variant))
        }
        refresh()
        if selectedVariant == variant, let fallback = fallbackVariant() {
            selectedVariant = fallback
        }
    }

    /// Walkie (the user's dictation app) may already have Whisper or
    /// Parakeet models downloaded. Its folder kept the LocalFlow name when
    /// the app was renamed. Copy them over so Kleio works with no
    /// download; APFS clones the files instead of duplicating them.
    /// Static so the headless --transcribe path can seed too.
    nonisolated static func seedFromWalkieIfAvailable() {
        let walkie = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalFlow/models", isDirectory: true)
        seed(from: walkie.appendingPathComponent("argmaxinc/whisperkit-coreml", isDirectory: true), to: modelsFolder) {
            $0.hasPrefix("openai_") || $0.hasPrefix("distil-")
        }
        seed(from: walkie.appendingPathComponent("FluidAudio", isDirectory: true),
             to: ParakeetTranscriber.modelsFolder) { $0.hasPrefix("parakeet") }
    }

    private nonisolated static func seed(from source: URL, to destination: URL, where include: (String) -> Bool) {
        let fm = FileManager.default
        guard let variants = try? fm.contentsOfDirectory(atPath: source.path) else { return }
        for variant in variants where include(variant) {
            let dest = destination.appendingPathComponent(variant)
            guard !fm.fileExists(atPath: dest.path) else { continue }
            try? fm.createDirectory(at: destination, withIntermediateDirectories: true)
            do {
                try fm.copyItem(at: source.appendingPathComponent(variant), to: dest)
                DiagLog.log("seeded model %@ from Walkie", variant)
            } catch {
                DiagLog.log("model seed failed for %@: %@", variant, error.localizedDescription)
            }
        }
    }
}
