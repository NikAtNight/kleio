import XCTest
@testable import Scribe

@MainActor
final class LibraryBackupJobTests: XCTestCase {
    private let unusedURL = URL(fileURLWithPath: "/unused-backup-fixture")

    func testQuitWaitsForBackupCompletionAndDuplicateStartsAreIgnored() async throws {
        let gate = BackupJobGate()
        var creations = 0
        var revealed = false
        let jobs = LibraryBackupJobs(create: { _, _, _ in
            creations += 1
            await gate.wait()
            return LibraryBackup.Manifest(createdAt: Date(), entries: [])
        })
        jobs.backUp(support: unusedURL, preferences: [:], to: unusedURL) { _ in revealed = true }
        jobs.backUp(support: unusedURL, preferences: [:], to: unusedURL)
        try await waitFor { await gate.isWaiting }
        var quitStarted = false
        var quitFinished = false
        let quit = Task {
            quitStarted = true
            let result = await jobs.prepareToQuit()
            quitFinished = true
            return result
        }
        try await waitFor { quitStarted }
        XCTAssertFalse(quitFinished)
        XCTAssertTrue(jobs.isWorking)
        XCTAssertFalse(revealed)
        XCTAssertNil(jobs.message)
        await gate.release()
        let finished = await quit.value
        XCTAssertTrue(finished)
        XCTAssertFalse(jobs.isWorking)
        XCTAssertTrue(revealed)
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(jobs.message, "Backed up 0 recordings.")
    }

    func testFailedBackupDuringQuitReportsFailureWithoutSuccessMessage() async throws {
        let gate = BackupJobGate()
        let jobs = LibraryBackupJobs(create: { _, _, _ in
            await gate.wait()
            throw LibraryBackup.BackupError.message("Fixture disk is unavailable.")
        })
        jobs.backUp(support: unusedURL, preferences: [:], to: unusedURL) { _ in XCTFail("Failed backup must not be revealed") }
        try await waitFor { await gate.isWaiting }
        var quitting = false
        let quit = Task { quitting = true; return await jobs.prepareToQuit() }
        try await waitFor { quitting }
        await gate.release()
        let finished = await quit.value
        XCTAssertFalse(finished)
        XCTAssertNil(jobs.message)
        XCTAssertEqual(jobs.error, "Fixture disk is unavailable.")
        XCTAssertFalse(jobs.isWorking)
    }

    func testQuitReportsBackupFailureThatFinishedWhileOtherWorkWasDraining() async throws {
        let jobs = LibraryBackupJobs(create: { _, _, _ in
            throw LibraryBackup.BackupError.message("Fixture backup failed before quit reached it.")
        })
        jobs.backUp(support: unusedURL, preferences: [:], to: unusedURL)
        try await waitFor { !jobs.isWorking }
        let finished = await jobs.prepareToQuit()
        XCTAssertFalse(finished)
        jobs.dismissError()
        let acknowledged = await jobs.prepareToQuit()
        XCTAssertTrue(acknowledged)
    }

    func testRestoreRechecksAvailabilityAndHonorsCancelledConfirmation() async throws {
        for allowed in [false, true] {
            var prompted = false
            let jobs = LibraryBackupJobs(
                inspect: { _ in LibraryBackup.Manifest(createdAt: Date(), entries: []) },
                schedule: { _, _ in XCTFail("A blocked or cancelled restore must not be scheduled") }
            )
            jobs.restoreNextLaunch(from: unusedURL, support: unusedURL, canRestore: { allowed }) { _ in
                prompted = true
                return false
            }
            _ = await jobs.prepareToQuit()
            XCTAssertEqual(prompted, allowed)
            XCTAssertNil(jobs.message)
            XCTAssertEqual(jobs.error == nil, allowed)
        }
    }

    func testQuitWaitsForRestoreSchedulingBeforeReportingSuccess() async throws {
        let gate = BackupJobGate()
        var scheduled = false
        let jobs = LibraryBackupJobs(
            inspect: { _ in LibraryBackup.Manifest(createdAt: Date(), entries: []) },
            schedule: { _, _ in await gate.wait(); scheduled = true }
        )
        jobs.restoreNextLaunch(from: unusedURL, support: unusedURL, canRestore: { true }, confirm: { _ in true })
        try await waitFor { await gate.isWaiting }
        XCTAssertNil(jobs.message)
        XCTAssertFalse(scheduled)
        let quit = Task { await jobs.prepareToQuit() }
        await gate.release()
        let finished = await quit.value
        XCTAssertTrue(finished)
        XCTAssertTrue(scheduled)
        XCTAssertEqual(jobs.message, "Restore scheduled. Quit and reopen Kleio to finish.")
    }

    private func waitFor(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !(await condition()) {
            guard Date() < deadline else { XCTFail("Backup operation did not reach its checkpoint"); throw CancellationError() }
            await Task.yield()
        }
    }
}

private actor BackupJobGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false
    func wait() async {
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}
