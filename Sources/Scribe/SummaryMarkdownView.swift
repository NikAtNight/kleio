import AppKit
import SwiftUI

/// The block-level Markdown that summaries use. SwiftUI's `Text` only renders
/// inline styles, so headings and lists are split out here.
enum SummaryMarkdown {
    enum Block: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(indent: Int, text: String)
        case numbered(indent: Int, marker: String, text: String)
        case task(indent: Int, done: Bool, text: String)
    }

    static func blocks(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let indent = rawLine.prefix { $0 == " " || $0 == "\t" }
                .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
            if line.isEmpty {
                flushParagraph()
            } else if let match = line.wholeMatch(of: #/(#{1,6})\s+(.+?)\s*#*/#) {
                flushParagraph()
                blocks.append(.heading(level: match.1.count, text: String(match.2)))
            } else if let match = line.wholeMatch(of: #/[-*+]\s+\[([ xX])\]\s*(.*)/#) {
                flushParagraph()
                blocks.append(.task(indent: indent, done: match.1 != " ", text: String(match.2)))
            } else if let match = line.wholeMatch(of: #/[-*+]\s+(.+)/#) {
                flushParagraph()
                blocks.append(.bullet(indent: indent, text: String(match.1)))
            } else if let match = line.wholeMatch(of: #/(\d+[.)])\s+(.+)/#) {
                flushParagraph()
                blocks.append(.numbered(indent: indent, marker: String(match.1), text: String(match.2)))
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()
        return blocks
    }
}

struct SummaryMarkdownView: View {
    let markdown: String
    var fontSize: CGFloat = NSFont.systemFontSize

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(SummaryMarkdown.blocks(markdown).enumerated()), id: \.offset) { index, block in
                blockView(block)
                    .padding(.top, index > 0 && isHeading(block) ? 8 : 0)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: SummaryMarkdown.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text, font: .system(size: fontSize + (level <= 2 ? 4 : 2), weight: .semibold))
        case .paragraph(let text):
            inline(text)
        case .bullet(let indent, let text):
            listItem(indent: indent, marker: Text("•"), text: text)
        case .numbered(let indent, let marker, let text):
            listItem(indent: indent, marker: Text(marker).monospacedDigit(), text: text)
        case .task(let indent, let done, let text):
            listItem(indent: indent,
                     marker: Text(Image(systemName: done ? "checkmark.square" : "square")).foregroundStyle(.secondary),
                     text: text)
        }
    }

    private func listItem(indent: Int, marker: Text, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker.font(.system(size: fontSize))
            inline(text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, CGFloat(indent) * 18)
    }

    private func inline(_ text: String, font: Font? = nil) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let attributed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        return Text(attributed).font(font ?? .system(size: fontSize))
    }

    private func isHeading(_ block: SummaryMarkdown.Block) -> Bool {
        if case .heading = block { return true }
        return false
    }
}
