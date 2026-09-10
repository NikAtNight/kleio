import XCTest
@testable import Scribe

final class AppShortcutTests: XCTestCase {
    @MainActor
    func testShortcutsPersistWithoutDuplicatesAndRememberRemoval() throws {
        let suite = "Scribe.ShortcutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let seed = RecordingApplication(bundleID: "test.browser", name: "Browser")
        let store = AppShortcutStore(defaults: defaults, initialShortcuts: [seed])
        store.add(RecordingApplication(bundleID: seed.bundleID, name: "Updated Browser"))
        XCTAssertEqual(store.shortcuts.count, 1)
        XCTAssertEqual(store.shortcuts.first?.name, "Updated Browser")
        let restored = AppShortcutStore(defaults: defaults, initialShortcuts: [])
        XCTAssertEqual(restored.shortcuts, store.shortcuts)
        restored.remove(seed)
        XCTAssertTrue(AppShortcutStore(defaults: defaults, initialShortcuts: [seed]).shortcuts.isEmpty)
    }
}
