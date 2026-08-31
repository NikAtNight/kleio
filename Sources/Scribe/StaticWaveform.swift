import SwiftUI

/// A lightweight waveform that stays useful before peak data has finished loading.
struct StaticWaveformView: View {
    let samples: [Float]
    let progress: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard !samples.isEmpty else {
                    let line = Path(CGRect(x: 0, y: size.height / 2 - 0.5, width: size.width, height: 1))
                    context.fill(line, with: .color(Color.secondary.opacity(0.2)))
                    return
                }

                let pitch: CGFloat = 3.5
                let barCount = max(1, Int(size.width / pitch))
                let center = size.height / 2
                for index in 0..<barCount {
                    let sample = resampledPeak(at: index, barCount: barCount)
                    let height = max(2, CGFloat(sample) * size.height)
                    let rect = CGRect(
                        x: CGFloat(index) * pitch,
                        y: center - height / 2,
                        width: 2,
                        height: height
                    )
                    let path = Path(roundedRect: rect, cornerRadius: 1)
                    let fraction = Double(index + 1) / Double(barCount)
                    let color: Color = fraction <= clampedProgress
                        ? .accentColor
                        : .secondary.opacity(0.35)
                    context.fill(path, with: .color(color))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onSeek(fraction(for: value.location.x, width: geometry.size.width))
                    }
            )
        }
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Int(clampedProgress * 100)) percent")
        .accessibilityAdjustableAction { direction in
            let step = 0.05
            switch direction {
            case .increment: onSeek(min(1, clampedProgress + step))
            case .decrement: onSeek(max(0, clampedProgress - step))
            @unknown default: break
            }
        }
    }

    private var clampedProgress: Double { min(1, max(0, progress)) }

    private func fraction(for location: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(1, max(0, Double(location / width)))
    }

    private func resampledPeak(at index: Int, barCount: Int) -> Float {
        let start = index * samples.count / barCount
        let end = max(start + 1, (index + 1) * samples.count / barCount)
        return samples[start..<min(end, samples.count)].max() ?? 0
    }
}

#Preview {
    StaticWaveformView(
        samples: (0..<160).map { index in Float(0.12 + abs(sin(Double(index) * 0.27)) * 0.88) },
        progress: 0.42,
        onSeek: { _ in }
    )
    .frame(width: 520, height: 44)
    .padding()
}
