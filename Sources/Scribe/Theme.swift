import SwiftUI
import AppKit

/// System typography and grouped surfaces shared by the native screens.
enum Theme {
    static func displayTitle(size: CGFloat = 32) -> Font {
        .system(size: size, weight: .bold)
    }

    static let metaLabel: Font = .system(size: 12, weight: .medium)
    static let metaValue: Font = .system(size: 13).monospacedDigit()
    static let paperBackground = Color(nsColor: NSColor(
        name: nil,
        dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1)
                : NSColor(calibratedRed: 0.95, green: 0.96, blue: 0.98, alpha: 1)
        }
    ))
    static let cardBackground = Color(nsColor: NSColor(
        name: nil,
        dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.17, alpha: 1)
                : NSColor.white
        }
    ))
}
