import Foundation

/// Where a piece of audio came from. Recordings label microphone audio "You"
/// and system-tap audio "Them" so call transcripts read like a dialogue.
enum AudioSource: String, Codable, Hashable {
    case microphone
    case system
    case imported

    var speakerLabel: String {
        switch self {
        case .microphone: return "You"
        case .system: return "Them"
        case .imported: return ""
        }
    }
}

/// One timestamped chunk of transcript. Times are seconds from the start of
/// the recording/file.
struct TranscriptSegment: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var source: AudioSource = .imported
    /// A user-facing speaker name. `nil` falls back to the source label for
    /// two-track meeting recordings and to no label for ordinary imports.
    /// Optional keeps documents written by earlier Scribe builds decodable.
    var speaker: String? = nil
}

/// A single audio file belonging to a document. Recordings in meeting mode
/// have two tracks (mic + system); imports have one.
struct AudioTrack: Codable, Hashable {
    var source: AudioSource
    /// File name relative to the document's folder.
    var fileName: String
    /// Podcast imports use one track per person. Transcription copies this
    /// label to every segment decoded from the track.
    var speakerName: String? = nil
}

enum DocumentStatus: String, Codable {
    /// Actively being recorded (also the crash marker: a document found in
    /// this state on launch means the app died mid-recording).
    case recording
    case queued
    case transcribing
    case ready
    case failed
    /// Audio recovered after a crash, not yet transcribed.
    case recovered
}

enum DocumentKind: String, Codable {
    case recording
    case imported
}

/// One item in the library: a recording or an imported file plus its
/// transcript. Persisted as document.json inside its own folder.
struct ScribeDocument: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date = Date()
    var kind: DocumentKind
    var status: DocumentStatus
    var duration: TimeInterval = 0
    var tracks: [AudioTrack] = []
    var segments: [TranscriptSegment] = []
    var language: String?
    var modelUsed: String?
    var summary: String?
    var failureReason: String?
    /// For imports: the original source file path (audio is copied in).
    var originalFilePath: String?
    /// Explicit people retained even before a segment has been assigned to
    /// them. Optional for backward compatibility with existing libraries.
    var knownSpeakers: [String]?
    /// Watch-folder jobs can export beside the source automatically once the
    /// queue finishes. Values are `ExportFormat.rawValue` strings.
    var automaticExportDirectory: String?
    var automaticExportFormats: [String]?

    var fullText: String {
        segments.map(\.text).joined(separator: " ")
    }

    var isMeetingRecording: Bool {
        tracks.contains { $0.source == .microphone } && tracks.contains { $0.source == .system }
    }

    func speakerName(for segment: TranscriptSegment) -> String {
        if let speaker = segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines),
           !speaker.isEmpty {
            return speaker
        }
        return isMeetingRecording ? segment.source.speakerLabel : ""
    }

    var availableSpeakerNames: [String] {
        var names: [String] = []
        for name in knownSpeakers ?? [] where !name.isEmpty && !names.contains(name) {
            names.append(name)
        }
        for segment in segments {
            let name = speakerName(for: segment)
            if !name.isEmpty && !names.contains(name) { names.append(name) }
        }
        return names
    }

    var hasSpeakerLabels: Bool {
        isMeetingRecording || !availableSpeakerNames.isEmpty
    }
}

extension TimeInterval {
    /// "1:02:03" / "12:03" style clock string.
    var clockString: String {
        let total = Int(self.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    /// "00:01:02,345" SRT timestamp.
    var srtString: String {
        let ms = Int((self * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms % 3_600_000) / 60_000, (ms % 60_000) / 1000, ms % 1000)
    }

    /// "00:01:02.345" VTT timestamp.
    var vttString: String {
        srtString.replacingOccurrences(of: ",", with: ".")
    }
}
