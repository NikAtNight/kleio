import XCTest
@testable import Scribe

final class MeetingMuteReaderTests: XCTestCase {
    private typealias Parser = MeetingMuteParser

    private func control(_ label: String, enabled: Bool = true) -> Parser.Control {
        .init(labels: [label], enabled: enabled)
    }

    private func context(_ labels: [String], provider: Parser.Provider = .meet, id: String = "opaque-call") -> Parser.Context {
        .init(id: id, provider: provider, controls: labels.map { control($0) })
    }

    private func parse(_ contexts: [Parser.Context], failure: String? = nil) -> MeetingMuteObservation {
        Parser.parse(.init(contexts: contexts, failure: failure), sourceName: "Meeting app", observedAt: 12.5)
    }

    private func assertUnavailable(_ observation: MeetingMuteObservation, file: StaticString = #filePath, line: UInt = #line) {
        guard case .unavailable = observation.state else { return XCTFail("Expected unavailable", file: file, line: line) }
        XCTAssertNil(observation.contextID, file: file, line: line)
    }

    func testMeetActionLabelsExpressOppositeCurrentState() {
        XCTAssertEqual(parse([context(["Leave call", "Turn off microphone"])]).state, .unmuted)
        XCTAssertEqual(parse([context(["Leave call", "Turn on microphone"])]).state, .muted)
    }

    func testShortcutSuffixAndWhitespaceDoNotChangeActionSemantics() {
        XCTAssertEqual(parse([context(["Leave call", "  Turn off microphone (⌘ + D)  "])]).state, .unmuted)
        assertUnavailable(parse([context(["Leave call", "Turn off microphone for Alex"])]))
    }

    func testPreviewMicrophoneIsInsufficient() {
        assertUnavailable(parse([context(["Join now", "Turn off microphone"])]))
        assertUnavailable(parse([context(["Leave call", "Join now", "Turn off microphone"])]))
    }

    func testOwnMicrophoneLabelsForNativeApps() {
        for (provider, leave) in [(Parser.Provider.teams, "Leave"), (.slack, "Leave huddle"), (.zoom, "Leave meeting")] {
            XCTAssertEqual(parse([context([leave, "Mute your microphone"], provider: provider)]).state, .unmuted)
            XCTAssertEqual(parse([context([leave, "Unmute my audio"], provider: provider)]).state, .muted)
        }
    }

    func testBareMuteAndParticipantActionsAreRejected() {
        for label in ["Mute", "Unmute", "Mute audio", "Mute microphone", "Mute Alex", "Unmute participant", "Mute tab", "Unmute site", "Mute all", "Ask to unmute"] {
            assertUnavailable(parse([context(["Leave", label], provider: .teams)]))
        }
    }

    func testDisconnectedComputerAudioIsUnavailable() {
        assertUnavailable(parse([context(["Leave meeting", "Join audio", "Mute my audio"], provider: .zoom)]))
    }

    func testWrongProviderLeaveMarkerDoesNotEstablishCall() {
        assertUnavailable(parse([context(["Leave huddle", "Turn off microphone"])]))
        assertUnavailable(parse([context(["Leave call", "Turn off microphone"], provider: .slack)]))
    }

    func testDuplicateControlsAndMultipleCallsAreAmbiguous() {
        assertUnavailable(parse([context(["Leave call", "Turn on microphone", "Turn off microphone"])]))
        assertUnavailable(parse([context(["Leave call", "Turn off microphone", "Turn off microphone"])]))
        assertUnavailable(parse([context(["Leave call", "Turn off microphone"], id: "a"), context(["Leave call", "Turn on microphone"], id: "b")]))
        assertUnavailable(parse([context(["Leave call", "Leave call", "Turn off microphone"])]))
    }

    func testDisabledMicrophoneNeverAdmitsAudio() {
        let value = Parser.Context(id: "call", provider: .meet, controls: [control("Leave call"), control("Turn off microphone", enabled: false)])
        assertUnavailable(parse([value]))
    }

    func testCheckboxLabelIsNotTreatedAsAnActionButton() {
        let value = Parser.Context(id: "call", provider: .teams, controls: [control("Leave"), .init(labels: ["Mute yourself"], enabled: true, role: "AXCheckBox")])
        assertUnavailable(parse([value]))
    }

