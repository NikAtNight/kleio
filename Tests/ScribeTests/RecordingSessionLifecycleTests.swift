import Foundation
import XCTest
@testable import Scribe

@MainActor
final class RecordingSessionLifecycleTests: XCTestCase {
    func testMuteSyncRequiresAppTargetBeforeOpeningDevicesOrCreatingMedia() async throws {
        let fixture = try Fixture()
        let driver = SyntheticCaptureDriver()
        let session = fixture.session(driver: driver)
        await session.start(mode: .meeting, library: fixture.library, meetingMuteSyncEnabled: true)
        XCTAssertFalse(session.isRecording)
        XCTAssertTrue(session.lastError?.contains("app shortcut") == true)
        XCTAssertEqual(driver.permissionRequests, 0)
        XCTAssertTrue(driver.events.isEmpty)
        XCTAssertTrue(fixture.library.documents.isEmpty)
    }

    func testUnavailableAppTargetDoesNotStartCaptureOrCreateMedia() async throws {
        let fixture = try Fixture()
        let driver = SyntheticCaptureDriver()
        let session = RecordingSession(dependencies: RecordingSessionDependencies(
            makeCapture: { driver }, availableDiskCapacity: { _ in nil },
            audioDuration: { _ in 0 }, enqueue: { _, _ in },
            resolveApplication: { _ in throw TestFailure("Meeting app has no audio source.") }
        ))
        await session.start(mode: .meeting, library: fixture.library,
                            application: .init(bundleID: "test.missing", name: "Missing app"),
                            meetingMuteSyncEnabled: true)
        XCTAssertFalse(session.isRecording)
        XCTAssertEqual(session.lastError, "Meeting app has no audio source.")
        XCTAssertFalse(driver.events.contains("start"))
        XCTAssertTrue(fixture.library.documents.isEmpty)
    }

    func testMuteSyncWiresOnlyMeetingTargetAndResetsStatusAfterStop() async throws {
        let fixture = try Fixture()
        let driver = SyntheticCaptureDriver()
        let session = fixture.session(driver: driver)
        let app = RecordingApplication(bundleID: "test.meeting", name: "Test meeting")
        await session.start(mode: .meeting, library: fixture.library, application: app, meetingMuteSyncEnabled: true)
        XCTAssertTrue(session.isRecording)
        XCTAssertEqual(driver.muteSyncApplication, app)
        guard case .unavailable = session.meetingMuteState else { return XCTFail("Startup must wait for a mute reading.") }
        driver.reportMuteState(.unavailable("Call controls are hidden."))
        await Task.yield()
        XCTAssertEqual(session.meetingMuteState, .unavailable("Call controls are hidden."))
        XCTAssertTrue(session.isRecording)
        XCTAssertTrue(driver.hasSystemAudio)
        XCTAssertNil(session.lastError)
        let latestMuteTime = RecordingClock.now
        driver.reportMuteState(.muted, at: latestMuteTime)
        // The callback crosses to the main actor, like the native reader.
        await Task.yield()
        XCTAssertEqual(session.meetingMuteState, .muted)
        driver.reportMuteState(.unmuted, at: latestMuteTime - 0.1)
        await Task.yield()
        XCTAssertEqual(session.meetingMuteState, .muted, "An older UI callback must not replace the newer muted reading.")
        session.togglePause()
        session.togglePause()
        XCTAssertTrue(driver.events.contains("pause"))
        XCTAssertTrue(driver.events.contains("resume"))
        session.stop(library: fixture.library, queue: fixture.queue)
        await session.waitForFinalization()
        XCTAssertNil(session.meetingMuteState)
        driver.reportMuteState(.unmuted)
        await Task.yield()
        XCTAssertNil(session.meetingMuteState)
    }

    func testVoiceMemosStayIndependentAndMeetingSyncDefaultsOff() async throws {
        for mode in [RecordingMode.microphoneOnly, .systemOnly, .meeting] {
            let fixture = try Fixture()
            let driver = SyntheticCaptureDriver()
            let session = fixture.session(driver: driver)
            if mode != .meeting {
                await session.start(mode: mode, library: fixture.library, meetingMuteSyncEnabled: true)
            } else {
                await session.start(mode: mode, library: fixture.library)
            }
            XCTAssertTrue(session.isRecording)
            XCTAssertNil(driver.muteSyncApplication)
            XCTAssertNil(session.meetingMuteState)
            session.stop(library: fixture.library, queue: fixture.queue)
            await session.waitForFinalization()
        }
    }

