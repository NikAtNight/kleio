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

/// A compact recording history that keeps the newest sample anchored to the right edge.
struct LiveWaveformView: View {
    let lanes: [LiveWaveformLane]
    let isPaused: Bool

    var body: some View {
        VStack(spacing: lanes.count > 1 ? 12 : 0) {
            ForEach(Array(lanes.enumerated()), id: \.offset) { _, lane in
                WaveformLaneView(lane: lane)
                    .frame(height: lanes.count > 1 ? 64 : 96)
            }
        }
        .opacity(isPaused ? 0.5 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live audio waveform")
    }
}

private struct WaveformLaneView: View {
    let lane: LiveWaveformLane

    var body: some View {
        Canvas { context, size in
            let centerY = size.height / 2
            let centerLine = Path(CGRect(x: 0, y: centerY, width: size.width, height: 1))
            context.fill(centerLine, with: .color(lane.color.opacity(0.14)))

            let samples = samplesForWidth(size.width)
            guard !samples.isEmpty else { return }

            let barWidth: CGFloat = 3
            let barGap: CGFloat = 2
            let stride = barWidth + barGap
            let startX = size.width - barWidth - CGFloat(samples.count - 1) * stride
            let maximumHeight = max(2, size.height - 12)

            for (index, sample) in samples.enumerated() {
                let height = max(2, CGFloat(sample) * maximumHeight)
                let rect = CGRect(
                    x: startX + CGFloat(index) * stride,
                    y: centerY - height / 2,
                    width: barWidth,
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 1.5),
                    with: .color(lane.color.opacity(0.9))
                )
            }
        }
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

    /// The recorder retains 45 seconds for this view, then condenses it into
    /// the number of bars the window can actually show.
    private func samplesForWidth(_ width: CGFloat) -> [Float] {
        let sampleRate: CGFloat = 20
        let historyWindow = Int(sampleRate * 45)
        let recentHistory = Array(lane.history.suffix(historyWindow))
        let barCount = min(recentHistory.count, max(1, Int(width / 5)))
        guard barCount > 0 else { return [] }
        guard barCount < recentHistory.count else { return recentHistory }

        return (0..<barCount).map { barIndex in
            let start = barIndex * recentHistory.count / barCount
            let end = max(start + 1, (barIndex + 1) * recentHistory.count / barCount)
            return recentHistory[start..<end].max() ?? 0
        }
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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 20)) { timeline in
            let now = timeline.date.timeIntervalSinceReferenceDate
            LiveWaveformView(
                lanes: previewLanes(at: now),
                isPaused: false
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
