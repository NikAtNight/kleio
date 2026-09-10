import SwiftUI
import AppKit

/// System typography and grouped surfaces shared by the native screens.
enum Theme {
    static func displayTitle(size: CGFloat = 32) -> Font {
        .system(size: size, weight: .bold)
    }

    static let metaLabel: Font = .system(size: 11, weight: .medium)
    static let metaValue: Font = .system(size: 13).monospacedDigit()
    static let paperBackground = Color(nsColor: NSColor(
        name: nil,
        dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedWhite: 0.10, alpha: 1)
                : NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.97, alpha: 1)
        }
    ))
    static let cardBackground = Color(nsColor: NSColor(
        name: nil,
        dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedWhite: 0.15, alpha: 1)
                : NSColor.white
        }
    ))
}
