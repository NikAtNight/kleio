import CoreML
import FluidAudio
import Foundation

// Only this file imports FluidAudio's ASR types, and it must never import
// WhisperKit: both export `WordTiming` and `Tokenizer`.

/// NVIDIA Parakeet TDT models on Core ML through FluidAudio. Much faster than
/// Whisper, with punctuation and token timings. There is no decoder prompt,
/// so vocabulary terms do nothing; replacement rules still apply afterwards.
final class ParakeetTranscriber: Sendable {
    enum ParakeetError: Error, LocalizedError {
        case unknownModel(String)
        case translationUnsupported
        case unsupportedLanguage(model: String, language: String)

        var errorDescription: String? {
            switch self {
            case .unknownModel(let id):
                return "\(id) isn't a Parakeet model."
            case .translationUnsupported:
                return "Parakeet models can't translate. Turn off Translate to English or choose a Whisper model."
            case .unsupportedLanguage(let model, let language):
                let name = Locale.current.localizedString(forLanguageCode: language) ?? language
                return "\(model) can't transcribe \(name). Choose a Whisper model or change the spoken language in Settings."
            }
        }
    }

    /// Catalog ids are stable strings saved in documents and preferences.
    nonisolated static let models: [String: AsrModelVersion] = [
        "parakeet-tdt-0.6b-v3": .v3,
        "parakeet-tdt-0.6b-v2": .v2,
        "parakeet-tdt-ctc-110m": .tdtCtc110m,
        "parakeet-tdt-0.6b-ja": .tdtJa,
    ]

    /// v3 covers 25 European languages; the others are single-language.
    nonisolated static let supportedLanguages: [String: Set<String>] = [
        "parakeet-tdt-0.6b-v3": ["bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it",
                                 "lv", "lt", "mt", "pl", "pt", "ro", "sk", "sl", "es", "sv", "ru", "uk"],
        "parakeet-tdt-0.6b-v2": ["en"],
        "parakeet-tdt-ctc-110m": ["en"],
        "parakeet-tdt-0.6b-ja": ["ja"],
    ]

    /// Short clips, like a quick dictation, are padded with trailing silence
    /// to this length. FluidAudio rejects audio under 0.3 s and can return no
    /// tokens for very short speech.
    nonisolated static let minimumSeconds: TimeInterval = 1.5

    nonisolated static let modelsFolder = ModelManager.downloadBase
        .appendingPathComponent("models/FluidAudio", isDirectory: true)

    private let asr: AsrManager
    private let version: AsrModelVersion
    private let decoderLayers: Int

    private init(asr: AsrManager, version: AsrModelVersion, decoderLayers: Int) {
        self.asr = asr
        self.version = version
        self.decoderLayers = decoderLayers
    }

    nonisolated static func isParakeet(_ model: String) -> Bool {
        models[model] != nil
    }

    /// FluidAudio takes the repo folder itself and downloads into its parent.
    nonisolated static func directory(for version: AsrModelVersion) -> URL {
        modelsFolder.appendingPathComponent(
            AsrModels.defaultCacheDirectory(for: version).lastPathComponent, isDirectory: true
        )
    }

    nonisolated static func isDownloaded(_ model: String) -> Bool {
        guard let version = models[model] else { return false }
        return AsrModels.modelsExist(at: directory(for: version), version: version)
    }

    nonisolated static func download(_ model: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let version = models[model] else { throw ParakeetError.unknownModel(model) }
        try FileManager.default.createDirectory(at: modelsFolder, withIntermediateDirectories: true)
        try await AsrModels.download(to: directory(for: version), version: version) {
            progress($0.fractionCompleted)
        }
    }

    nonisolated static func delete(_ model: String) {
        guard let version = models[model] else { return }
        try? FileManager.default.removeItem(at: directory(for: version))
    }

    /// Downloads the model if needed, then loads it. A cold first load also
    /// compiles the Core ML models for this Mac.
    static func load(model: String) async throws -> ParakeetTranscriber {
        guard let version = models[model] else { throw ParakeetError.unknownModel(model) }
        try FileManager.default.createDirectory(at: modelsFolder, withIntermediateDirectories: true)
        let folder = try await AsrModels.download(to: directory(for: version), version: version)
        let loaded = try await AsrModels.load(from: folder, version: version)
        let asr = AsrManager()
        try await asr.loadModels(loaded)
        return ParakeetTranscriber(asr: asr, version: version, decoderLayers: await asr.decoderLayerCount)
    }

    /// Throws before any audio is decoded when the request can't be honored.
    nonisolated static func validate(model: String, language: String?, translate: Bool) throws {
        if translate { throw ParakeetError.translationUnsupported }
        guard let language, !language.isEmpty,
              let supported = supportedLanguages[model], !supported.contains(language) else { return }
        throw ParakeetError.unsupportedLanguage(model: ModelManager.displayName(for: model), language: language)
    }

