import Foundation

/// The recorded source stays independent of speaker identities and display names.
/// Source labels are fallbacks for documents written before speaker detection.
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
    var speakerID: UUID? = nil
    var words: [TranscriptWord]? = nil
}

struct TranscriptWord: Codable, Hashable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var probability: Float? = nil
}

struct DocumentSpeaker: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var isMicrophone: Bool = false
    var savedPersonID: UUID? = nil
}

struct SpeakerAssignment: Codable, Hashable {
    var segmentID: UUID
    var speakerID: UUID
}

enum SpeakerAnalysisStatus: String, Codable {
    case notRequested, running, complete, failed
}

struct VideoTrack: Codable, Hashable {
    var fileName: String
    var startOffset: TimeInterval
    var duration: TimeInterval
}

/// A user note pinned to a point in a recording or imported file.
struct MeetingNote: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var time: TimeInterval
    var text: String
}

/// An item in the chronological transcript timeline.
enum TranscriptTimelineRow: Identifiable, Hashable {
    case segment(TranscriptSegment)
    case note(MeetingNote)

    enum ID: Hashable {
        case segment(UUID)
        case note(UUID)
    }

    var id: ID {
        switch self {
        case .segment(let segment): return .segment(segment.id)
        case .note(let note): return .note(note.id)
        }
    }

    var time: TimeInterval {
        switch self {
        case .segment(let segment): return segment.start
        case .note(let note): return note.time
        }
    }

    static func merged(segments: [TranscriptSegment], notes: [MeetingNote]) -> [Self] {
        (segments.map(Self.segment) + notes.map(Self.note)).sorted { lhs, rhs in
            if lhs.time != rhs.time { return lhs.time < rhs.time }
            switch (lhs, rhs) {
            case (.segment, .note): return true
            case (.note, .segment): return false
            default: return false
            }
        }
    }
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
    var startOffset: TimeInterval? = nil
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
    /// Cluster-centroid embeddings keyed by the current user-facing speaker
    /// label. Optional for backward compatibility with existing libraries.
    var speakerVoiceprints: [String: [Float]]?
    /// Watch-folder jobs can export beside the source automatically once the
    /// queue finishes. Values are `ExportFormat.rawValue` strings.
    var automaticExportDirectory: String?
    var automaticExportFormats: [String]?
    /// Calendar metadata retained only for an auto-recording. Optional so
    /// documents written by older Scribe builds continue to decode.
    var calendarEventID: String?
    var calendarEventTitle: String?
    /// Optional for backward compatibility with documents written before
    /// timestamped meeting notes were available.
    var notes: [MeetingNote]?
    var speakers: [DocumentSpeaker]?
    var detectedSpeakers: [DocumentSpeaker]?
    var detectedSpeakerAssignments: [SpeakerAssignment]?
    var speakerEditsApplied: Bool?
    var speakerAnalysisStatus: SpeakerAnalysisStatus?
    var speakerAnalysisError: String?
    var speakerModelUsed: String?
    var rawSegments: [TranscriptSegment]?
    var microphoneSpeakerName: String?
    var expectedRemoteSpeakerCount: Int?
    var recordingAppBundleID: String?
    var recordingAppName: String?
    var videoTracks: [VideoTrack]?
    var recoveredAt: Date?
    var transcriptionWarning: String?

    var fullText: String {
        segments.map(\.text).joined(separator: " ")
    }

    var isMeetingRecording: Bool {
        tracks.contains { $0.source == .microphone } && tracks.contains { $0.source == .system }
    }

    var isAutoRecording: Bool { calendarEventID != nil }

    func speakerName(for segment: TranscriptSegment) -> String {
        if kind == .recording, segment.source == .microphone {
            return microphoneSpeakerName ?? segment.source.speakerLabel
        }
        if let id = segment.speakerID,
           let person = speakers?.first(where: { $0.id == id }) {
            return person.name
        }
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

    mutating func rekeySpeakerVoiceprint(from oldName: String, to newName: String) {
        guard var voiceprints = speakerVoiceprints,
              let embedding = voiceprints.removeValue(forKey: oldName) else { return }
        if let existing = voiceprints[newName], existing.count == embedding.count {
            let average = zip(existing, embedding).map { ($0 + $1) / 2 }
            voiceprints[newName] = VoiceProfileStore.normalized(average)
        } else {
            voiceprints[newName] = embedding
        }
        speakerVoiceprints = voiceprints
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
