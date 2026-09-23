import XCTest
@testable import Scribe

final class CallPromptTests: XCTestCase {
    private let app = RecordingApplication(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")

    private func sample(_ presence: CallPresence = .active(contextID: "call-1", name: "Slack Huddle")) -> CallDetectionSample {
        CallDetectionSample(application: app, presence: presence)
    }

    func testRequiresConsecutiveConfirmationsAndNeverPromptsForAnOpenAppAlone() {
        var core = CallPromptCore()
        XCTAssertNil(core.update([sample(.inactive)], at: 0, recordingBusy: false, presentationBlocked: false))
        XCTAssertNil(core.update([sample()], at: 2, recordingBusy: false, presentationBlocked: false))
        let call = core.update([sample()], at: 4, recordingBusy: false, presentationBlocked: false)
        XCTAssertEqual(call, DetectedCall(application: app, contextID: "call-1", name: "Slack Huddle"))
    }

    func testUnknownAndLongSamplingGapsRequireFreshConfirmation() {
        var core = CallPromptCore()
        _ = core.update([sample()], at: 0, recordingBusy: false, presentationBlocked: false)
        XCTAssertNil(core.update([sample(.unknown)], at: 2, recordingBusy: false, presentationBlocked: false))
        XCTAssertNil(core.update([sample()], at: 4, recordingBusy: false, presentationBlocked: false))
        XCTAssertNil(core.update([sample()], at: 100, recordingBusy: false, presentationBlocked: false))
        XCTAssertNotNil(core.update([sample()], at: 102, recordingBusy: false, presentationBlocked: false))
    }

    func testDismissalSurvivesUnknownAndBriefAbsenceButResetsAfterCallEnds() throws {
        var core = CallPromptCore()
        _ = core.update([sample()], at: 0, recordingBusy: false, presentationBlocked: false)
        let call = try XCTUnwrap(core.update([sample()], at: 2, recordingBusy: false, presentationBlocked: false))
        core.dismiss(call)
        for (time, presence): (Double, CallPresence) in [(4, .unknown), (6, .inactive), (8, .active(contextID: "call-1", name: "Slack Huddle")), (10, .active(contextID: "call-1", name: "Slack Huddle"))] {
            XCTAssertNil(core.update([sample(presence)], at: time, recordingBusy: false, presentationBlocked: false))
        }
        _ = core.update([sample(.inactive)], at: 12, recordingBusy: false, presentationBlocked: false)
        _ = core.update([sample(.inactive)], at: 22, recordingBusy: false, presentationBlocked: false)
        XCTAssertNil(core.update([sample()], at: 24, recordingBusy: false, presentationBlocked: false))
        XCTAssertNotNil(core.update([sample()], at: 26, recordingBusy: false, presentationBlocked: false))
    }

    func testProcessExitAndDifferentCallAllowANewPrompt() throws {
        for processExits in [false, true] {
            var core = CallPromptCore()
            _ = core.update([sample()], at: 0, recordingBusy: false, presentationBlocked: false)
            core.dismiss(try XCTUnwrap(core.update([sample()], at: 2, recordingBusy: false, presentationBlocked: false)))
            if processExits { _ = core.update([], at: 4, recordingBusy: false, presentationBlocked: false) }
            let next = sample(.active(contextID: processExits ? "call-1" : "call-2", name: "Slack Huddle"))
            XCTAssertNil(core.update([next], at: 6, recordingBusy: false, presentationBlocked: false))
            XCTAssertNotNil(core.update([next], at: 8, recordingBusy: false, presentationBlocked: false))
        }
    }

    func testExistingRecordingConsumesCallButTemporaryUIConflictOnlyDefersPrompt() {
        for busy in [false, true] {
            var core = CallPromptCore()
            XCTAssertNil(core.update([sample()], at: 0, recordingBusy: busy, presentationBlocked: !busy))
            XCTAssertNil(core.update([sample()], at: 2, recordingBusy: busy, presentationBlocked: !busy))
            let call = core.update([sample()], at: 4, recordingBusy: false, presentationBlocked: false)
            XCTAssertEqual(call == nil, busy)
        }
    }

    func testMultipleCallsDoNotChooseAnArbitraryAppEvenAfterDismissingOne() throws {
        var core = CallPromptCore()
        _ = core.update([sample()], at: 0, recordingBusy: false, presentationBlocked: false)
        core.dismiss(try XCTUnwrap(core.update([sample()], at: 2, recordingBusy: false, presentationBlocked: false)))
        let other = CallDetectionSample(application: .init(bundleID: "com.apple.FaceTime", name: "FaceTime"),
                                        presence: .active(contextID: "other-call", name: "FaceTime call"))
        XCTAssertNil(core.update([sample(), other], at: 4, recordingBusy: false, presentationBlocked: false))
        XCTAssertNil(core.update([sample(), other], at: 6, recordingBusy: false, presentationBlocked: false))
        XCTAssertEqual(core.update([other], at: 8, recordingBusy: false, presentationBlocked: false)?.application, other.application)
    }

    func testStaleDismissalCannotDismissADifferentCall() throws {
        var core = CallPromptCore()
        _ = core.update([sample()], at: 0, recordingBusy: false, presentationBlocked: false)
        let old = try XCTUnwrap(core.update([sample()], at: 2, recordingBusy: false, presentationBlocked: false))
        let next = sample(.active(contextID: "call-2", name: "Slack Huddle"))
        _ = core.update([next], at: 4, recordingBusy: false, presentationBlocked: false)
        core.dismiss(old)
        XCTAssertNotNil(core.update([next], at: 6, recordingBusy: false, presentationBlocked: false))
    }

    func testSwitchingBrowserCallContextsPreservesEarlierDismissal() throws {
        var core = CallPromptCore()
        _ = core.update([sample()], at: 0, recordingBusy: false, presentationBlocked: false)
        core.dismiss(try XCTUnwrap(core.update([sample()], at: 2, recordingBusy: false, presentationBlocked: false)))
        let other = sample(.active(contextID: "call-2", name: "Google Meet call"))
        _ = core.update([other], at: 4, recordingBusy: false, presentationBlocked: false)
        XCTAssertNotNil(core.update([other], at: 6, recordingBusy: false, presentationBlocked: false))
        XCTAssertNil(core.update([sample()], at: 8, recordingBusy: false, presentationBlocked: false))
        XCTAssertNil(core.update([sample()], at: 10, recordingBusy: false, presentationBlocked: false))
    }

    func testConfirmedPrejoinRearmsOnlyThatBrowserContext() throws {
        var core = CallPromptCore()
        _ = core.update([sample()], at: 0, recordingBusy: false, presentationBlocked: false)
        core.dismiss(try XCTUnwrap(core.update([sample()], at: 2, recordingBusy: false, presentationBlocked: false)))
        let other = sample(.active(contextID: "call-2", name: "Google Meet call"))
        _ = core.update([other], at: 4, recordingBusy: false, presentationBlocked: false)
        core.dismiss(try XCTUnwrap(core.update([other], at: 6, recordingBusy: false, presentationBlocked: false)))
        let prejoin = sample(.readyToJoin(contextID: "call-1"))
        _ = core.update([prejoin], at: 8, recordingBusy: false, presentationBlocked: false)
        _ = core.update([prejoin], at: 18, recordingBusy: false, presentationBlocked: false)
        _ = core.update([sample()], at: 20, recordingBusy: false, presentationBlocked: false)
        XCTAssertNotNil(core.update([sample()], at: 22, recordingBusy: false, presentationBlocked: false))
        _ = core.update([other], at: 24, recordingBusy: false, presentationBlocked: false)
        XCTAssertNil(core.update([other], at: 26, recordingBusy: false, presentationBlocked: false))
    }

    func testBriefPrejoinDoesNotLoseDismissal() throws {
        var core = CallPromptCore()
        _ = core.update([sample()], at: 0, recordingBusy: false, presentationBlocked: false)
        core.dismiss(try XCTUnwrap(core.update([sample()], at: 2, recordingBusy: false, presentationBlocked: false)))
        _ = core.update([sample(.readyToJoin(contextID: "call-1"))], at: 4, recordingBusy: false, presentationBlocked: false)
        _ = core.update([sample()], at: 6, recordingBusy: false, presentationBlocked: false)
        XCTAssertNil(core.update([sample()], at: 8, recordingBusy: false, presentationBlocked: false))
    }
}
