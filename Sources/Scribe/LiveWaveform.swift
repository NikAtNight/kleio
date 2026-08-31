import SwiftUI

struct LiveWaveformLane {
    let label: String
    let history: [Float]
    let color: Color

    init(label: String, history: [Float], color: Color) {
        self.label = label
        self.history = history
        self.color = color
    }
}

/// A live scrolling waveform, newest audio at the right edge.
///
/// Renders inside `TimelineView(.animation)` and slides bars left on the
/// display clock: one bar per fixed-rate sample, with a fractional offset
/// interpolated from `lastAppend`, so motion stays smooth no matter how
/// irregularly the audio callbacks arrive.
struct LiveWaveformView: View {
    let lanes: [LiveWaveformLane]
    let isPaused: Bool
    /// When the newest sample landed (drives the interpolated scroll phase).
    var lastAppend: Date = .distantPast
    /// Seconds between samples in each lane's history.
    var sampleInterval: TimeInterval = RecordingSession.waveformSampleInterval

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: isPaused)) { timeline in
            let phase = scrollPhase(at: timeline.date)
            VStack(spacing: lanes.count > 1 ? 12 : 0) {
                ForEach(Array(lanes.enumerated()), id: \.offset) { _, lane in
                    WaveformLaneView(lane: lane, phase: phase)
                        .frame(height: lanes.count > 1 ? 64 : 96)
                }
            }
        }
        .opacity(isPaused ? 0.5 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live audio waveform")
    }

    /// 0 when a sample just landed, approaching 1 as the next one is due.
    private func scrollPhase(at now: Date) -> CGFloat {
        guard lastAppend != .distantPast, sampleInterval > 0 else { return 1 }
        let age = now.timeIntervalSince(lastAppend)
        return CGFloat(min(max(age / sampleInterval, 0), 1))
    }
}

private struct WaveformLaneView: View {
    let lane: LiveWaveformLane
    let phase: CGFloat

    private static let barWidth: CGFloat = 3
    private static let barStride: CGFloat = 5

    var body: some View {
        Canvas { context, size in
            let centerY = size.height / 2
            let centerLine = Path(CGRect(x: 0, y: centerY, width: size.width, height: 1))
            context.fill(centerLine, with: .color(lane.color.opacity(0.14)))

            guard !lane.history.isEmpty else { return }
            let stride = Self.barStride
            let maximumHeight = max(2, size.height - 12)
            let visibleBars = min(lane.history.count, Int(size.width / stride) + 2)
            let newest = lane.history.count - 1

            // Bar age in samples is (index from newest + phase); each bar's
            // right edge slides left continuously as phase advances, and the
            // newest bar enters from beyond the right edge. Canvas clips.
            for j in 0..<visibleBars {
                let sample = lane.history[newest - j]
                let rightEdge = size.width + stride - (CGFloat(j) + phase) * stride
                let x = rightEdge - Self.barWidth
                if rightEdge <= 0 { break }
                let height = max(2, CGFloat(sample) * maximumHeight)
                let rect = CGRect(
                    x: x,
                    y: centerY - height / 2,
                    width: Self.barWidth,
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 1.5),
                    with: .color(lane.color.opacity(0.9))
                )
            }
        }
        .clipped()
        .overlay(alignment: .leading) {
            Text(lane.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.thinMaterial, in: Capsule())
                .padding(.leading, 4)
        }
        .accessibilityLabel(lane.label)
    }
}

#Preview("One voice") {
    LiveWaveformPreview(laneCount: 1)
        .padding(24)
        .frame(width: 620)
}

#Preview("Meeting") {
    LiveWaveformPreview(laneCount: 2)
        .padding(24)
        .frame(width: 620)
}

private struct LiveWaveformPreview: View {
    let laneCount: Int
    @State private var start = Date()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 20)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            LiveWaveformView(
                lanes: previewLanes(at: now),
                isPaused: false,
                lastAppend: timeline.date
            )
        }
    }

    private func previewLanes(at time: TimeInterval) -> [LiveWaveformLane] {
        let you = waveformHistory(at: time, offset: 0)
        if laneCount == 1 {
            return [LiveWaveformLane(label: "You", history: you, color: .accentColor)]
        }
        return [
            LiveWaveformLane(label: "You", history: you, color: .blue),
            LiveWaveformLane(label: "Them", history: waveformHistory(at: time, offset: 1.2), color: .purple),
        ]
    }

    private func waveformHistory(at time: TimeInterval, offset: TimeInterval) -> [Float] {
        (0..<900).map { index in
            SyntheticSpeech.level(at: time - Double(899 - index) / 20 + offset)
        }
    }
}