    func testSuccessfulLifecyclePersistsThenStopsAudioBeforeQueuing() async throws {
        let fixture = try Fixture()
        let driver = SyntheticCaptureDriver()
        driver.audioDuration = 4
        let session = fixture.session(driver: driver)

        await session.start(mode: .meeting, library: fixture.library)

        XCTAssertTrue(session.isRecording)
        let id = try XCTUnwrap(session.activeDocumentID)
        XCTAssertEqual(fixture.library.document(id: id)?.status, .recording)
        XCTAssertEqual(fixture.library.document(id: id)?.tracks.map(\.source), [.system, .microphone])

        session.stop(library: fixture.library, queue: fixture.queue)
        await session.waitForFinalization()

        XCTAssertEqual(driver.events, ["start", "stop-audio", "stop-video", "close"])
        XCTAssertEqual(fixture.enqueued, [id])
        XCTAssertEqual(fixture.library.document(id: id)?.status, .queued)
        XCTAssertEqual(fixture.library.document(id: id)?.duration, 4)
        XCTAssertFalse(session.isBusy)
    }

    func testFinalizationWaitsForAsynchronousVideoStop() async throws {
        let fixture = try Fixture()
        let driver = SyntheticCaptureDriver()
        driver.delayVideoStop = true
        driver.videoResult = RecordingVideoStopResult(duration: 8, startOffset: 1.25)
        let session = fixture.session(driver: driver)

        await session.start(mode: .meeting, library: fixture.library, videoMode: .window)
        let id = try XCTUnwrap(session.activeDocumentID)
        session.stop(library: fixture.library, queue: fixture.queue)
        await driver.waitUntilVideoStopStarts()

        XCTAssertTrue(session.isFinalizing)
        XCTAssertTrue(session.isRecording)
        XCTAssertEqual(fixture.library.document(id: id)?.status, .recording)
        XCTAssertTrue(driver.events.starts(with: ["prepare-video", "start", "stop-audio", "stop-video"]))

        driver.completeVideoStop()
        await session.waitForFinalization()

        let document = try XCTUnwrap(fixture.library.document(id: id))
        XCTAssertEqual(document.videoTracks?.first?.duration, 8)
        XCTAssertEqual(document.videoTracks?.first?.startOffset, 1.25)
        XCTAssertEqual(document.status, .queued)
    }

