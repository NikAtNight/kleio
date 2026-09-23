import ApplicationServices
import XCTest
@testable import Scribe

/// Runs `MeetingMuteReader` against a scripted Accessibility tree instead of parser snapshots.
final class MeetingReaderAccessibilityTests: XCTestCase {
    private final class Node: NSObject {
        var attributes: [String: Any]
        init(_ attributes: [String: Any]) { self.attributes = attributes }
    }

    private final class ScriptedAccessibility: MeetingAccessibility {
        var isTrusted = true
        var now: TimeInterval = 100
        var secondsPerCall: TimeInterval = 0
        var processIDs: [String: pid_t] = [:]
        var roots: [pid_t: Node] = [:]
        var writes: [(processID: pid_t, attribute: String, value: Bool)] = []
        var failingAttributes: Set<String> = []

        func processID(bundleID: String) -> pid_t? { processIDs[bundleID] }

        func application(_ processID: pid_t) -> CFTypeRef {
            if let root = roots[processID] { return root }
            let root = Node(["AXRole": "AXApplication", "pid": processID])
            roots[processID] = root
            return root
        }

        func copy(_ element: CFTypeRef, _ attribute: String, timeout: Float) -> (error: AXError, value: CFTypeRef?) {
            now += secondsPerCall
            if failingAttributes.contains(attribute) { return (.cannotComplete, nil) }
            guard let value = (element as? Node)?.attributes[attribute] else { return (.noValue, nil) }
            return (.success, value as AnyObject)
        }

        func set(_ element: CFTypeRef, _ attribute: String, to value: Bool) -> AXError {
            guard let node = element as? Node, let pid = node.attributes["pid"] as? pid_t else { return .illegalArgument }
            writes.append((pid, attribute, value))
            node.attributes[attribute] = value
            return attribute == "AXEnhancedUserInterface" ? .notImplemented : .success
        }
    }

