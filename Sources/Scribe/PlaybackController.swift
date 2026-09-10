import Foundation
import AVFoundation
import SwiftUI

/// Plays a document's audio. Meeting recordings have two files (mic +
/// system); they're combined into one AVMutableComposition so both sides
/// play mixed, in sync, through a single scrubber.
@MainActor
final class PlaybackController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var rate: Float = 1.0 {
        didSet {
            player?.defaultRate = rate
            if isPlaying { player?.rate = rate }
        }
    }
    private(set) var documentID: UUID?

    @Published private(set) var player: AVPlayer?
    @Published private(set) var lastError: String?
    private var loadGeneration = UUID()
    private var statusObserver: NSKeyValueObservation?
    private var playbackObserver: NSKeyValueObservation?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    func load(document: ScribeDocument, folder: URL? = nil) async {
        guard documentID != document.id else { return }
        unload()
        documentID = document.id
        let generation = loadGeneration
        let composition = AVMutableComposition()
        let folder = folder ?? LibraryStore.folder(for: document.id)
        var failures: [String] = []
        for track in document.tracks {
            do {
                try await Self.insert(url: folder.appendingPathComponent(track.fileName), type: .audio,
                    offset: track.startOffset ?? 0, into: composition)
            } catch { failures.append("\(track.fileName): \(error.localizedDescription)") }
        }
        for track in document.videoTracks ?? [] {
            do {
                try await Self.insert(url: folder.appendingPathComponent(track.fileName), type: .video,
                    offset: track.startOffset, into: composition)
            } catch { failures.append("\(track.fileName): \(error.localizedDescription)") }
        }
        guard generation == loadGeneration else { return }
        lastError = failures.isEmpty ? nil : "Some media could not be opened. " + failures.joined(separator: " ")
        guard !composition.tracks.isEmpty else { documentID = nil; return }

        let item = AVPlayerItem(asset: composition)
        let player = AVPlayer(playerItem: item)
        player.defaultRate = rate
        self.player = player
        duration = composition.duration.seconds
        playbackObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard self?.loadGeneration == generation else { return }
                self?.isPlaying = player.timeControlStatus != .paused
            }
        }
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in
                guard self?.loadGeneration == generation else { return }
                self?.lastError = item.error?.localizedDescription ?? "Playback failed."
                self?.isPlaying = false
            }
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10), queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.currentTime = time.seconds
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
                self?.player?.seek(to: .zero)
                self?.currentTime = 0
            }
        }
    }

    private static func insert(url: URL, type: AVMediaType, offset: TimeInterval, into composition: AVMutableComposition) async throws {
        let asset = AVURLAsset(url: url)
        guard let source = try await asset.loadTracks(withMediaType: type).first else {
            throw NSError(domain: "Scribe.Playback", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No playable \(type == .video ? "video" : "audio") track."])
        }
        let range = try await source.load(.timeRange)
        guard let destination = composition.addMutableTrack(withMediaType: type,
            preferredTrackID: kCMPersistentTrackID_Invalid) else { return }
        // Preserve an asset's internal leading gap, such as video frames arriving after audio.
        let start = CMTime(seconds: max(0, offset), preferredTimescale: 60_000) + range.start
        do {
            try destination.insertTimeRange(range, of: source, at: start)
            if type == .video { destination.preferredTransform = try await source.load(.preferredTransform) }
        } catch {
            composition.removeTrack(destination)
            throw error
        }
    }

    func unload() {
        loadGeneration = UUID()
        statusObserver = nil
        playbackObserver = nil
        lastError = nil
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        player?.pause()
        player = nil
        timeObserver = nil
        endObserver = nil
        documentID = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.rate = rate
            isPlaying = true
        }
    }

    func seek(to time: TimeInterval) {
        let clamped = max(0, min(time, duration))
        currentTime = clamped
        player?.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero, toleranceAfter: .zero
        )
    }

    func skip(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }
}
