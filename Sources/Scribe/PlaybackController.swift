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

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    func load(document: ScribeDocument) async {
        guard documentID != document.id else { return }
        unload()
        documentID = document.id

        let composition = AVMutableComposition()
        let folder = LibraryStore.folder(for: document.id)
        for track in document.tracks {
            let asset = AVURLAsset(url: folder.appendingPathComponent(track.fileName))
            guard let assetTrack = try? await asset.loadTracks(withMediaType: .audio).first,
                  let assetDuration = try? await asset.load(.duration),
                  let compositionTrack = composition.addMutableTrack(
                    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
                  ) else { continue }
            try? compositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: assetDuration),
                of: assetTrack, at: .zero
            )
        }
        guard !composition.tracks.isEmpty else { return }

        let item = AVPlayerItem(asset: composition)
        let player = AVPlayer(playerItem: item)
        player.defaultRate = rate
        self.player = player
        duration = composition.duration.seconds

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

    func unload() {
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
