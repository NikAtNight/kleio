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
    private var vocabularyTerms: [String]?
    private var vocabularyTokens: [Int]?
    /// Read by WhisperKit's synchronous early-stop callback, which runs
    /// off-actor — hence a lock-guarded flag rather than actor state.
    private let cancelFlag = CancelFlag()

    var isLoaded: Bool { whisperKit != nil }

    /// Names and correction targets that Whisper should treat as prior text.
    /// Passing nil removes the bias.
    func setVocabulary(_ terms: [String]?) {
        vocabularyTerms = terms
        refreshVocabularyTokens()
    }

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
        refreshVocabularyTokens()
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

        // The queue already owns the configured ReplacementStore. Reading the
        // saved terms here keeps the prompt current without changing its API.
        setVocabulary(ReplacementStore.vocabularyTerms())

        var options = Self.decodingOptions(language: language, translate: translate, model: loadedModel)
        options.promptTokens = vocabularyTokens

        let duration = audioDuration(of: url)
        let flag = cancelFlag
        let engineProgress = whisperKit.progress
        let initialProgress = engineProgress.fractionCompleted
        let callback: TranscriptionCallback = { progress in
            // The engine tracks completed audio windows. Timestamp tokens in
            // provisional text restart in each window and cannot measure file progress.
            onProgress?(min(1, max(0, engineProgress.fractionCompleted - initialProgress)),
                        Transcriber.stripSpecialTokens(from: progress.text))
            // Returning false stops decoding early (cancellation).
            return flag.isSet ? false : nil
        }

        let results = try await whisperKit.transcribe(
            audioPath: url.path,
            decodeOptions: options,
            callback: callback
        )
        if cancelFlag.isSet { throw TranscriberError.cancelled }

        return Self.segments(from: results, source: source, duration: duration)
    }

    nonisolated static func decodingOptions(language: String?, translate: Bool, model: String?) -> DecodingOptions {
        let selectedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedLanguage = selectedLanguage.flatMap { $0.isEmpty ? nil : $0 }
            ?? (model?.hasSuffix(".en") == true ? "en" : nil)
        return DecodingOptions(
            task: translate ? .translate : .transcribe,
            language: resolvedLanguage,
            temperature: 0,
            detectLanguage: resolvedLanguage == nil,
            wordTimestamps: true
        )
    }

    private func refreshVocabularyTokens() {
        guard let whisperKit, let tokenizer = whisperKit.tokenizer else {
            vocabularyTokens = nil
            return
        }
        let terms = (vocabularyTerms ?? []).filter { !$0.isEmpty }
        guard !terms.isEmpty else {
            vocabularyTokens = nil
            return
        }
        let tokens = tokenizer.encode(text: " Glossary: \(terms.joined(separator: ", ")).")
        vocabularyTokens = tokens.isEmpty ? nil : Array(tokens.prefix(96))
    }

    nonisolated static func segments(
        from results: [TranscriptionResult], source: AudioSource, duration: TimeInterval? = nil
    ) -> [TranscriptSegment] {
        if let duration, !duration.isFinite || duration <= 0 { return [] }
        var out: [TranscriptSegment] = []
        for result in results {
            for seg in result.segments {
                guard let interval = boundedInterval(start: seg.start, end: seg.end, duration: duration) else { continue }
                var text = stripSpecialTokens(from: seg.text)
                var rejectedWords = false
                let words = seg.words?.compactMap { word -> TranscriptWord? in
                    let clean = stripSpecialTokens(from: word.word)
                    guard !clean.isEmpty else { return nil }
                    guard let timing = boundedInterval(start: word.start, end: word.end, duration: duration) else {
                        rejectedWords = true
                        return nil
                    }
                    // Keep the leading space Whisper uses to join words.
                    let prefix = String(word.word.prefix(while: { $0.isWhitespace }))
                    return TranscriptWord(start: timing.start, end: timing.end,
                                          text: prefix + clean, probability: word.probability)
                }
                if rejectedWords {
                    // Removing timestamps must also remove the rejected words
                    // from the displayed text, including padded tail speech.
                    text = (words ?? []).map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard !text.isEmpty else { continue }
                out.append(TranscriptSegment(
                    start: interval.start,
                    end: interval.end,
                    text: text,
                    source: source,
                    words: words
                ))
            }
        }
        return out
    }

    private nonisolated static func boundedInterval(
        start: Float, end: Float, duration: TimeInterval?
    ) -> (start: TimeInterval, end: TimeInterval)? {
        let start = TimeInterval(start)
        let end = TimeInterval(end)
        guard start.isFinite, end.isFinite, end >= start,
              end > 0 || start == 0,
              duration.map({ start < $0 }) ?? true else { return nil }
        return (max(0, start), min(end, duration ?? end))
    }

    /// Whisper emits inline special tokens like <|startoftranscript|> and
    /// timestamp tokens <|0.00|>, plus bracketed noise markers.
    nonisolated static func stripSpecialTokens(from text: String) -> String {
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
