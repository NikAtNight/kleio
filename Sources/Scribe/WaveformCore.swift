import Foundation
import SwiftUI

// Adapted from LocalFlow's HudThemes.

struct HudColor {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat

    init(_ hexString: String) {
        var value: UInt64 = 0
        Scanner(string: String(hexString.dropFirst())).scanHexInt64(&value)
        red = CGFloat((value >> 16) & 0xFF)
        green = CGFloat((value >> 8) & 0xFF)
        blue = CGFloat(value & 0xFF)
    }

    init(red: CGFloat, green: CGFloat, blue: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    func cgColor(opacity: CGFloat = 1) -> CGColor {
        CGColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: opacity)
    }

    func color(opacity: CGFloat = 1) -> Color {
        Color(cgColor: cgColor(opacity: opacity))
    }

    static func lerp(_ first: HudColor, _ second: HudColor, by amount: CGFloat) -> HudColor {
        let progress = min(1, max(0, amount))
        return HudColor(
            red: first.red + (second.red - first.red) * progress,
            green: first.green + (second.green - first.green) * progress,
            blue: first.blue + (second.blue - first.blue) * progress
        )
    }
}

struct HudRamp {
    let stops: [(position: CGFloat, color: HudColor)]

    init(_ stops: [(CGFloat, String)]) {
        self.stops = stops.map { (position: $0.0, color: HudColor($0.1)) }
    }

    func color(at position: CGFloat) -> HudColor {
        guard let first = stops.first, let last = stops.last else {
            return HudColor(red: 0, green: 0, blue: 0)
        }

        let clampedPosition = min(1, max(0, position))
        guard clampedPosition > first.position else { return first.color }
        for index in 1..<stops.count where clampedPosition <= stops[index].position {
            let previous = stops[index - 1]
            let next = stops[index]
            let span = max(0.0001, next.position - previous.position)
            return HudColor.lerp(previous.color, next.color, by: (clampedPosition - previous.position) / span)
        }
        return last.color
    }
}

/// Adds a quadratic midpoint spline through points, beginning at the first point.
func smoothSpline(_ path: inout Path, through points: [CGPoint]) {
    guard let first = points.first else { return }
    path.move(to: first)

    guard points.count > 2 else {
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return
    }

    for index in 1..<(points.count - 1) {
        let control = points[index]
        let endPoint = index == points.count - 2
            ? points[index + 1]
            : CGPoint(
                x: (points[index].x + points[index + 1].x) / 2,
                y: (points[index].y + points[index + 1].y) / 2
            )
        path.addQuadCurve(to: endPoint, control: control)
    }
}

/// Per-frame features derived from a 12-band spectrum. Preview renderers can
/// use onset detection without inventing a separate timing model.
struct VoiceFeatures {
    private(set) var centroid: CGFloat = 0.5
    private(set) var low: CGFloat = 0
    private(set) var mid: CGFloat = 0
    private(set) var high: CGFloat = 0
    private(set) var onset = false
    private(set) var onsetStrength: CGFloat = 0

    private var previousBands = [CGFloat](repeating: 0, count: 12)
    private var fluxEnvelope: CGFloat = 0
    private var lastOnset: CGFloat = -9

    mutating func reset() {
        self = VoiceFeatures()
    }

    mutating func update(time: CGFloat, deltaTime: CGFloat, level: CGFloat, spectrum: [CGFloat]) {
        var weightedBandSum: CGFloat = 0
        var totalEnergy: CGFloat = 0
        var lowEnergy: CGFloat = 0
        var midEnergy: CGFloat = 0
        var highEnergy: CGFloat = 0
        var flux: CGFloat = 0

        for (index, energy) in spectrum.enumerated() {
            weightedBandSum += CGFloat(index) * energy
            totalEnergy += energy
            if index < 4 {
                lowEnergy += energy
            } else if index < 8 {
                midEnergy += energy
            } else {
                highEnergy += energy
            }

            if index < previousBands.count {
                flux += max(0, energy - previousBands[index])
                previousBands[index] = energy
            }
        }

        low = lowEnergy
        mid = midEnergy
        high = highEnergy
        centroid = totalEnergy > 0.001 && spectrum.count > 1
            ? weightedBandSum / totalEnergy / CGFloat(spectrum.count - 1)
            : 0.5

        fluxEnvelope *= pow(0.02, max(0, deltaTime))
        let gate = max(0.15, fluxEnvelope * 1.4)
        onset = time - lastOnset > 0.1 && level > 0.15 && flux > gate
        onsetStrength = onset ? min(1, (flux / gate - 1) / 3) : 0
        if onset {
            lastOnset = time
        }
        fluxEnvelope = max(fluxEnvelope, flux)
    }
}

/// Speech-shaped input for waveform previews. It is deterministic so preview
/// redraws show motion rather than random flicker.
enum SyntheticSpeech {
    static func level(at time: Double) -> Float {
        let period = 3.4
        let phase = time.truncatingRemainder(dividingBy: period)
        if phase > 2.5 {
            return Float(0.02 + 0.012 * (0.5 + 0.5 * sin(time * 7)))
        }

        let syllable = max(0, sin(phase * 2 * .pi * 3.6 + sin(time * 0.9) * 1.7))
        let word = (time / period).rounded(.down)
        let stress = 0.6 + 0.4 * sin(phase * 2.3 + word * 1.7)
        let jitter = 0.86 + 0.14 * (0.5 + 0.5 * sin(time * 19.3 + word * 3.1))
        return Float(min(1, (0.10 + 0.9 * pow(syllable, 1.6)) * stress * jitter))
    }

    static func spectrum(at time: Double, level: Float) -> [Float] {
        let bandCount = 12
        return (0..<bandCount).map { band in
            let tilt = pow(1 - Double(band) / Double(bandCount), 0.9) * 0.75 + 0.22
            let oscillation = 0.42 + 0.58 * abs(sin(time * (1.3 + Double(band) * 0.7) + Double(band) * 2.1))
            let formant = exp(-pow(Double(band) - (3 + 2.5 * sin(time * 0.6)), 2) / 6)
            return Float(min(1, Double(level) * (tilt * oscillation + formant * 0.9 * Double(level))))
        }
    }
}