    func testContradictoryAttributesFailClosed() {
        let value = Parser.Context(id: "call", provider: .meet, controls: [control("Leave call"), .init(labels: ["Turn off microphone", "Turn on microphone"], enabled: true)])
        assertUnavailable(parse([value]))
    }

    func testRepeatedAttributesOnSameButtonAreNotMultipleControls() {
        let value = Parser.Context(id: "call", provider: .meet, controls: [control("Leave call"), .init(labels: ["Turn off microphone", "Turn off microphone"], enabled: true)])
        XCTAssertEqual(parse([value]).state, .unmuted)
    }

    func testReadFailureDiscardsOtherwiseUnmutedSnapshot() {
        let call = context(["Leave call", "Turn off microphone"])
        for reason in ["AX control was destroyed", "AX read failed", "Read time limit exceeded", "Tree scan was incomplete"] {
            assertUnavailable(parse([call], failure: reason))
        }
    }

    func testNoCallAndMissingIdentityAreUnavailable() {
        assertUnavailable(parse([]))
        assertUnavailable(parse([context(["Leave call", "Turn off microphone"], id: "")]))
    }

    func testObservationKeepsOpaqueIdentityAndHostTimestamp() {
        let observation = parse([context(["Leave call", "Turn off microphone"])])
        XCTAssertEqual(observation.contextID, "opaque-call")
        XCTAssertEqual(observation.observedAt, 12.5)
        XCTAssertEqual(observation.sourceName, "Meeting app")
    }

    func testMicReadTimesSurviveTheRestOfTheWindowScan() {
        let mic = Parser.Control(labels: ["Turn off microphone"], enabled: true,
                                 readStartedAt: 12.2, observedAt: 12.21)
        let call = Parser.Context(id: "call", provider: .meet, controls: [control("Leave call"), mic])
        let observation = Parser.parse(.init(contexts: [call]), sourceName: "Browser", observedAt: 12.4)
        XCTAssertEqual(observation.state, .unmuted)
        XCTAssertEqual(observation.readStartedAt, 12.2)
        XCTAssertEqual(observation.observedAt, 12.21)
    }

    func testOnlyExactSupportedHTTPSOriginsAreAccepted() {
        let supported: [(String, Parser.Provider)] = [
            ("https://meet.google.com/abc", .meet), ("https://teams.microsoft.com/path", .teams),
            ("https://teams.cloud.microsoft/path", .teams), ("https://teams.live.com/path", .teams),
            ("https://app.slack.com/path", .slack), ("https://meet.google.com:443/abc", .meet)
        ]
        for (raw, provider) in supported { XCTAssertEqual(Parser.Provider.web(url: URL(string: raw)!), provider) }
        for raw in ["http://meet.google.com/abc", "https://meet.google.com.evil.example/", "https://evil.example/?next=https://meet.google.com", "https://meet.google.com@evil.example/", "https://user@meet.google.com/", "https://meet.google.com:444/", "https://sub.meet.google.com/", "https://slack.com/", "https://app.slack.com.evil.example/"] {
            XCTAssertNil(Parser.Provider.web(url: URL(string: raw)!), raw)
        }
    }

    func testNativeBundleIdentityIsExact() {
        XCTAssertEqual(Parser.Provider.native(bundleID: "com.microsoft.teams"), .teams)
        XCTAssertEqual(Parser.Provider.native(bundleID: "com.microsoft.teams2"), .teams)
        XCTAssertEqual(Parser.Provider.native(bundleID: "com.tinyspeck.slackmacgap"), .slack)
        XCTAssertEqual(Parser.Provider.native(bundleID: "us.zoom.xos"), .zoom)
        XCTAssertNil(Parser.Provider.native(bundleID: "evil.com.microsoft.teams2"))
    }

    func testCallPresenceDoesNotDependOnMicrophoneState() {
        for labels in [["Leave call"], ["Leave call", "Turn on microphone"], ["Leave call", "Turn off microphone"]] {
            XCTAssertEqual(CallPresenceParser.parse(.init(contexts: [context(labels)]), isBrowser: true),
                           .active(contextID: "opaque-call", name: "Google Meet call"))
        }
        let call = Parser.Context(id: "call", provider: .meet,
                                  controls: [control("Leave call"), control("Turn off microphone", enabled: false)])
        XCTAssertEqual(CallPresenceParser.parse(.init(contexts: [call]), isBrowser: true),
                       .active(contextID: "call", name: "Google Meet call"))
    }

