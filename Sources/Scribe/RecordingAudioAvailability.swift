import AVFoundation
import Foundation

/// The recovery screen and transcription queue use the same local file check.
struct RecordingAudioAvailability {
    enum State: String {
        case available, missing, empty, unreadable

        var label: String {
            switch self {
            case .available: return "Available"
            case .missing: return "Missing"
            case .empty: return "Empty"
            case .unreadable: return "Can't open"
            }
        }
    }

    struct Item {
        let track: AudioTrack
        let state: State

        var name: String { RecordingAudioAvailability.name(for: track) }
    }

    let items: [Item]
    var availableTracks: [AudioTrack] { items.filter { $0.state == .available }.map(\.track) }
    var unavailable: [Item] { items.filter { $0.state != .available } }

    static func name(for track: AudioTrack) -> String {
        switch track.source {
        case .microphone: return "Microphone"
        case .system: return "App audio"
        case .imported: return track.speakerName ?? "Imported audio"
        }
    }

    static func inspect(_ document: ScribeDocument, folder: URL) -> Self {
        Self(items: document.tracks.map { track in
            let url = folder.appendingPathComponent(track.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return Item(track: track, state: .missing)
            }
            do {
                let file = try AVAudioFile(forReading: url)
                guard file.length > 0 else { return Item(track: track, state: .empty) }
                guard file.processingFormat.sampleRate > 0,
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                   frameCapacity: AVAudioFrameCount(min(file.length, 1_024))) else {
                    return Item(track: track, state: .unreadable)
                }
                try file.read(into: buffer)
                return Item(track: track, state: buffer.frameLength > 0 ? .available : .empty)
            } catch {
                return Item(track: track, state: .unreadable)
            }
        })
    }
}