    func testPartialStartFailureStopsOpenedSourcesAndKeepsCrashMarkerMedia() async throws {
        let fixture = try Fixture()
        let driver = SyntheticCaptureDriver()
        driver.startError = TestFailure("Microphone failed after app audio started.")
        let session = fixture.session(driver: driver)

        await session.start(mode: .meeting, library: fixture.library)

        XCTAssertFalse(session.isRecording)
        XCTAssertEqual(driver.events, ["start", "stop-audio", "stop-video", "close"])
        let document = try XCTUnwrap(fixture.library.documents.first)
        XCTAssertEqual(document.status, .recovered)
        XCTAssertTrue(document.failureReason?.contains("Microphone failed") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.library.folder(for: document.id)
            .appendingPathComponent("system.caf").path))
        XCTAssertFalse(fixture.library.hasPendingRecordingSave(document.id))
    }

    func testCallbackFailureFinalizesAsRecoveredWithoutEnqueueing() async throws {
        let fixture = try Fixture()
        let driver = SyntheticCaptureDriver()
        let session = fixture.session(driver: driver)
        await session.start(mode: .meeting, library: fixture.library)
        let id = try XCTUnwrap(session.activeDocumentID)

        driver.delayVideoStop = true
        driver.reportCaptureError("The app audio writer stopped.")
        await driver.waitUntilVideoStopStarts()
        XCTAssertTrue(session.isFinalizing)
        XCTAssertTrue(fixture.enqueued.isEmpty)
        driver.completeVideoStop()
        await session.waitForFinalization()

        XCTAssertEqual(fixture.library.document(id: id)?.status, .recovered)
        XCTAssertTrue(fixture.library.document(id: id)?.failureReason?.contains("writer stopped") == true)
        XCTAssertTrue(fixture.enqueued.isEmpty)
    }

    func testQuitCancelsStartupAfterManifestAndPreservesPartialCapture() async throws {
        let fixture = try Fixture()
        let driver = SyntheticCaptureDriver()
        driver.delayStart = true
        let session = fixture.session(driver: driver)
        let start = Task { await session.start(mode: .meeting, library: fixture.library, videoMode: .window) }
        await driver.waitUntilStartBegins()

        await session.prepareToQuit(library: fixture.library, queue: fixture.queue)
        await start.value

        XCTAssertTrue(driver.cancelStartCalled)
        XCTAssertFalse(session.isStarting)
        XCTAssertFalse(session.isRecording)
        let document = try XCTUnwrap(fixture.library.documents.first)
        XCTAssertEqual(document.status, .recovered)
        XCTAssertTrue(document.failureReason?.contains("cancelled") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.library.folder(for: document.id)
            .appendingPathComponent("system.caf").path))
    }

    func testFailedFinalSaveOwnsRetryIntentAndPreservesEdits() async throws {
        let fixture = try Fixture()
        let driver = SyntheticCaptureDriver()
        let session = fixture.session(driver: driver)
        await session.start(mode: .meeting, library: fixture.library)
        let id = try XCTUnwrap(session.activeDocumentID)
        let paths = try fixture.blockManifest(for: id)

        session.stop(library: fixture.library, queue: fixture.queue)
        await session.waitForFinalization()

        XCTAssertTrue(session.hasPendingSave)
        XCTAssertTrue(session.isBusy)
        XCTAssertTrue(fixture.library.hasPendingRecordingSave(id))
        XCTAssertEqual(fixture.library.pendingRecordingSaveIDs, [id])
        XCTAssertTrue(fixture.enqueued.isEmpty)
        let visible = try XCTUnwrap(fixture.library.document(id: id))
        XCTAssertFalse(fixture.library.delete(visible))

        await session.prepareToQuit(library: fixture.library, queue: fixture.queue)
        XCTAssertTrue(session.hasPendingSave)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.original.path))

        try FileManager.default.removeItem(at: paths.blocker)
        var edited = try XCTUnwrap(fixture.library.document(id: id))
        edited.title = "Renamed while waiting"
        edited.notes = [MeetingNote(time: 2, text: "Keep this note")]
        XCTAssertTrue(fixture.library.update(edited))
        session.retryFinalSave(library: fixture.library, queue: fixture.queue)

        XCTAssertFalse(session.hasPendingSave)
        XCTAssertEqual(fixture.enqueued, [id])
        let saved = try XCTUnwrap(fixture.library.document(id: id))
        XCTAssertEqual(saved.status, .queued)
        XCTAssertEqual(saved.title, "Renamed while waiting")
        XCTAssertEqual(saved.notes?.first?.text, "Keep this note")
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.original.path))
    }

    func testPendingRecordingCannotChangeLibraryOwnership() async throws {
        let original = try Fixture()
        let other = try Fixture()
        let driver = SyntheticCaptureDriver()
        let session = original.session(driver: driver)
        await session.start(mode: .meeting, library: original.library)
        let id = try XCTUnwrap(session.activeDocumentID)
        let paths = try original.blockManifest(for: id)
        session.stop(library: original.library, queue: original.queue)
        await session.waitForFinalization()

        await session.start(mode: .meeting, library: other.library)
        session.retryFinalSave(library: other.library, queue: other.queue)
        await session.prepareToQuit(library: other.library, queue: other.queue)

        XCTAssertEqual(session.pendingSaveDocumentID, id)
        XCTAssertTrue(session.isBusy)
        XCTAssertTrue(other.library.documents.isEmpty)
        XCTAssertEqual(driver.events.filter { $0 == "start" }.count, 1)
        try FileManager.default.removeItem(at: paths.blocker)
        session.retryFinalSave(library: original.library, queue: original.queue)
        XCTAssertFalse(session.hasPendingSave)
        XCTAssertEqual(original.enqueued, [id])
        XCTAssertTrue(other.enqueued.isEmpty)
    }

    func testQuitWaitsForStartupBeforeStoppingVideo() async throws {
        let fixture = try Fixture()
        let driver = SyntheticCaptureDriver()
        driver.delayStart = true
        driver.cancellationCompletesStart = false
        let session = fixture.session(driver: driver)
        let start = Task { await session.start(mode: .meeting, library: fixture.library, videoMode: .window) }
        await driver.waitUntilStartBegins()
        let quit = Task { await session.prepareToQuit(library: fixture.library, queue: fixture.queue) }
        await driver.waitUntilStartCancelled()

        XCTAssertTrue(session.isStarting)
        XCTAssertFalse(driver.events.contains("stop-video"))
        driver.completeStart()
        await start.value
        await quit.value

        XCTAssertFalse(session.isBusy)
        XCTAssertEqual(driver.events.filter { $0 == "stop-video" }.count, 1)
        XCTAssertEqual(fixture.library.documents.first?.status, .recovered)
        XCTAssertTrue(fixture.enqueued.isEmpty)
    }

    func testDiscardWaitsForFinalSaveBeforeDeletingMedia() async throws {
        let fixture = try Fixture()
        let driver = SyntheticCaptureDriver()
        let session = fixture.session(driver: driver)
        await session.start(mode: .microphoneOnly, library: fixture.library)
        let id = try XCTUnwrap(session.activeDocumentID)
        let media = fixture.library.folder(for: id).appendingPathComponent("microphone.caf")
        let paths = try fixture.blockManifest(for: id)

        session.discard(library: fixture.library)
        await session.waitForFinalization()

        XCTAssertTrue(fixture.library.hasPendingRecordingSave(id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.path))
        XCTAssertFalse(fixture.library.delete(try XCTUnwrap(fixture.library.document(id: id))))

        try FileManager.default.removeItem(at: paths.blocker)
        session.retryFinalSave(library: fixture.library, queue: fixture.queue)

        XCTAssertNil(fixture.library.document(id: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.library.folder(for: id).path))
        XCTAssertFalse(session.hasPendingSave)
    }

    func testLowDiskRejectsStartBeforePermissionManifestOrCapture() async throws {
        let fixture = try Fixture()
        let driver = SyntheticCaptureDriver()
        var factoryCalls = 0
        let session = RecordingSession(dependencies: RecordingSessionDependencies(
            makeCapture: { factoryCalls += 1; return driver },
            availableDiskCapacity: { _ in RecordingSession.minimumFreeDiskBytes - 1 },
            audioDuration: { _ in 0 },
            enqueue: { _, _ in XCTFail("A rejected recording must not be queued") }
        ))

        await session.start(mode: .meeting, library: fixture.library, videoMode: .window)

        XCTAssertEqual(factoryCalls, 0)
        XCTAssertEqual(driver.permissionRequests, 0)
        XCTAssertTrue(driver.events.isEmpty)
        XCTAssertTrue(fixture.library.documents.isEmpty)
        XCTAssertTrue(session.lastError?.contains("1 GB") == true)
        XCTAssertFalse(session.isBusy)
    }

}

