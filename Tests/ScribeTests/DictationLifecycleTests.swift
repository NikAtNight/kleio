import XCTest
@testable import Scribe

@MainActor
final class DictationLifecycleTests: XCTestCase {
    func testCancelledPermissionRequestCannotChangeNewerStart() async throws {
        for oldPermissionAllowed in [false, true] {
            let domain = "DictationLifecycleTests-\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            defer { defaults.removePersistentDomain(forName: domain) }
            defaults.set(true, forKey: "dictationEnabled")
            let requests = PermissionRequests()
            let controller = DictationController(defaults: defaults, requestMicrophonePermission: { await requests.request() })
            controller.toggle()
            try await waitFor { requests.continuations.count == 1 }
            controller.cancelRecording()
            controller.toggle()
            try await waitFor { requests.continuations.count == 2 }
            requests.continuations[0].resume(returning: oldPermissionAllowed)
            try await waitFor { requests.completed == 1 }
            XCTAssertEqual(controller.phase, .preparing)
            XCTAssertNil(controller.lastMessage)
            requests.continuations[1].resume(returning: false)
            try await waitFor { controller.phase == .idle }
            XCTAssertEqual(controller.lastMessage, MicRecorder.MicError.permissionDenied.localizedDescription)
        }
    }

    func testDisablingDictationCancelsPendingPermissionWithoutStartingCapture() async throws {
        let domain = "DictationLifecycleTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "dictationEnabled")
        let requests = PermissionRequests()
        let controller = DictationController(defaults: defaults, requestMicrophonePermission: { await requests.request() })
        controller.toggle()
        try await waitFor { requests.continuations.count == 1 }
        controller.setEnabled(false)
        requests.continuations[0].resume(returning: true)
        try await waitFor { requests.completed == 1 }
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertFalse(controller.enabled)
        XCTAssertFalse(defaults.bool(forKey: "dictationEnabled"))
        XCTAssertNil(controller.lastMessage)
    }

    func testBackupBlocksDictationBeforeRequestingPermission() {
        let domain = "DictationLifecycleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "dictationEnabled")
        let controller = DictationController(defaults: defaults, requestMicrophonePermission: {
            XCTFail("A blocked start must not request microphone access")
            return false
        })
        controller.startBlockReason = { "Backup is running" }
        controller.toggle()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(controller.lastMessage, "Backup is running")
    }

    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for the dictation lifecycle")
        throw CancellationError()
    }
}

@MainActor
private final class PermissionRequests {
    var continuations: [CheckedContinuation<Bool, Never>] = []
    var completed = 0
    func request() async -> Bool {
        let allowed = await withCheckedContinuation { continuations.append($0) }
        completed += 1
        return allowed
    }
}