    func testCallPresenceRequiresUniqueEnabledJoinedCallControl() {
        let cases: [[Parser.Context]] = [
            [context(["Leave call", "Leave call"])],
            [context(["Leave call"], id: "a"), context(["Leave call"], id: "b")],
            [context(["Leave call"], id: "")],
            [.init(id: "call", provider: .meet, controls: [control("Leave call", enabled: false)])],
            [context(["Leave call", "Join now"])],
            [context(["Leave call", "Ask to join"])],
            [context(["Leave meeting", "Join audio"], provider: .zoom)]
        ]
        for contexts in cases {
            XCTAssertEqual(CallPresenceParser.parse(.init(contexts: contexts), isBrowser: false), .unknown)
        }
    }

    func testCallPresenceRequiresButtonRatherThanMatchingText() {
        let call = Parser.Context(id: "call", provider: .meet,
                                  controls: [.init(labels: ["Leave call"], enabled: true, role: "AXStaticText")])
        XCTAssertEqual(CallPresenceParser.parse(.init(contexts: [call]), isBrowser: true), .unknown)
    }

    func testCallPresenceTreatsBrowserAbsenceAsUnknown() {
        for contexts in [[], [context(["Turn off microphone"])], [context(["Join audio"])]] {
            XCTAssertEqual(CallPresenceParser.parse(.init(contexts: contexts), isBrowser: true), .unknown)
            XCTAssertEqual(CallPresenceParser.parse(.init(contexts: contexts), isBrowser: false), .inactive)
        }
        XCTAssertEqual(CallPresenceParser.parse(.init(contexts: [context(["Leave call"])], failure: "Read failed"), isBrowser: false), .unknown)
    }

    func testReadableBrowserPrejoinIdentifiesTheContextThatCanBeRearmed() {
        XCTAssertEqual(CallPresenceParser.parse(.init(contexts: [context(["Join now"])]), isBrowser: true),
                       .readyToJoin(contextID: "opaque-call"))
        var disabled = context(["Join now"])
        disabled.controls[0].enabled = false
        XCTAssertEqual(CallPresenceParser.parse(.init(contexts: [disabled]), isBrowser: true), .unknown)
    }

    func testCallPresenceProviderLabelsAndFaceTimeCandidateControls() {
        let providers: [(Parser.Provider, String, String)] = [
            (.slack, "Leave huddle", "Slack Huddle"), (.teams, "Leave", "Teams call"),
            (.zoom, "Leave meeting", "Zoom call"), (.meet, "Leave call", "Google Meet call"),
            (.faceTime, "End call", "FaceTime call"), (.faceTime, "Hang up", "FaceTime call")
        ]
        for (provider, label, name) in providers {
            XCTAssertEqual(CallPresenceParser.parse(.init(contexts: [context([label], provider: provider)]), isBrowser: false),
                           .active(contextID: "opaque-call", name: name))
        }
        XCTAssertEqual(CallPresenceParser.parse(.init(contexts: [context(["Leave huddle"], provider: .teams)]), isBrowser: false), .inactive)
    }

    func testFaceTimeCallDetectionDoesNotEnableMuteReading() {
        XCTAssertTrue(MeetingMuteReader.supportsCallDetection(bundleID: "com.apple.FaceTime"))
        XCTAssertNil(Parser.Provider.native(bundleID: "com.apple.FaceTime"))
        assertUnavailable(parse([context(["End call", "Mute yourself"], provider: .faceTime)]))
        XCTAssertTrue(MeetingMuteReader.supportsCallDetection(bundleID: "com.google.Chrome"))
        XCTAssertTrue(MeetingMuteReader.supportsCallDetection(bundleID: "com.microsoft.teams2"))
        XCTAssertFalse(MeetingMuteReader.supportsCallDetection(bundleID: "evil.com.apple.FaceTime"))
        XCTAssertFalse(MeetingMuteReader.supportsCallDetection(bundleID: "com.apple.Music"))
    }

}
