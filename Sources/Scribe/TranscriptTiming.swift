import Foundation

/// Word alignment shared by turn assembly and speaker analysis. Legacy or
/// edited text without a complete alignment stays intact.
enum TranscriptTiming {
    static func wordRanges(in segment: TranscriptSegment) -> [Range<String.Index>]? {
        guard let words = segment.words, !words.isEmpty,
              words.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }),
              zip(words, words.dropFirst()).allSatisfy({ $0.start <= $1.start && $0.end <= $1.end }) else { return nil }
        var cursor = segment.text.startIndex
        var ranges: [Range<String.Index>] = []
        for word in words {
            let token = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty,
                  let range = segment.text.range(of: token, range: cursor..<segment.text.endIndex),
                  segment.text[cursor..<range.lowerBound].allSatisfy(\.isWhitespace) else { return nil }
            ranges.append(range)
            cursor = range.upperBound
        }
        guard segment.text[cursor...].allSatisfy(\.isWhitespace) else { return nil }
        return ranges
    }

    static func split(_ segment: TranscriptSegment, atWordIndices starts: [Int]) -> [TranscriptSegment]? {
        guard let ranges = wordRanges(in: segment), let words = segment.words,
              starts.first == 0, starts.allSatisfy({ words.indices.contains($0) }),
              zip(starts, starts.dropFirst()).allSatisfy({ $0 < $1 }) else { return nil }
        return starts.enumerated().map { group, first in
            let next = group + 1 < starts.count ? starts[group + 1] : words.count
            let lower = first == 0 ? segment.text.startIndex : ranges[first].lowerBound
            let upper = next == words.count ? segment.text.endIndex : ranges[next].lowerBound
            var turn = segment
            turn.id = first == 0 ? segment.id : UUID()
            turn.start = first == 0 ? segment.start : words[first].start
            turn.end = next == words.count ? segment.end : words[next - 1].end
            turn.text = String(segment.text[lower..<upper]).trimmingCharacters(in: .whitespacesAndNewlines)
            turn.words = Array(words[first..<next])
            return turn
        }
    }

    /// A reply in a pause separates the words before it from the words after it,
    /// even when the recognizer put both in one microphone/app-audio segment.
    /// An interruption can split a turn while retaining its overlapping times.
    /// Speech with no pause remains intact.
    static func chronologicalTurns(from segments: [TranscriptSegment]) -> [TranscriptSegment] {
        let aligned = segments.filter { wordRanges(in: $0) != nil }
        var otherSpeech: [AudioSource: [Range<TimeInterval>]] = [:]
        for source in Set(segments.map(\.source)) {
            let spans = aligned.filter { $0.source != source }.flatMap { $0.words ?? [] }
                .filter { $0.end > $0.start }
                .map { $0.start..<$0.end }
                .sorted { $0.lowerBound < $1.lowerBound }
            var merged: [Range<TimeInterval>] = []
            for span in spans {
                if let last = merged.last, span.lowerBound <= last.upperBound {
                    merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
                } else {
                    merged.append(span)
                }
            }
            otherSpeech[source] = merged
        }
        return segments.flatMap { segment -> [TranscriptSegment] in
            guard wordRanges(in: segment) != nil, let words = segment.words else { return [segment] }
            let spans = otherSpeech[segment.source] ?? []
            var starts = [0]
            for index in 1..<words.count {
                let gapStart = words[index - 1].end
                let gapEnd = words[index].start
                guard gapEnd > gapStart else { continue }
                // Spans are disjoint, so both their starts and ends increase.
                var low = 0
                var high = spans.count
                while low < high {
                    let middle = (low + high) / 2
                    if spans[middle].upperBound <= gapStart { low = middle + 1 } else { high = middle }
                }
                // A turn must fit inside the pause. A voice continuing across
                // the boundary is overlapping speech, not a clean handoff.
                if low < spans.count, spans[low].lowerBound < gapStart { low += 1 }
                if low < spans.count, spans[low].lowerBound < gapEnd,
                   spans[low].upperBound <= gapEnd { starts.append(index) }
            }
            var timed = segment
            timed.start = words[0].start
            timed.end = words.map(\.end).max() ?? segment.end
            return split(timed, atWordIndices: starts) ?? [segment]
        }.sorted { $0.start < $1.start }
    }

    /// Never return to an older enclosing interval after a newer turn ends.
    /// Selecting by time also works after a seek or with an unsorted legacy array.
    static func activeSegmentID(in segments: [TranscriptSegment], at time: TimeInterval) -> UUID? {
        guard time.isFinite else { return nil }
        var latest: TranscriptSegment?
        for segment in segments where segment.start.isFinite && segment.start <= time {
            if let current = latest, segment.start < current.start { continue }
            latest = segment
        }
        guard let latest, time < max(latest.end, latest.start + 0.5) else { return nil }
        return latest.id
    }
}