@MainActor
private final class Fixture {
    let root: URL
    let library: LibraryStore
    let queue = TranscriptionQueue()
    var enqueued: [UUID] = []

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingSessionLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        library = LibraryStore(baseURL: root)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func session(driver: SyntheticCaptureDriver) -> RecordingSession {
        return RecordingSession(dependencies: RecordingSessionDependencies(
            makeCapture: { driver },
            availableDiskCapacity: { _ in RecordingSession.minimumFreeDiskBytes },
            audioDuration: { [weak driver] _ in driver?.audioDuration ?? 0 },
            enqueue: { [weak self] _, id in self?.enqueued.append(id) },
            resolveApplication: { _ in [123] }
        ))
    }

    func blockManifest(for id: UUID) throws -> (blocker: URL, original: URL) {
        let manifest = library.folder(for: id).appendingPathComponent("document.json")
        let original = library.folder(for: id).appendingPathComponent("original.json")
        try FileManager.default.moveItem(at: manifest, to: original)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        return (manifest, original)
    }
}

@MainActor
private final class SyntheticCaptureDriver: RecordingCaptureDriving {
    var hasMicrophone = false
    var hasSystemAudio = false
    var permissionGranted = true
    var permissionRequests = 0
    var startError: Error?
    var delayStart = false
    var cancellationCompletesStart = true
    var delayVideoStop = false
    var audioDuration: TimeInterval = 0
    var videoResult: RecordingVideoStopResult?
    var events: [String] = []
    var cancelStartCalled = false
    var muteSyncApplication: RecordingApplication?
    private var muteStateHandler: (@Sendable (MeetingMuteObservation) -> Void)?