    private let slack = RecordingApplication(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")
    private let teams = RecordingApplication(bundleID: "com.microsoft.teams2", name: "Microsoft Teams")
    private let zoom = RecordingApplication(bundleID: "us.zoom.xos", name: "zoom.us")
    private let chrome = RecordingApplication(bundleID: "com.google.Chrome", name: "Google Chrome")

    private func button(_ label: String, enabled: Bool = true) -> Node {
        Node(["AXRole": "AXButton", "AXDescription": label, "AXEnabled": NSNumber(value: enabled)])
    }

    private func group(_ children: [Node], role: String = "AXGroup") -> Node {
        Node(["AXRole": role, "AXChildren": children])
    }

    private func window(_ controls: [Node]) -> Node {
        let window = group([group([group(controls, role: "AXWebArea")])], role: "AXWindow")
        window.attributes["AXTitle"] = "Secret channel title"
        return window
    }

    private func install(_ app: RecordingApplication, pid: pid_t, windows: [Node], main: Node? = nil,
                         in ax: ScriptedAccessibility) {
        ax.processIDs[app.bundleID] = pid
        let root = ax.application(pid) as! Node
        root.attributes["AXWindows"] = windows
        root.attributes["AXMainWindow"] = main
        root.attributes["AXFocusedWindow"] = main
    }

    func testEmptyWindowListFallsBackToMainAndFocusedWindowOnce() {
        let ax = ScriptedAccessibility()
        let huddle = window([button("Leave huddle"), button("Mute your microphone")])
        install(slack, pid: 10, windows: [], main: huddle, in: ax)
        let reader = MeetingMuteReader(accessibility: ax)
        // Reading the same window twice would look like two calls and report unknown.
        guard case .active(_, "Slack Huddle") = reader.readCall(application: slack) else {
            return XCTFail("Expected the huddle in the main window")
        }
        XCTAssertEqual(reader.read(application: slack).state, .unmuted)
    }

    func testTreeDeeperThanTheLimitStillFindsTheShallowLeaveButton() {
        let ax = ScriptedAccessibility()
        var deep = group([button("Unrelated")])
        for _ in 0..<80 { deep = group([deep]) }
        install(teams, pid: 20, windows: [window([button("Leave"), button("Mute your microphone"), deep])], in: ax)
        let reader = MeetingMuteReader(accessibility: ax)
        guard case .active(_, "Teams call") = reader.readCall(application: teams) else {
            return XCTFail("Expected the shallow leave button to count")
        }
        // Mute sync still fails closed when part of the tree was not read.
        guard case .unavailable = reader.read(application: teams).state else { return XCTFail("Expected mute sync to fail closed") }
    }

    func testCallDetectionHasALargerTimeBudgetThanMuteSync() {
        let ax = ScriptedAccessibility()
        let filler = (0..<1200).map { _ in group([]) }
        install(teams, pid: 20, windows: [window(filler + [button("Leave"), button("Mute your microphone")])], in: ax)
        XCTAssertEqual(MeetingMuteReader(accessibility: ax).read(application: teams).state, .unmuted)
        // About 2,400 uncached attribute reads take 0.24 s at this rate.
        ax.secondsPerCall = 0.0001
        guard case .unavailable = MeetingMuteReader(accessibility: ax).read(application: teams).state else {
            return XCTFail("Expected the mute read to time out")
        }
        guard case .active = MeetingMuteReader(accessibility: ax).readCall(application: teams) else {
            return XCTFail("Expected call detection to finish")
        }
    }

    func testContentExposureIsRequestedOncePerProcessOnlyForSlackAndTeamsCallDetection() {
        let ax = ScriptedAccessibility()
        for (index, app) in [slack, teams, zoom, chrome].enumerated() {
            install(app, pid: pid_t(index + 1), windows: [window([])], in: ax)
        }
        let readers = [slack, teams, zoom, chrome].map { ($0, MeetingMuteReader(accessibility: ax)) }
        for (app, reader) in readers { _ = reader.read(application: app) }
        XCTAssertTrue(ax.writes.isEmpty, "Mute sync must not change other apps")

        for _ in 0..<3 { for (app, reader) in readers { _ = reader.readCall(application: app) } }
        XCTAssertEqual(ax.writes.map(\.processID), [1, 2])
        XCTAssertEqual(ax.writes.map(\.attribute), ["AXManualAccessibility", "AXEnhancedUserInterface"])
        XCTAssertEqual(ax.writes.map(\.value), [true, true])

        // A relaunched app is a new process and is asked again.
        install(slack, pid: 11, windows: [window([])], in: ax)
        _ = readers[0].1.readCall(application: slack)
        _ = readers[0].1.readCall(application: slack)
        XCTAssertEqual(ax.writes.last?.processID, 11)
        XCTAssertEqual(ax.writes.count, 3)

        // Turning detection off clears only the Teams flag this reader turned on.
        for (_, reader) in readers { reader.releaseAccessibility() }
        XCTAssertEqual(ax.writes.count, 4)
        XCTAssertEqual(ax.writes.last?.processID, 2)
        XCTAssertEqual(ax.writes.last?.attribute, "AXEnhancedUserInterface")
        XCTAssertEqual(ax.writes.last?.value, false)
    }

    func testTeamsFlagSetBySomeoneElseIsLeftAlone() {
        let ax = ScriptedAccessibility()
        install(teams, pid: 2, windows: [window([])], in: ax)
        (ax.application(2) as! Node).attributes["AXEnhancedUserInterface"] = true
        let reader = MeetingMuteReader(accessibility: ax)
        _ = reader.readCall(application: teams)
        reader.releaseAccessibility()
        XCTAssertTrue(ax.writes.isEmpty)
    }

    func testFreshlyExposedTreeReadsUnknownUntilPopulated() {
        let ax = ScriptedAccessibility()
        let hidden = group([group([])], role: "AXWindow")
        install(slack, pid: 10, windows: [hidden], in: ax)
        let reader = MeetingMuteReader(accessibility: ax)
        XCTAssertEqual(reader.readCall(application: slack), .unknown)
        ax.now += 2
        XCTAssertEqual(reader.readCall(application: slack), .unknown)

        // Web content that is still filling in is not evidence that no call is running.
        hidden.attributes["AXChildren"] = [group([], role: "AXWebArea")]
        XCTAssertEqual(reader.readCall(application: slack), .unknown)
        ax.now += MeetingMuteReader.exposureWarmUp
        XCTAssertEqual(reader.readCall(application: slack), .inactive)

        // A tree that never exposes web content stays unknown.
        hidden.attributes["AXChildren"] = [group([])]
        XCTAssertEqual(reader.readCall(application: slack), .unknown)
    }

    func testLeaveButtonCountsDuringWarmUp() {
        let ax = ScriptedAccessibility()
        install(slack, pid: 10, windows: [window([button("Leave huddle")])], in: ax)
        guard case .active = MeetingMuteReader(accessibility: ax).readCall(application: slack) else {
            return XCTFail("Expected found controls to count immediately")
        }
    }

    func testDebugLoggingIsOffByDefaultAndOmitsWindowTitles() {
        let ax = ScriptedAccessibility()
        install(slack, pid: 10, windows: [window([button("Leave huddle"), button("Mute", enabled: false)])], in: ax)
        var lines: [String] = []
        let reader = MeetingMuteReader(accessibility: ax, log: { lines.append($0) })
        _ = reader.readCall(application: slack)
        _ = reader.read(application: slack)
        XCTAssertTrue(lines.isEmpty)

        _ = reader.readCall(application: slack, debug: true)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("active (Slack Huddle)"), lines[0])
        XCTAssertTrue(lines[0].contains("Leave huddle"), lines[0])
        XCTAssertFalse(lines[0].contains("Mute"), "Disabled buttons are not listed")
        XCTAssertFalse(lines[0].contains("Secret"), "Window titles are never logged")

        // Repeated polls with the same result stay quiet.
        _ = reader.readCall(application: slack, debug: true)
        XCTAssertEqual(lines.count, 1)
        (ax.application(10) as! Node).attributes["AXWindows"] = [window([button("Start huddle")])]
        _ = reader.readCall(application: slack, debug: true)
        XCTAssertEqual(lines.count, 2)
    }

