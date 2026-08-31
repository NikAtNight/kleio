import Foundation
import XCTest
@testable import Scribe

final class ManualAutoStopTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    func testStopsWhenTheTrackedConferencingProcessQuits() {
        var core = ManualAutoStopCore()
        _ = update(&core, at: origin, elapsed: 0, processes: ["us.zoom.xos"])

        XCTAssertEqual(
            update(&core, at: origin.addingTimeInterval(120), elapsed: 120),
            [.stopRecording]
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
            update(&micOnly, at: origin.addingTimeInterval(120), isManualMeeting: false, elapsed: 120),
            []
        )
    }

    private func update(
        _ core: inout ManualAutoStopCore,
        at now: Date,
        enabled: Bool = true,
        isManualMeeting: Bool = true,
        paused: Bool = false,
        elapsed: TimeInterval,
        processes: Set<String> = [],
        systemAudioActive: Bool = false,
        micAudioActive: Bool = false
    ) -> [ManualAutoStopCommand] {
        core.update(
            now: now,
            enabled: enabled,
            isManualMeetingRecording: isManualMeeting,
            isPaused: paused,
            elapsed: elapsed,
            conferencingProcessBundleIDs: processes,
            systemAudioActive: systemAudioActive,
            micAudioActive: micAudioActive,
            silenceMinutes: 3
        )
    }
}
