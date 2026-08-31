import Foundation
import SwiftUI

struct TextReplacement: Codable, Identifiable, Hashable {
    var id = UUID()
    var original = ""
    var replacement = ""
}

/// User-defined cleanup rules applied to every newly decoded segment. The
/// store is intentionally tiny and lives in UserDefaults so it can be used
/// by dictation, file transcription, and watch-folder jobs alike.
@MainActor
final class ReplacementStore: ObservableObject {
    @Published var rules: [TextReplacement] {
        didSet { save() }
    }
    @Published var caseSensitive: Bool {
        didSet { UserDefaults.standard.set(caseSensitive, forKey: "replacementCaseSensitive") }
    }
    @Published var wholeWords: Bool {
        didSet { UserDefaults.standard.set(wholeWords, forKey: "replacementWholeWords") }
    }
    @Published var removeFillerWords: Bool {
        didSet { UserDefaults.standard.set(removeFillerWords, forKey: "removeFillerWords") }
    }

    nonisolated private static let rulesKey = "textReplacementRules"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.rulesKey),
           let saved = try? JSONDecoder().decode([TextReplacement].self, from: data) {
            rules = saved
        } else {
            rules = []
        }
        caseSensitive = UserDefaults.standard.bool(forKey: "replacementCaseSensitive")
        wholeWords = UserDefaults.standard.object(forKey: "replacementWholeWords") == nil
            ? true : UserDefaults.standard.bool(forKey: "replacementWholeWords")
        removeFillerWords = UserDefaults.standard.bool(forKey: "removeFillerWords")
    }

    func addRule() {
        rules.append(TextReplacement())
    }

    /// Adds a finished correction once. Empty and duplicate rules do not
    /// belong in the cleanup pass or the recognition vocabulary.
    @discardableResult
    func addRule(original: String, replacement: String) -> Bool {
        let original = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty, !replacement.isEmpty,
              !rules.contains(where: {
                  $0.original.trimmingCharacters(in: .whitespacesAndNewlines)
                      .caseInsensitiveCompare(original) == .orderedSame
                      && $0.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
                      .caseInsensitiveCompare(replacement) == .orderedSame
              }) else { return false }
        rules.append(TextReplacement(original: original, replacement: replacement))
        return true
    }

    /// Terms that should bias recognition toward a correction the user has
    /// already taught Scribe. This reads persisted rules for transcribers
    /// that do not share the SwiftUI store instance, such as headless jobs.
    nonisolated static func vocabularyTerms() -> [String] {
        let saved = (UserDefaults.standard.data(forKey: rulesKey))
            .flatMap { try? JSONDecoder().decode([TextReplacement].self, from: $0) } ?? []
        var seen = Set<String>()
        return saved.compactMap { rule in
            let term = rule.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { return nil }
            return term
        }.prefix(50).map { $0 }
    }

    func deleteRules(at offsets: IndexSet) {
        rules.remove(atOffsets: offsets)
    }

    func apply(to text: String) -> String {
        var output = text
        if removeFillerWords {
            output = output.replacingOccurrences(
                of: #"(?i)(?<![\p{L}\p{N}_])(?:um+|uh+|erm+)(?![\p{L}\p{N}_])(?:\s*,)?\s*"#,
                with: "",
                options: .regularExpression
            )
        }
        for rule in rules {
            let original = rule.original.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !original.isEmpty else { continue }
            let escaped = NSRegularExpression.escapedPattern(for: original)
            let boundary = wholeWords ? #"(?<![\p{L}\p{N}_])"# + escaped + #"(?![\p{L}\p{N}_])"# : escaped
            let pattern = caseSensitive ? boundary : "(?i)" + boundary
            output = output.replacingOccurrences(
                of: pattern,
                with: NSRegularExpression.escapedTemplate(for: rule.replacement),
                options: .regularExpression
            )
        }
        return output
            .replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func apply(to segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.map { segment in
            var edited = segment
            edited.text = apply(to: segment.text)
            return edited
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: Self.rulesKey)
        }
    }
}