    func testTeamsFlagIsNeverClearedWhenItsStateCouldNotBeRead() {
        let ax = ScriptedAccessibility()
        install(teams, pid: 2, windows: [window([])], in: ax)
        ax.failingAttributes = ["AXEnhancedUserInterface"]
        let reader = MeetingMuteReader(accessibility: ax)
        _ = reader.readCall(application: teams)
        reader.releaseAccessibility()
        // It may belong to VoiceOver, so Kleio sets it but doesn't clear it.
        XCTAssertEqual(ax.writes.map(\.value), [true])
    }

    func testErrorReadingAnExtraWindowDoesNotFailTheRead() {
        let ax = ScriptedAccessibility()
        install(teams, pid: 20, windows: [window([button("Leave"), button("Mute your microphone")])], in: ax)
        ax.failingAttributes = ["AXMainWindow", "AXFocusedWindow"]
        let reader = MeetingMuteReader(accessibility: ax)
        guard case .active = reader.readCall(application: teams) else { return XCTFail("Expected the call") }
        XCTAssertEqual(reader.read(application: teams).state, .unmuted)
    }

    @MainActor
    func testControllerDebugSettingDefaultsOff() throws {
        let suite = "MeetingReaderAccessibilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(CallDetectionController(defaults: defaults).debugLogging)
        defaults.set(true, forKey: "callDetectionDebug")
        XCTAssertTrue(CallDetectionController(defaults: defaults).debugLogging)
    }
}