    private var errorHandler: (@Sendable (String) -> Void)?
    private var startContinuation: CheckedContinuation<Void, Error>?
    private var videoStopContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []
    private var videoStopWaiters: [CheckedContinuation<Void, Never>] = []

    func requestMicrophonePermission() async -> Bool {
        permissionRequests += 1
        return permissionGranted
    }

    func prepareVideo(_ mode: VideoCaptureMode) async throws {
        events.append("prepare-video")
    }

    func start(
        mode: RecordingMode,
        folder: URL,
        processes: [UInt32]?,
        clock: RecordingClock,
        muteSyncApplication: RecordingApplication?,
        onMuteState: @escaping @Sendable (MeetingMuteObservation) -> Void,
        onError: @escaping @Sendable (String) -> Void,
        onWarning: @escaping @Sendable (String) -> Void,
        onMicLevel: @escaping @Sendable (Float) -> Void,
        onSystemLevel: @escaping @Sendable (Float) -> Void,
        onFirstVideoFrame: @escaping @Sendable (TimeInterval) -> Void
    ) async throws {
        events.append("start")
        self.muteSyncApplication = muteSyncApplication
        muteStateHandler = onMuteState
        errorHandler = onError
        hasMicrophone = mode.usesMic
        hasSystemAudio = mode.usesSystem
        if mode.usesSystem { try Data("system audio".utf8).write(to: folder.appendingPathComponent("system.caf")) }
        if mode.usesMic { try Data("microphone audio".utf8).write(to: folder.appendingPathComponent("microphone.caf")) }
        for waiter in startWaiters { waiter.resume() }
        startWaiters = []
        if delayStart {
            try await withCheckedThrowingContinuation { startContinuation = $0 }
        }
        if let startError { throw startError }
    }

    func updateProcesses(_ processes: [UInt32]) throws { }

    func setPaused(_ paused: Bool) { events.append(paused ? "pause" : "resume") }

    func stopAudio() {
        events.append("stop-audio")
        hasMicrophone = false
        hasSystemAudio = false
    }

    func stopVideo() async throws -> RecordingVideoStopResult? {
        events.append("stop-video")
        for waiter in videoStopWaiters { waiter.resume() }
        videoStopWaiters = []
        if delayVideoStop { await withCheckedContinuation { videoStopContinuation = $0 } }
        return videoResult
    }

    func cancelStart() async {
        cancelStartCalled = true
        for waiter in cancelWaiters { waiter.resume() }
        cancelWaiters = []
        if cancellationCompletesStart {
            startContinuation?.resume(throwing: CancellationError())
            startContinuation = nil
        }
    }

    func close() {
        events.append("close")
    }

    func reportMuteState(_ state: MeetingMuteState, at time: TimeInterval = RecordingClock.now) {
        muteStateHandler?(.init(state: state, contextID: "test", sourceName: "Test meeting", observedAt: time))
    }

    func reportCaptureError(_ message: String) {
        errorHandler?(message)
    }

    func waitUntilStartBegins() async {
        if events.contains("start") { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilVideoStopStarts() async {
        if events.contains("stop-video") { return }
        await withCheckedContinuation { videoStopWaiters.append($0) }
    }

    func waitUntilStartCancelled() async {
        if cancelStartCalled { return }
        await withCheckedContinuation { cancelWaiters.append($0) }
    }

    func completeStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func completeVideoStop() {
        videoStopContinuation?.resume()
        videoStopContinuation = nil
    }
}

private struct TestFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
