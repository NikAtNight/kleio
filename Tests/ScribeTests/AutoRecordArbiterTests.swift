import Foundation
import XCTest
@testable import Scribe

final class AutoRecordArbiterTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private var configuration: AutoRecordConfiguration {
        AutoRecordConfiguration(
            enabled: true,
            leadMinutes: 2,
            lateJoinMinutes: 15,
            graceMinutes: 5,
            silenceMinutes: 3,
            confirmationSeconds: 3,
            countdownSeconds: 10
        )
    }

    private func event(
        id: String = "event-1",
        startOffset: TimeInterval = 120,
        duration: TimeInterval = 3_600
    ) -> AutoRecordEvent {
        AutoRecordEvent(
            eventID: id,
            title: "Planning call",
            start: origin.addingTimeInterval(startOffset),
            end: origin.addingTimeInterval(startOffset + duration),
            joinURL: URL(string: "https://meet.google.com/abc-defg-hij")
        )
    }

    @discardableResult
    private func advanceToCountdown(
        _ core: inout AutoRecordArbiterCore,
        event: AutoRecordEvent,
        configuration: AutoRecordConfiguration? = nil
    ) -> Date {
        let config = configuration ?? self.configuration
        _ = update(&core, at: origin, meetings: [event], configuration: config)
        _ = update(&core, at: origin, meetings: [event], configuration: config, process: true)
        _ = update(&core, at: origin.addingTimeInterval(1), meetings: [event], configuration: config, process: true, system: true)
        let confirmedAt = origin.addingTimeInterval(4)
        _ = update(&core, at: confirmedAt, meetings: [event], configuration: config, process: true, system: true)
        return confirmedAt
    }

    @discardableResult
    private func advanceToRecording(
        _ core: inout AutoRecordArbiterCore,
        event: AutoRecordEvent,
        configuration: AutoRecordConfiguration? = nil
    ) -> Date {
        let config = configuration ?? self.configuration
        let confirmedAt = advanceToCountdown(&core, event: event, configuration: config)
        let recordingAt = confirmedAt.addingTimeInterval(config.countdownSeconds)
        _ = update(&core, at: recordingAt, meetings: [event], configuration: config, process: true, system: true)
        return recordingAt
    }

    func testHappyPathArmsConfirmsCountsDownAndRecords() {
        var core = AutoRecordArbiterCore()
        let meeting = event()

        XCTAssertEqual(update(&core, at: origin, meetings: [meeting]), [])
        XCTAssertEqual(core.phase, .armed(meeting))

        XCTAssertEqual(update(&core, at: origin, meetings: [meeting], process: true), [.startMetering])
        XCTAssertEqual(core.phase, .confirming(meeting))

        XCTAssertEqual(update(&core, at: origin.addingTimeInterval(1), meetings: [meeting], process: true, system: true), [])
        XCTAssertEqual(
            update(&core, at: origin.addingTimeInterval(4), meetings: [meeting], process: true, system: true),
            [.stopMetering, .postCountdown(meeting)]
        )
        XCTAssertEqual(core.phase, .countdown(meeting, deadline: origin.addingTimeInterval(14)))

        XCTAssertEqual(
            update(&core, at: origin.addingTimeInterval(14), meetings: [meeting], process: true, system: true),
            [.startRecording(meeting)]
        )
        XCTAssertEqual(core.phase, .recording(meeting))
    }

    func testCountdownWaitsWhileDictationOrBackupBlocksThenStarts() {
        var core = AutoRecordArbiterCore()
        let meeting = event()
        let deadline = advanceToCountdown(&core, event: meeting).addingTimeInterval(configuration.countdownSeconds)

        for offset in [0.0, 60, 600] {
            XCTAssertEqual(
                update(&core, at: deadline.addingTimeInterval(offset), meetings: [meeting], process: true, system: true, blocked: true),
                []
            )
            XCTAssertEqual(core.phase, .countdown(meeting, deadline: deadline))
        }
        XCTAssertEqual(
            update(&core, at: deadline.addingTimeInterval(601), meetings: [meeting], process: true, system: true),
            [.startRecording(meeting)]
        )
        XCTAssertEqual(core.phase, .recording(meeting))
    }

    func testBlockedCountdownGivesUpAfterTheMeetingEnds() {
        var core = AutoRecordArbiterCore()
        let meeting = event(duration: 600)
        advanceToCountdown(&core, event: meeting)

        XCTAssertEqual(
            update(&core, at: meeting.end.addingTimeInterval(1), meetings: [meeting], process: true, blocked: true),
            []
        )
        XCTAssertEqual(core.phase, .idle)
        // The meeting is still inside its late-join window, but it must not count down again.
        _ = update(&core, at: meeting.end.addingTimeInterval(2), meetings: [meeting], process: true, system: true)
        XCTAssertEqual(core.phase, .idle)
    }

    func testStartNowSkipsCountdownWait() {
        var core = AutoRecordArbiterCore()
        let meeting = event()
        advanceToCountdown(&core, event: meeting)

        XCTAssertEqual(core.startNow(), [.startRecording(meeting)])
        XCTAssertEqual(core.phase, .recording(meeting))
    }

    func testCancelFromIdleArmedConfirmingAndCountdown() {
        let meeting = event()

        var idle = AutoRecordArbiterCore()
        XCTAssertEqual(idle.cancel(eventID: meeting.eventID), [])
        _ = update(&idle, at: origin, meetings: [meeting])
        XCTAssertEqual(idle.phase, .idle)

        var armed = AutoRecordArbiterCore()
        _ = update(&armed, at: origin, meetings: [meeting])
        XCTAssertEqual(armed.cancel(), [])
        XCTAssertEqual(armed.phase, .idle)

        var confirming = AutoRecordArbiterCore()
        _ = update(&confirming, at: origin, meetings: [meeting])
        _ = update(&confirming, at: origin, meetings: [meeting], process: true)
        XCTAssertEqual(confirming.cancel(), [.stopMetering])
        XCTAssertEqual(confirming.phase, .idle)

        var countdown = AutoRecordArbiterCore()
        advanceToCountdown(&countdown, event: meeting)
        XCTAssertEqual(countdown.cancel(), [])
        XCTAssertEqual(countdown.phase, .idle)
    }

    func testCancelFromRecordingAndStoppingRequestsStop() {
        let meeting = event()
        var recording = AutoRecordArbiterCore()
        advanceToRecording(&recording, event: meeting)
        XCTAssertEqual(recording.cancel(), [.stopRecording(.cancelled)])
        XCTAssertEqual(recording.phase, .stopping(meeting))

        XCTAssertEqual(recording.cancel(), [.stopRecording(.cancelled)])
        XCTAssertEqual(recording.phase, .stopping(meeting))
        _ = update(&recording, at: origin.addingTimeInterval(20), meetings: [meeting], process: true, recording: false)
        XCTAssertEqual(recording.phase, .idle)
    }

    func testLateJoinInsideWindowArmsAndOutsideWindowDoesNot() {
        let meeting = event(startOffset: 0)
        var inside = AutoRecordArbiterCore()
        _ = update(&inside, at: origin.addingTimeInterval(15 * 60), meetings: [meeting])
        XCTAssertEqual(inside.phase, .armed(meeting))

        var outside = AutoRecordArbiterCore()
        _ = update(&outside, at: origin.addingTimeInterval(15 * 60 + 1), meetings: [meeting])
        XCTAssertEqual(outside.phase, .idle)
    }

    func testOverlapNotifiesOnceAndNeverSwitchesSilently() {
        let first = event()
        let second = event(id: "event-2", startOffset: 130)
        var core = AutoRecordArbiterCore()
        let recordingAt = advanceToRecording(&core, event: first)

        XCTAssertEqual(
            update(&core, at: recordingAt.addingTimeInterval(1), meetings: [first, second], process: true, system: true, mic: true, recording: true),
            [.postOverlap(active: first, waiting: second)]
        )
        XCTAssertEqual(core.phase, .recording(first))
        XCTAssertEqual(
            update(&core, at: recordingAt.addingTimeInterval(2), meetings: [first, second], process: true, system: true, mic: true, recording: true),
            []
        )
    }

    func testStopAndSwitchStopsCurrentThenCountsDownForWaitingMeeting() {
        let first = event()
        let second = event(id: "event-2", startOffset: 180)
        var core = AutoRecordArbiterCore()
        let recordingAt = advanceToRecording(&core, event: first)

        XCTAssertEqual(core.stopAndSwitch(to: second), [.stopRecording(.switchMeeting)])
        XCTAssertEqual(core.phase, .stopping(first))
        XCTAssertEqual(
            update(&core, at: recordingAt.addingTimeInterval(1), meetings: [first, second], process: true, recording: false),
            [.postCountdown(second)]
        )
        XCTAssertEqual(core.phase, .countdown(second, deadline: recordingAt.addingTimeInterval(11)))
    }

    func testManualStopIsObserved() {
        let meeting = event()
        var core = AutoRecordArbiterCore()
        let recordingAt = advanceToRecording(&core, event: meeting)

        _ = update(&core, at: recordingAt.addingTimeInterval(1), meetings: [meeting], process: true, recording: false)
        XCTAssertEqual(core.phase, .stopping(meeting))
        XCTAssertEqual(core.lastStopReason, .manual)
        _ = update(&core, at: recordingAt.addingTimeInterval(2), meetings: [meeting], process: true, recording: false)
        XCTAssertEqual(core.phase, .idle)
    }

    func testScheduledEndPlusGraceStopsWhenQuiet() {
        let meeting = event(duration: 600)
        var core = AutoRecordArbiterCore()
        advanceToRecording(&core, event: meeting)
        let stopDate = meeting.end.addingTimeInterval(5 * 60)

        XCTAssertEqual(
            update(&core, at: stopDate, meetings: [meeting], process: true, recording: true),
            [.stopRecording(.scheduledEnd)]
        )
        XCTAssertEqual(core.lastStopReason, .scheduledEnd)
    }

    func testSustainedSilenceStopsBeforeScheduledEnd() {
        let meeting = event()
        var config = configuration
        config.silenceMinutes = 1
        var core = AutoRecordArbiterCore()
        let recordingAt = advanceToRecording(&core, event: meeting, configuration: config)
        _ = update(&core, at: recordingAt.addingTimeInterval(1), meetings: [meeting], configuration: config, process: true, recording: true)

        XCTAssertEqual(
            update(&core, at: recordingAt.addingTimeInterval(61), meetings: [meeting], configuration: config, process: true, recording: true),
            [.stopRecording(.silence)]
        )
        XCTAssertEqual(core.lastStopReason, .silence)
    }

    func testProcessQuitStopsRecording() {
        let meeting = event()
        var core = AutoRecordArbiterCore()
        let recordingAt = advanceToRecording(&core, event: meeting)

        XCTAssertEqual(
            update(&core, at: recordingAt.addingTimeInterval(1), meetings: [meeting], recording: true),
            [.stopRecording(.processQuit)]
        )
        XCTAssertEqual(core.lastStopReason, .processQuit)
    }

    func testDisabledMasterToggleShortCircuitsAndStopsActiveAutoRecording() {
        let meeting = event()
        var disabled = configuration
        disabled.enabled = false
        var idle = AutoRecordArbiterCore()
        _ = update(&idle, at: origin, meetings: [meeting], configuration: disabled)
        XCTAssertEqual(idle.phase, .idle)

        var active = AutoRecordArbiterCore()
        let recordingAt = advanceToRecording(&active, event: meeting)
        XCTAssertEqual(
            update(&active, at: recordingAt, meetings: [meeting], configuration: disabled, process: true, recording: true),
            [.stopRecording(.disabled)]
        )
        XCTAssertEqual(active.phase, .stopping(meeting))
        _ = update(&active, at: recordingAt.addingTimeInterval(1), meetings: [meeting], configuration: disabled, recording: false)
        XCTAssertEqual(active.phase, .idle)
    }

    func testProcessEvidenceAllowsNativeAppsAndBrowsersOnlyForMeetOrTeamsLinks() {
        XCTAssertTrue(AudioProcessMonitor.hasConferencingProcess(
            runningBundleIDs: ["us.zoom.xos"],
            joinURL: nil
        ))
        XCTAssertTrue(AudioProcessMonitor.hasConferencingProcess(
            runningBundleIDs: ["com.apple.Safari"],
            joinURL: URL(string: "https://meet.google.com/abc-defg-hij")
        ))
        XCTAssertFalse(AudioProcessMonitor.hasConferencingProcess(
            runningBundleIDs: ["com.apple.Safari"],
            joinURL: URL(string: "https://zoom.us/j/123")
        ))
        // Slack usually stays open all day, so it isn't evidence of a scheduled meeting.
        XCTAssertFalse(AudioProcessMonitor.hasConferencingProcess(
            runningBundleIDs: ["com.tinyspeck.slackmacgap"],
            joinURL: URL(string: "https://zoom.us/j/123")
        ))
    }

    func testOlderDocumentDecodesWithoutCalendarMetadata() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "title": "Old recording",
          "createdAt": "2026-01-02T03:04:05Z",
          "kind": "recording",
          "status": "ready",
          "duration": 1,
          "tracks": [],
          "segments": []
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(ScribeDocument.self, from: Data(json.utf8))

        XCTAssertNil(document.calendarEventID)
        XCTAssertNil(document.calendarEventTitle)
        XCTAssertFalse(document.isAutoRecording)
    }

    private func update(
        _ core: inout AutoRecordArbiterCore,
        at date: Date,
        meetings: [AutoRecordEvent],
        configuration: AutoRecordConfiguration? = nil,
        process: Bool = false,
        system: Bool = false,
        mic: Bool = false,
        recording: Bool = false,
        blocked: Bool = false
    ) -> [AutoRecordCommand] {
        core.update(
            now: date,
            meetings: meetings,
            configuration: configuration ?? self.configuration,
            processRunning: process,
            systemAudioActive: system,
            micAudioActive: mic,
            recordingActive: recording,
            startBlocked: blocked
        )
    }
}
