import Foundation
import WhisperKit

/// Wraps WhisperKit: loads a CoreML Whisper model (downloaded from the
/// argmaxinc/whisperkit-coreml registry) and transcribes audio files into
/// timestamped segments. Proven core adapted from LocalFlow.
actor Transcriber {
    enum TranscriberError: Error, LocalizedError {
        case notLoaded
        case cancelled

        var errorDescription: String? {
            switch self {
            case .notLoaded: return "Whisper model is not loaded yet."
            case .cancelled: return "Transcription was cancelled."
            }
        }
    }

    private var whisperKit: WhisperKit?
    private(set) var loadedModel: String?
    private var loadGeneration = 0
    /// Read by WhisperKit's synchronous early-stop callback, which runs
    /// off-actor — hence a lock-guarded flag rather than actor state.
    private let cancelFlag = CancelFlag()

    var isLoaded: Bool { whisperKit != nil }

    /// Loads (and if needed downloads) the given model. Safe to call again
    /// with a different model name: the previous pipeline keeps serving until
    /// the replacement is ready, so a failed load never strands the app.
    func load(model: String) async throws {
        if loadedModel == model, whisperKit != nil { return }
        loadGeneration += 1
        let generation = loadGeneration

        let config = WhisperKitConfig(model: model, downloadBase: ModelManager.downloadBase)
        let pipe = try await WhisperKit(config)

        // The actor is reentrant across that await: last requested load wins.
        guard generation == loadGeneration else { return }
        whisperKit = pipe
        loadedModel = model
    }

    nonisolated func cancelCurrent() {
        cancelFlag.set()
    }

    /// Transcribes an audio file (any AVFoundation-readable format) into
    /// timestamped segments. `onProgress` receives 0…1 completion estimates
    /// plus the latest decoded text for live preview.
    func transcribe(
        file url: URL,
        source: AudioSource,
        language: String?,
        translate: Bool,
        onProgress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws -> [TranscriptSegment] {
        guard let whisperKit else { throw TranscriberError.notLoaded }
        cancelFlag.clear()

        var options = DecodingOptions()
        options.task = translate ? .translate : .transcribe
        options.temperature = 0
        if let language, !language.isEmpty {
            options.language = language
        } else if loadedModel?.hasSuffix(".en") == true {
            options.language = "en"
        }

        let duration = max(audioDuration(of: url), 0.1)
        let flag = cancelFlag
        let callback: TranscriptionCallback = { progress in
            // Whisper decodes in 30 s windows; the latest segment end is a
            // good progress proxy for a single file.
            let lastEnd = Self.lastTimestamp(in: progress.text)
            onProgress?(min(lastEnd / duration, 1.0), Transcriber.stripSpecialTokens(from: progress.text))
            // Returning false stops decoding early (cancellation).
            return flag.isSet ? false : nil
        }

        let results = try await whisperKit.transcribe(
            audioPath: url.path,
            decodeOptions: options,
            callback: callback
        )
        if cancelFlag.isSet { throw TranscriberError.cancelled }

        return Self.segments(from: results, source: source)
    }

    /// Extracts the last `<|12.34|>` timestamp token from in-flight decoder
    /// text (window-relative, so only a rough progress signal).
    private static func lastTimestamp(in text: String) -> Double {
        guard let match = text.ranges(of: #/<\|(\d+\.\d+)\|>/#).last else { return 0 }
        let token = text[match].dropFirst(2).dropLast(2)
        return Double(token) ?? 0
    }

    static func segments(from results: [TranscriptionResult], source: AudioSource) -> [TranscriptSegment] {
        var out: [TranscriptSegment] = []
        for result in results {
            for seg in result.segments {
                let text = stripSpecialTokens(from: seg.text)
                guard !text.isEmpty else { continue }
                out.append(TranscriptSegment(
                    start: TimeInterval(seg.start),
                    end: TimeInterval(seg.end),
                    text: text,
                    source: source
                ))
            }
        }
        return out
    }

    /// Whisper emits inline special tokens like <|startoftranscript|> and
    /// timestamp tokens <|0.00|>, plus bracketed noise markers.
    static func stripSpecialTokens(from text: String) -> String {
        var result = text
        let patterns = [
            "<\\|[^|]*\\|>",
            "\\[[A-Z_ ]+\\]",
            "(?i)\\((?:music|laughs|laughter|applause|noise|silence|inaudible|coughs)\\)",
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return result
            .replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Lock-guarded bool readable from WhisperKit's synchronous callback thread.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock(); defer { lock.unlock() }
        value = true
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        value = false
    }
}
