import Foundation

/// Finds word substitutions a user made while editing a transcript segment.
/// Insertions and deletions are editing choices, not reliable recognition fixes.
enum DictationDiff {
    private static let commonWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "if", "then", "than",
        "is", "are", "was", "were", "be", "been", "am", "do", "does", "did",
        "have", "has", "had", "i", "you", "he", "she", "it", "we", "they",
        "me", "him", "her", "us", "them", "my", "your", "his", "its", "our",
        "their", "this", "that", "these", "those", "to", "of", "in", "on",
        "at", "for", "with", "from", "by", "as", "not", "no", "yes", "can",
        "will", "would", "should", "could", "just", "very", "really", "now",
        "up", "out", "one", "two", "too", "there", "here", "what", "when",
        "where", "who", "how", "why", "all", "any", "some", "more", "most",
    ]

    /// Returns unique `wrong -> right` candidates in reading order.
    static func proposedCorrections(original: String, edited: String) -> [(wrong: String, right: String)] {
        let originalWords = words(in: original)
        let editedWords = words(in: edited)
        guard !originalWords.isEmpty, !editedWords.isEmpty else { return [] }

        var proposals: [(wrong: String, right: String)] = []
        var seen = Set<String>()
        for (before, after) in substitutions(originalWords, editedWords) {
            let wrong = trimPunctuation(before)
            let right = trimPunctuation(after)
            guard isLearnable(wrong: wrong, right: right) else { continue }
            guard seen.insert(wrong.lowercased()).inserted else { continue }
            proposals.append((wrong, right))
        }
        return proposals
    }

    private static func isLearnable(wrong: String, right: String) -> Bool {
        guard !wrong.isEmpty, !right.isEmpty,
              wrong.lowercased() != right.lowercased(),
              !commonWords.contains(wrong.lowercased()),
              wrong.count > 2, right.count > 1 else { return false }
        return true
    }

    /// Uses an LCS alignment so only one-for-one unmatched words become
    /// candidates. The table is bounded to keep large pasted edits cheap.
    private static func substitutions(_ before: [String], _ after: [String]) -> [(String, String)] {
        guard before.count <= 400, after.count <= 400 else { return [] }
        var lengths = Array(
            repeating: Array(repeating: 0, count: after.count + 1),
            count: before.count + 1
        )
        for i in stride(from: before.count - 1, through: 0, by: -1) {
            for j in stride(from: after.count - 1, through: 0, by: -1) {
                lengths[i][j] = before[i].lowercased() == after[j].lowercased()
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }

        var result: [(String, String)] = []
        var i = 0
        var j = 0
        while i < before.count, j < after.count {
            if before[i].lowercased() == after[j].lowercased() {
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                if lengths[i + 1][j] == lengths[i][j + 1] {
                    result.append((before[i], after[j]))
                    i += 1
                    j += 1
                } else {
                    i += 1
                }
            } else {
                j += 1
            }
        }
        return result
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func trimPunctuation(_ word: String) -> String {
        word.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }
}