    /// Transcribes a whole file. Long files are read from disk in chunks, so
    /// memory stays flat for hour-long meetings. Cancelling the calling task
    /// stops decoding between chunks.
    func transcribe(
        file url: URL,
        source: AudioSource,
        language: String?,
        duration: TimeInterval,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws -> [TranscriptSegment] {
        // FluidAudio reports progress only for audio over 15 s and finishes
        // the stream only then. Files over 30 s always take that path, so a
        // shorter file never leaves this reader waiting.
        var progressTask: Task<Void, Never>?
        if let onProgress, duration > 30 {
            let stream = await asr.transcriptionProgressStream
            progressTask = Task {
                do {
                    for try await fraction in stream { onProgress(fraction) }
                } catch {}
            }
        }
        defer { progressTask?.cancel() }

        // A fresh state per file: a cancelled call must not leak decoder
        // state into the next one.
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let hint = version == .v3 ? language.flatMap(Language.init(rawValue:)) : nil
        let result: ASRResult
        if duration < Self.minimumSeconds {
            let samples = Self.padded(try AudioConverter().resampleAudioFile(url))
            result = try await asr.transcribe(samples, decoderState: &state, language: hint)
        } else {
            result = try await asr.transcribe(url, decoderState: &state, language: hint)
        }
        let tokens = result.tokenTimings?.map {
            Token(text: $0.token, start: $0.startTime, end: $0.endTime, confidence: $0.confidence)
        }
        return Self.segments(text: result.text, tokens: tokens ?? [], source: source,
                             duration: duration > 0 ? duration : result.duration)
    }

    // MARK: - Pure helpers (no FluidAudio types, unit-tested)

    /// Pads 16 kHz samples with trailing zeros up to `minimumSeconds`.
    static func padded(_ samples: [Float], sampleRate: Int = 16_000) -> [Float] {
        let minimum = Int((Double(sampleRate) * minimumSeconds).rounded(.up))
        guard samples.count < minimum else { return samples }
        return samples + [Float](repeating: 0, count: minimum - samples.count)
    }

    struct Token: Equatable {
        let text: String
        let start: TimeInterval
        let end: TimeInterval
        var confidence: Float = 1
    }

    /// A pause this long ends a segment even without sentence punctuation.
    /// FluidAudio token times are emission times, and replayed pauses came
    /// out about 0.7 s shorter than the real silence, so this is roughly a
    /// 1.7 s gap in the audio.
    static let pauseSeconds: TimeInterval = 1.0
    /// Long run-on speech still breaks into readable, seekable segments.
    static let maximumSegmentSeconds: TimeInterval = 30

    /// Groups SentencePiece tokens into words and words into segments.
    /// A token that starts with a space (or "▁"), or follows a bare space
    /// token, starts a word. Unspaced punctuation tokens join the previous
    /// word without extending its end time, because FluidAudio emits them
    /// after the pause that follows the sentence.
    /// If the tokens don't rebuild the text, the whole file is one segment
    /// without word timings: the output is never worse than the engine text.
    static func segments(
        text: String, tokens: [Token], source: AudioSource, duration: TimeInterval
    ) -> [TranscriptSegment] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, duration.isFinite, duration > 0 else { return [] }
        let whole = [TranscriptSegment(start: 0, end: duration, text: trimmed, source: source)]

        var words: [TranscriptWord] = []
        var confidences: [[Float]] = []
        // A bare word-boundary token comes before digits: " ", "3".
        var pendingBoundary = false
        for token in tokens {
            let piece = token.text.replacingOccurrences(of: "\u{2581}", with: " ")
            let core = piece.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty else {
                pendingBoundary = true
                continue
            }
            let start = min(max(0, token.start), duration)
            let end = min(max(start, token.end), duration)
            let spaced = pendingBoundary || piece.first?.isWhitespace == true
            pendingBoundary = false
            // Scripts without spaces still need word breaks after a sentence.
            let afterSentence = words.last?.text.last.map { "。？！".contains($0) } ?? false
            if !spaced, !afterSentence, core.allSatisfy(\.isPunctuation), !words.isEmpty {
                words[words.count - 1].text += core
            } else if words.isEmpty || spaced || afterSentence {
                // A spaced opening quote or "¿" starts a word that the next
                // unspaced token continues.
                let previousEnd = words.last?.end ?? 0
                words.append(TranscriptWord(start: max(start, words.last?.start ?? 0), end: max(end, previousEnd),
                                            text: words.isEmpty || !spaced ? core : " " + core))
                confidences.append([token.confidence])
            } else {
                words[words.count - 1].text += core
                words[words.count - 1].end = max(words[words.count - 1].end, end)
                confidences[confidences.count - 1].append(token.confidence)
            }
        }
        for index in words.indices where !confidences[index].isEmpty {
            words[index].probability = confidences[index].reduce(0, +) / Float(confidences[index].count)
        }
        guard !words.isEmpty,
              collapsed(words.map(\.text).joined()) == collapsed(trimmed) else { return whole }

        var segments: [TranscriptSegment] = []
        var current: [TranscriptWord] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            var trimmedWords = current
            trimmedWords[0].text = trimmedWords[0].text.trimmingCharacters(in: .whitespaces)
            let segmentText = trimmedWords.map(\.text).joined()
            segments.append(TranscriptSegment(start: first.start, end: last.end, text: segmentText,
                                              source: source, words: current))
            current = []
        }
        for word in words {
            if let last = current.last, let first = current.first {
                let pause = word.start - last.end
                let sentenceEnded = last.text.last.map { ".?!。？！".contains($0) } ?? false
                if sentenceEnded || pause >= pauseSeconds || word.end - first.start > maximumSegmentSeconds {
                    flush()
                }
            }
            current.append(word)
        }
        flush()
        return segments
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
