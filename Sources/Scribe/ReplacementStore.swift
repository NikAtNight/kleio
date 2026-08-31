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

    private static let rulesKey = "textReplacementRules"

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
