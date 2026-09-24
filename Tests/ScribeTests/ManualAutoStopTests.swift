import Foundation
import XCTest
@testable import Scribe

final class ManualAutoStopTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)
    private let zoom = RecordingApplication(bundleID: "us.zoom.xos", name: "Zoom")

    func testStopsWhenTheRecordedAppQuits() {
        var core = ManualAutoStopCore()
        let recording = ActiveRecording(mode: .meeting, origin: .manual, application: zoom)
        _ = update(&core, at: origin, recording: recording, elapsed: 0, processes: ["us.zoom.xos", "Cisco-Systems.Spark"])

        XCTAssertEqual(
            update(&core, at: origin.addingTimeInterval(120), recording: recording, elapsed: 120,
                   processes: ["Cisco-Systems.Spark"]),
            [.stopRecording]
        )
    }

    func testStopsWhenARecordedSlackHuddleAppQuits() {
        var core = ManualAutoStopCore()
        let slack = RecordingApplication(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
        let recording = ActiveRecording(mode: .meeting, origin: .manual, application: slack)
        _ = update(&core, at: origin, recording: recording, elapsed: 0, processes: [slack.bundleID])
        XCTAssertEqual(update(&core, at: origin.addingTimeInterval(120), recording: recording, elapsed: 120),
                       [.stopRecording])
    }

    func testUnrelatedConferencingAppQuittingDoesNotStopTheRecording() {
        var core = ManualAutoStopCore()
        let recording = ActiveRecording(mode: .meeting, origin: .manual, application: zoom)
        // Webex sorts before Zoom, which is what the old tracker latched onto.
        _ = update(&core, at: origin, recording: recording, elapsed: 0, processes: ["Cisco-Systems.Spark", "us.zoom.xos"])

        XCTAssertEqual(
            update(&core, at: origin.addingTimeInterval(120), recording: recording, elapsed: 120,
                   processes: ["us.zoom.xos"], systemAudioActive: true),
            []
        )
    }

    func testBrowserAndUntargetedRecordingsUseOnlyTheSilenceRule() {
        let chrome = RecordingApplication(bundleID: "com.google.Chrome", name: "Chrome")
        for application in [chrome, nil] {
            var core = ManualAutoStopCore()
            let recording = ActiveRecording(mode: .meeting, origin: .manual, application: application)
            _ = update(&core, at: origin, recording: recording, elapsed: 0, processes: ["us.zoom.xos"])

            // Zoom quits, but it is not the recorded app. Only three minutes of silence stops the recording.
            XCTAssertEqual(update(&core, at: origin.addingTimeInterval(120), recording: recording, elapsed: 120), [])
            XCTAssertEqual(update(&core, at: origin.addingTimeInterval(179), recording: recording, elapsed: 179), [])
            XCTAssertEqual(
                update(&core, at: origin.addingTimeInterval(180), recording: recording, elapsed: 180),
                [.stopRecording]
            )
        }
    }

    func testAutoRecordedMeetingsAreLeftToTheArbiter() {
        var core = ManualAutoStopCore()
        XCTAssertEqual(
            update(&core, at: origin.addingTimeInterval(600),
                   recording: ActiveRecording(mode: .meeting, origin: .autoRecord, application: nil), elapsed: 600),
            []
        )
    }

    func testStopsAfterTheSilenceWindow() {
        var core = ManualAutoStopCore()
        _ = update(&core, at: origin.addingTimeInterval(120), elapsed: 120)

        XCTAssertEqual(update(&core, at: origin.addingTimeInterval(299), elapsed: 299), [])
        XCTAssertEqual(
            update(&core, at: origin.addingTimeInterval(300), elapsed: 300),
            [.stopRecording]
        )
    }

    func testDoesNotStopDuringTheFirstTwoMinutes() {
        var core = ManualAutoStopCore()
        _ = update(&core, at: origin, elapsed: 0, processes: ["us.zoom.xos"])

        XCTAssertEqual(update(&core, at: origin.addingTimeInterval(119), elapsed: 119), [])
    }

    func testPauseSuspendsTheSilenceClock() {
        var core = ManualAutoStopCore()
        _ = update(&core, at: origin.addingTimeInterval(120), elapsed: 120)
        _ = update(&core, at: origin.addingTimeInterval(240), paused: true, elapsed: 240)
        _ = update(&core, at: origin.addingTimeInterval(600), paused: true, elapsed: 240)
        _ = update(&core, at: origin.addingTimeInterval(600), elapsed: 240)

        XCTAssertEqual(update(&core, at: origin.addingTimeInterval(659), elapsed: 299), [])
        XCTAssertEqual(
            update(&core, at: origin.addingTimeInterval(660), elapsed: 300),
            [.stopRecording]
        )
    }

    func testDisabledSettingAndNonMeetingModesAreInert() {
        var disabled = ManualAutoStopCore()
        XCTAssertEqual(
            update(&disabled, at: origin.addingTimeInterval(120), enabled: false, elapsed: 120),
            []
        )

        var micOnly = ManualAutoStopCore()
        XCTAssertEqual(
            update(&micOnly, at: origin.addingTimeInterval(120),
                   recording: ActiveRecording(mode: .microphoneOnly, origin: .manual, application: nil), elapsed: 120),
            []
        )
    }

    func testStopsShortlyAfterTheDetectedCallEnds() {
        var core = ManualAutoStopCore()
        let teams = RecordingApplication(bundleID: "com.microsoft.teams2", name: "Microsoft Teams")
        let recording = ActiveRecording(mode: .meeting, origin: .manual, application: teams)
        let joined = CallPresence.active(contextID: "meeting", name: "Teams Meeting")
        _ = update(&core, at: origin, recording: recording, elapsed: 0, processes: [teams.bundleID],
                   systemAudioActive: true, call: joined)

        // Teams keeps running after the call, and a short call is still under two minutes.
        XCTAssertEqual(update(&core, at: origin.addingTimeInterval(60), recording: recording, elapsed: 60,
                              processes: [teams.bundleID], call: .inactive), [])
        XCTAssertEqual(update(&core, at: origin.addingTimeInterval(74), recording: recording, elapsed: 74,
                              processes: [teams.bundleID], call: .inactive), [])
        XCTAssertEqual(update(&core, at: origin.addingTimeInterval(75), recording: recording, elapsed: 75,
                              processes: [teams.bundleID], call: .inactive), [.stopRecording])
        XCTAssertEqual(update(&core, at: origin.addingTimeInterval(80), recording: recording, elapsed: 80,
                              processes: [teams.bundleID], call: .inactive), [])
    }

    func testCallEndNeedsAJoinedCallAndSteadyReads() {
        let slack = RecordingApplication(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
        let recording = ActiveRecording(mode: .meeting, origin: .manual, application: slack)
        let joined = CallPresence.active(contextID: "huddle", name: "Slack Huddle")

        // Recording before joining: the missing leave button is not an ended call.
        var beforeJoin = ManualAutoStopCore()
        for second in stride(from: 0, through: 60, by: 2) {
            XCTAssertEqual(update(&beforeJoin, at: origin.addingTimeInterval(TimeInterval(second)), recording: recording,
                                  elapsed: TimeInterval(second), processes: [slack.bundleID],
                                  systemAudioActive: true, call: .inactive), [])
        }

        // An unreadable window restarts the wait, and so does a paused recording.
        var core = ManualAutoStopCore()
        _ = update(&core, at: origin, recording: recording, elapsed: 0, processes: [slack.bundleID], call: joined)
        _ = update(&core, at: origin.addingTimeInterval(2), recording: recording, elapsed: 2,
                   processes: [slack.bundleID], systemAudioActive: true, call: .inactive)
        _ = update(&core, at: origin.addingTimeInterval(10), recording: recording, elapsed: 10,
                   processes: [slack.bundleID], systemAudioActive: true, call: .unknown)
        XCTAssertEqual(update(&core, at: origin.addingTimeInterval(20), recording: recording, elapsed: 20,
                              processes: [slack.bundleID], systemAudioActive: true, call: .inactive), [])
        _ = update(&core, at: origin.addingTimeInterval(30), recording: recording, paused: true, elapsed: 30,
                   processes: [slack.bundleID], call: .inactive)
        XCTAssertEqual(update(&core, at: origin.addingTimeInterval(40), recording: recording, elapsed: 30,
                              processes: [slack.bundleID], systemAudioActive: true, call: .inactive), [])
        XCTAssertEqual(update(&core, at: origin.addingTimeInterval(55), recording: recording, elapsed: 45,
                              processes: [slack.bundleID], systemAudioActive: true, call: .inactive), [.stopRecording])
    }

    private func update(
        _ core: inout ManualAutoStopCore,
        at now: Date,
        enabled: Bool = true,
        recording: ActiveRecording? = ActiveRecording(mode: .meeting, origin: .manual, application: nil),
        paused: Bool = false,
        elapsed: TimeInterval,
        processes: Set<String> = [],
        systemAudioActive: Bool = false,
        micAudioActive: Bool = false,
        call: CallPresence? = nil
    ) -> [ManualAutoStopCommand] {
        core.update(
            now: now,
            enabled: enabled,
            recording: recording,
            isPaused: paused,
            elapsed: elapsed,
            conferencingProcessBundleIDs: processes,
            systemAudioActive: systemAudioActive,
            micAudioActive: micAudioActive,
            silenceMinutes: 3,
            callPresence: call
        )
    }
}
