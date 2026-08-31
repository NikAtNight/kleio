import Foundation
import AppKit
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case txt, md, html, srt, vtt, csv, json

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .txt: return "Plain Text (.txt)"
        case .md: return "Markdown (.md)"
        case .html: return "Web Page (.html)"
        case .srt: return "Subtitles (.srt)"
        case .vtt: return "WebVTT (.vtt)"
        case .csv: return "CSV (.csv)"
        case .json: return "JSON (.json)"
        }
    }

    var contentType: UTType {
        switch self {
        case .txt: return .plainText
        case .md: return UTType(filenameExtension: "md") ?? .plainText
        case .html: return .html
        case .srt: return UTType(filenameExtension: "srt") ?? .plainText
        case .vtt: return UTType(filenameExtension: "vtt") ?? .plainText
        case .csv: return .commaSeparatedText
        case .json: return .json
        }
    }
}

enum Exporter {
    static func render(_ doc: ScribeDocument, as format: ExportFormat) -> String {
        switch format {
        case .txt: return plainText(doc)
        case .md: return markdown(doc)
        case .html: return html(doc)
        case .srt: return srt(doc)
        case .vtt: return vtt(doc)
        case .csv: return csv(doc)
        case .json: return json(doc)
        }
    }

    @MainActor
    static func exportWithPanel(_ doc: ScribeDocument, format: ExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = sanitizedFileName(doc.title) + "." + format.rawValue
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try render(doc, as: format).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Watch-folder imports remember their source directory and requested
    /// formats. Exporting here keeps automation independent of the UI.
    static func exportAutomaticallyIfNeeded(_ doc: ScribeDocument) {
        guard let path = doc.automaticExportDirectory,
              let rawFormats = doc.automaticExportFormats,
              !rawFormats.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for raw in rawFormats {
            guard let format = ExportFormat(rawValue: raw) else { continue }
            let url = directory
                .appendingPathComponent(sanitizedFileName(doc.title))
                .appendingPathExtension(format.rawValue)
            do {
                try render(doc, as: format).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSLog("Scribe: automatic export failed for %@: %@", doc.title, error.localizedDescription)
            }
        }
    }

    static func sanitizedFileName(_ name: String) -> String {
        name.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func speakerPrefix(_ seg: TranscriptSegment, in doc: ScribeDocument) -> String {
        let speaker = doc.speakerName(for: seg)
        return speaker.isEmpty ? "" : "\(speaker): "
    }

    private static func plainText(_ doc: ScribeDocument) -> String {
        TranscriptTimelineRow.merged(segments: doc.segments, notes: doc.notes ?? [])
            .map { row in
                switch row {
                case .segment(let segment):
                    return "[\(segment.start.clockString)] \(speakerPrefix(segment, in: doc))\(segment.text)"
                case .note(let note):
                    return "[\(note.time.clockString)] Note: \(note.text)"
                }
            }
            .joined(separator: "\n")
    }

    private static func markdown(_ doc: ScribeDocument) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        var out = "# \(doc.title)\n\n"
        out += "- **Date:** \(formatter.string(from: doc.createdAt))\n"
        out += "- **Duration:** \(doc.duration.clockString)\n"
        if let model = doc.modelUsed { out += "- **Model:** \(model)\n" }
        out += "\n"
        if let summary = doc.summary, !summary.isEmpty {
            out += "## Summary\n\n\(summary)\n\n"
        }
        out += "## Transcript\n\n"
        for row in TranscriptTimelineRow.merged(segments: doc.segments, notes: doc.notes ?? []) {
            switch row {
            case .segment(let segment):
                let speaker = speakerPrefix(segment, in: doc)
                out += "**[\(segment.start.clockString)]** \(speaker.isEmpty ? "" : "**\(speaker)**")\(segment.text)\n\n"
            case .note(let note):
                out += "> **\(note.time.clockString)** \(note.text)\n\n"
            }
        }
        return out
    }

    private static func html(_ doc: ScribeDocument) -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        let body = TranscriptTimelineRow.merged(segments: doc.segments, notes: doc.notes ?? []).map { row in
            switch row {
            case .segment(let segment):
                let speaker = doc.speakerName(for: segment)
                let speakerHTML = speaker.isEmpty ? "" : "<strong>\(escape(speaker)):</strong> "
                return "<p><time>\(segment.start.clockString)</time> \(speakerHTML)\(escape(segment.text))</p>"
            case .note(let note):
                return "<p class=\"note\"><time>\(note.time.clockString)</time> <strong>Note:</strong> \(escape(note.text))</p>"
            }
        }.joined(separator: "\n")
        let summary = doc.summary.map { "<section><h2>Summary</h2><p>\(escape($0).replacingOccurrences(of: "\n", with: "<br>"))</p></section>" } ?? ""
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <title>\(escape(doc.title))</title>
        <style>body{font:16px -apple-system,BlinkMacSystemFont,sans-serif;max-width:820px;margin:40px auto;padding:0 20px;line-height:1.5}time{color:#777;font-variant-numeric:tabular-nums;margin-right:.6rem}h1{margin-bottom:.25rem}.meta{color:#666}</style></head>
        <body><h1>\(escape(doc.title))</h1><p class="meta">\(escape(doc.createdAt.formatted())) · \(doc.duration.clockString)</p>
        \(summary)<section><h2>Transcript</h2>\(body)</section></body></html>
        """
    }

    private static func srt(_ doc: ScribeDocument) -> String {
        doc.segments.enumerated().map { index, seg in
            "\(index + 1)\n\(seg.start.srtString) --> \(seg.end.srtString)\n\(speakerPrefix(seg, in: doc))\(seg.text)\n"
        }.joined(separator: "\n")
    }

    private static func vtt(_ doc: ScribeDocument) -> String {
        "WEBVTT\n\n" + doc.segments.map { seg in
            "\(seg.start.vttString) --> \(seg.end.vttString)\n\(speakerPrefix(seg, in: doc))\(seg.text)\n"
        }.joined(separator: "\n")
    }

    private static func csv(_ doc: ScribeDocument) -> String {
        func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var out = "start,end,speaker,text\n"
        for seg in doc.segments {
            let speaker = doc.speakerName(for: seg)
            out += "\(seg.start),\(seg.end),\(quote(speaker)),\(quote(seg.text))\n"
        }
        return out
    }

    private static func json(_ doc: ScribeDocument) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(doc), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
