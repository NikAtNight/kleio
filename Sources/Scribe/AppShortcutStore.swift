import AppKit
import Combine

extension RecordingApplication {
    var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    var icon: NSImage {
        applicationURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app", accessibilityDescription: name)!
    }
}

@MainActor
final class AppShortcutStore: ObservableObject {
    @Published private(set) var shortcuts: [RecordingApplication]
    private let defaults: UserDefaults
    private static let key = "recordingAppShortcuts"

    init(defaults: UserDefaults = .standard, initialShortcuts: [RecordingApplication]? = nil) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([RecordingApplication].self, from: data) {
            shortcuts = saved
        } else {
            shortcuts = initialShortcuts ?? Self.installedDefaults()
        }
    }

    func add(_ shortcut: RecordingApplication) {
        if let index = shortcuts.firstIndex(where: { $0.id == shortcut.id }) {
            shortcuts[index] = shortcut
        } else {
            shortcuts.append(shortcut)
        }
        persist()
    }

    func remove(_ shortcut: RecordingApplication) {
        shortcuts.removeAll { $0.id == shortcut.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(shortcuts) {
            defaults.set(data, forKey: Self.key)
        }
    }

    private static func installedDefaults() -> [RecordingApplication] {
        [
            RecordingApplication(bundleID: "us.zoom.xos", name: "Zoom"),
            RecordingApplication(bundleID: "com.microsoft.teams2", name: "Teams"),
            RecordingApplication(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"),
            RecordingApplication(bundleID: "app.zen-browser.zen", name: "Zen Browser"),
            RecordingApplication(bundleID: "com.google.Chrome", name: "Chrome"),
            RecordingApplication(bundleID: "com.apple.Safari", name: "Safari")
        ].filter { $0.applicationURL != nil }
    }
}
