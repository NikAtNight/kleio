import SwiftUI
import AppKit

/// Shared display styles for the Biscotti-inspired shell: serif display
/// titles, monospaced metadata labels, and a warm paper-like background.
/// Structure stays native macOS; these are accents, not a re-skin.
enum Theme {
    /// Large serif page titles ("Project Planning" style).
    static func displayTitle(size: CGFloat = 32) -> Font {
        .system(size: size, weight: .bold, design: .serif)
    }

    /// Small monospaced labels for metadata columns (WHEN, WHERE, dates).
    static let metaLabel: Font = .system(size: 11, weight: .medium, design: .monospaced)

    /// Monospaced body values that pair with `metaLabel` (times, durations).
    static let metaValue: Font = .system(size: 13, design: .monospaced)

    /// Warm content-pane background: soft cream in light mode, warm near-black
    /// in dark mode. Sidebar and toolbar keep their native materials.
    static let paperBackground = Color(nsColor: NSColor(
        name: nil,
        dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(calibratedRed: 0.115, green: 0.112, blue: 0.105, alpha: 1)
                : NSColor(calibratedRed: 0.980, green: 0.973, blue: 0.955, alpha: 1)
        }
    ))

    /// Card surface that sits on `paperBackground`.
    static let cardBackground = Color(nsColor: NSColor(
        name: nil,
        dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(calibratedWhite: 0.16, alpha: 1)
                : NSColor.white
        }
    ))
}
