import AppKit
import ApplicationServices
import CryptoKit

struct MeetingMuteObservation: Equatable, Sendable {
    var state: MeetingMuteState
    var contextID: String?
    var sourceName: String
    var observedAt: TimeInterval
    var readStartedAt: TimeInterval? = nil
}

protocol MeetingMuteReading {
    func read(application: RecordingApplication) -> MeetingMuteObservation
}

/// Candidate English control labels. Live app acceptance is required before relying on them.
enum MeetingMuteParser {
    enum Provider: Equatable {
        case teams, slack, zoom, meet, faceTime

        static func native(bundleID: String) -> Self? {
            switch bundleID {
            case "com.microsoft.teams", "com.microsoft.teams2": return .teams
            case "com.tinyspeck.slackmacgap": return .slack
            case "us.zoom.xos": return .zoom
            default: return nil
            }
        }

        static func web(url: URL) -> Self? {
            guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
                  url.port == nil || url.port == 443 else { return nil }
            switch url.host?.lowercased() {
            case "meet.google.com": return .meet
            case "teams.microsoft.com", "teams.cloud.microsoft", "teams.live.com": return .teams
            case "app.slack.com": return .slack
            default: return nil
            }
        }
    }

    struct Control: Equatable {
        var labels: [String]
        var enabled: Bool
        var role: String = "AXButton"
        var readStartedAt: TimeInterval? = nil
        var observedAt: TimeInterval? = nil
    }

    struct Context {
        var id: String
        var provider: Provider
        var controls: [Control]
    }

    struct Snapshot {
        var contexts: [Context]
        var failure: String? = nil
    }

    static func parse(_ snapshot: Snapshot, sourceName: String, observedAt: TimeInterval) -> MeetingMuteObservation {
        func unavailable(_ reason: String) -> MeetingMuteObservation {
            .init(state: .unavailable(reason), contextID: nil, sourceName: sourceName, observedAt: observedAt)
        }
        if let failure = snapshot.failure { return unavailable(failure) }
        guard !snapshot.contexts.contains(where: { $0.provider == .faceTime }) else {
            return unavailable("Automatic mute reading is unavailable for this app.")
        }
        let joined = snapshot.contexts.filter { context in
            context.controls.contains { control in control.role == "AXButton" && control.enabled && control.labels.contains { isLeave($0, provider: context.provider) } }
        }
        guard joined.count == 1, let context = joined.first else {
            return unavailable(joined.isEmpty ? "No readable joined call was found." : "More than one joined call is visible.")
        }
        let leaveControls = context.controls.filter { $0.role == "AXButton" && $0.enabled && $0.labels.contains { isLeave($0, provider: context.provider) } }
        guard leaveControls.count == 1 else { return unavailable("More than one call control group is visible.") }
        if context.controls.contains(where: { $0.labels.contains { ["join now", "join audio", "join with computer audio"].contains(normalize($0)) } }) {
            return unavailable("The call's microphone connection is uncertain.")
        }
        let candidates = context.controls.compactMap { control -> (state: MeetingMuteState, control: Control)? in
            guard control.role == "AXButton" else { return nil }
            let states = control.labels.compactMap { microphoneState($0, provider: context.provider) }
            guard let state = states.first else { return nil }
            guard control.enabled, states.allSatisfy({ $0 == state }) else { return (.unavailable("The microphone control is unreadable or disabled."), control) }
            return (state, control)
        }
        guard candidates.count == 1, let candidate = candidates.first else {
            return unavailable("The local microphone control could not be identified uniquely.")
        }
        let state = candidate.state
        if case .unavailable(let reason) = state { return unavailable(reason) }
        guard !context.id.isEmpty else { return unavailable("The call identity is unavailable.") }
        return .init(state: state, contextID: context.id, sourceName: sourceName,
                     observedAt: candidate.control.observedAt ?? observedAt,
                     readStartedAt: candidate.control.readStartedAt)
    }

    static func normalize(_ label: String) -> String {
        // Accept a keyboard shortcut suffix without accepting arbitrary text after a label.
        let lower = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let range = lower.range(of: #"\s*\([⌘⇧⌥⌃a-z0-9 +]+\)$"#, options: .regularExpression) else { return lower }
        return String(lower[..<range.lowerBound])
    }

    static func isLeave(_ label: String, provider: Provider) -> Bool {
        let label = normalize(label)
        switch provider {
        case .meet: return label == "leave call"
        case .teams: return ["leave", "leave call", "leave meeting", "hang up"].contains(label)
        case .slack: return label == "leave huddle"
        case .zoom: return ["leave", "leave meeting", "end meeting"].contains(label)
        case .faceTime: return ["end call", "hang up"].contains(label)
        }
    }

    private static func microphoneState(_ label: String, provider: Provider) -> MeetingMuteState? {
        let label = normalize(label)
        if provider == .meet {
            if label == "turn on microphone" { return .muted }
            if label == "turn off microphone" { return .unmuted }
        }
        // Bare Mute/Unmute can belong to participants or browser tab audio.
        // No installed app resource has supplied a verified stable own-mic identifier.
        if ["unmute your microphone", "unmute my microphone", "unmute my audio", "unmute yourself"].contains(label) { return .muted }
        if ["mute your microphone", "mute my microphone", "mute my audio", "mute yourself"].contains(label) { return .unmuted }
        return nil
    }
}

enum CallPresence: Equatable, Sendable {
    case active(contextID: String, name: String)
    case inactive
    case readyToJoin(contextID: String)
    case unknown
}

/// Candidate call controls share the bounded AX snapshot used for mute reading.
enum CallPresenceParser {
    private static let prejoinLabels = ["join now", "join call", "join meeting", "join huddle", "join audio", "join with computer audio", "ask to join"]

    static func parse(_ snapshot: MeetingMuteParser.Snapshot, isBrowser: Bool) -> CallPresence {
        guard snapshot.failure == nil else { return .unknown }
        let joined = snapshot.contexts.filter { context in
            context.controls.contains { control in
                control.role == "AXButton" && control.labels.contains {
                    MeetingMuteParser.isLeave($0, provider: context.provider)
                }
            }
        }
        guard !joined.isEmpty else {
            guard isBrowser else { return .inactive }
            let ready = snapshot.contexts.filter { context in
                !context.id.isEmpty && context.controls.contains { control in
                    control.role == "AXButton" && control.enabled && control.labels.contains {
                        // Joining audio can be offered within an existing call.
                        ["join now", "join call", "join meeting", "join huddle", "ask to join"].contains(MeetingMuteParser.normalize($0))
                    }
                }
            }
            return ready.count == 1 ? .readyToJoin(contextID: ready[0].id) : .unknown
        }
        guard joined.count == 1, let context = joined.first, !context.id.isEmpty else { return .unknown }
        let leave = context.controls.filter { control in
            control.role == "AXButton" && control.labels.contains {
                MeetingMuteParser.isLeave($0, provider: context.provider)
            }
        }
        guard leave.count == 1, leave[0].enabled else { return .unknown }
        guard !context.controls.contains(where: { control in
            control.labels.contains { prejoinLabels.contains(MeetingMuteParser.normalize($0)) }
        }) else { return .unknown }
        let name: String
        switch context.provider {
        case .slack: name = "Slack Huddle"
        case .teams: name = "Teams call"
        case .meet: name = "Google Meet call"
        case .zoom: name = "Zoom call"
        case .faceTime: name = "FaceTime call"
        }
        return .active(contextID: context.id, name: name)
    }
}

/// Accessibility and clock access for `MeetingMuteReader`. Tests substitute a scripted tree.
protocol MeetingAccessibility {
    var isTrusted: Bool { get }
    var now: TimeInterval { get }
    /// The only running instance of the bundle, or nil when there are none or several.
    func processID(bundleID: String) -> pid_t?
    func application(_ processID: pid_t) -> CFTypeRef
    func copy(_ element: CFTypeRef, _ attribute: String, timeout: Float) -> (error: AXError, value: CFTypeRef?)
    func set(_ element: CFTypeRef, _ attribute: String, to value: Bool) -> AXError
}

struct NativeMeetingAccessibility: MeetingAccessibility {
    var isTrusted: Bool { AXIsProcessTrusted() }
    var now: TimeInterval { RecordingClock.now }

    func processID(bundleID: String) -> pid_t? {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
        return apps.count == 1 ? apps[0].processIdentifier : nil
    }

    func application(_ processID: pid_t) -> CFTypeRef { AXUIElementCreateApplication(processID) }

    func copy(_ element: CFTypeRef, _ attribute: String, timeout: Float) -> (error: AXError, value: CFTypeRef?) {
        guard CFGetTypeID(element) == AXUIElementGetTypeID() else { return (.illegalArgument, nil) }
        let element = element as! AXUIElement
        // Timeouts belong to each AX object, not its application's subtree.
        guard AXUIElementSetMessagingTimeout(element, timeout) == .success else { return (.failure, nil) }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return (error, value)
    }

    func set(_ element: CFTypeRef, _ attribute: String, to value: Bool) -> AXError {
        guard CFGetTypeID(element) == AXUIElementGetTypeID() else { return .illegalArgument }
        let element = element as! AXUIElement
        guard AXUIElementSetMessagingTimeout(element, 0.1) == .success else { return .failure }
        return AXUIElementSetAttributeValue(element, attribute as CFString, value ? kCFBooleanTrue : kCFBooleanFalse)
    }
}

/// Call only from one serial background queue. AX references are never shared with the audio thread.
final class MeetingMuteReader: MeetingMuteReading {
    private struct CachedNode {
        var element: CFTypeRef
        var role: String
    }
    private struct Identity {
        var element: CFTypeRef
        var documentDigest: String?
        var token: String
    }
    private struct Limits {
        var duration: TimeInterval
        var nodes: Int
        var callTimeout: TimeInterval
        var depth: Int
        var failsBeyondDepth: Bool
    }
    private struct Exposure {
        var processID: pid_t
        var requestedAt: TimeInterval
        var restoresEnhancedInterface: Bool
    }
    private enum ReadFailure: Error { case unavailable }
    // Mute sync fails closed: an unread subtree could hide a contradicting microphone control.
    private static let muteLimits = Limits(duration: 0.18, nodes: 1800, callTimeout: 0.015, depth: 28, failsBeyondDepth: true)
    // Exposed Chromium trees are larger and slower on first access. Their deepest parts rarely hold call controls.
    private static let callLimits = Limits(duration: 0.4, nodes: 4000, callTimeout: 0.05, depth: 48, failsBeyondDepth: false)
    /// Chromium fills in a newly requested tree over a few seconds.
    static let exposureWarmUp: TimeInterval = 5
    private let ax: MeetingAccessibility
    private let log: (String) -> Void
    private var nodes: [CFHashCode: CachedNode] = [:]
    private var identities: [Identity] = []
    private var processID: pid_t?
    private var exposure: Exposure?
    private var lastDebugEntry: String?
    private var limits = MeetingMuteReader.muteLimits
    private var deadline: TimeInterval = 0
    private var visited = 0
    private var webAreas = 0
    private static let browserBundles: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome",
        "com.google.Chrome.beta", "com.google.Chrome.canary", "org.chromium.Chromium",
        "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "company.thebrowser.Browser",
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "app.zen-browser.zen",
        "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera"
    ]
    private static let skippedRoles: Set<String> = [
        "AXTextArea", "AXTextField", "AXStaticText", "AXSecureTextField", "AXMenu", "AXMenuBar",
        "AXMenuItem", "AXList", "AXTable", "AXOutline"
    ]
    private static let controlRoles: Set<String> = ["AXButton", "AXCheckBox", "AXSwitch"]

    init(accessibility: MeetingAccessibility = NativeMeetingAccessibility(),
         log: @escaping (String) -> Void = { DiagLog.logToFileOnly($0) }) {
        ax = accessibility
        self.log = log
    }

    static func supportsCallDetection(bundleID: String) -> Bool {
        MeetingMuteParser.Provider.native(bundleID: bundleID) != nil
            || bundleID == "com.apple.FaceTime" || browserBundles.contains(bundleID)
    }

    /// Slack (Electron) and Teams (WebView2) hide their web content until an assistive client asks for it.
    /// Teams does not support AXManualAccessibility. AXEnhancedUserInterface also animates window frame changes,
    /// which interferes with window managers, so it is limited to Teams.
    static func exposureAttribute(bundleID: String) -> String? {
        switch MeetingMuteParser.Provider.native(bundleID: bundleID) {
        case .slack: return "AXManualAccessibility"
        case .teams: return "AXEnhancedUserInterface"
        default: return nil
        }
    }

    func read(application: RecordingApplication) -> MeetingMuteObservation {
        let snapshot = snapshot(application: application, forCallDetection: false)
        let result = MeetingMuteParser.parse(snapshot, sourceName: application.name, observedAt: ax.now)
        if case .unavailable = result.state { identities.removeAll(keepingCapacity: true) }
        return result
    }

    /// Call only while call detection is enabled. The first read of Slack or Teams asks it to expose its content.
    func readCall(application: RecordingApplication, debug: Bool = false) -> CallPresence {
        let snapshot = snapshot(application: application, forCallDetection: true)
        var presence = CallPresenceParser.parse(snapshot, isBrowser: Self.browserBundles.contains(application.bundleID))
        var reason = snapshot.failure
        if presence == .inactive, Self.exposureAttribute(bundleID: application.bundleID) != nil, snapshot.failure == nil {
            // An empty or still-loading tree is not evidence that the call ended.
            if let exposure, ax.now - exposure.requestedAt < Self.exposureWarmUp {
                presence = .unknown
                reason = "content is still loading"
            } else if webAreas == 0 {
                presence = .unknown
                reason = "no web content is exposed"
            }
        }
        if debug {
            // Button labels only. Window titles and URLs are never read into the snapshot.
            var seen = Set<String>()
            let labels = snapshot.contexts.flatMap(\.controls)
                .filter { $0.role == "AXButton" && $0.enabled }
                .flatMap(\.labels)
                .map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            let summary: String
            switch presence {
            case .active(_, let name): summary = "active (\(name))"
            case .inactive: summary = "inactive"
            case .readyToJoin: summary = "ready to join"
            case .unknown: summary = "unknown (\(reason ?? "ambiguous controls"))"
            }
            // Polls repeat every 2 seconds, so only log when the result or the buttons change.
            let buttons = labels.prefix(80).joined(separator: " | ")
            if lastDebugEntry != summary + buttons {
                lastDebugEntry = summary + buttons
                log("call detection \(application.bundleID): \(summary); \(snapshot.contexts.count) contexts, "
                    + "\(visited) nodes; enabled buttons: \(buttons)")
            }
        }
        return presence
    }

    /// Clears AXEnhancedUserInterface if this reader turned it on. Slack's flag has no visible side effect.
    func releaseAccessibility() {
        guard let exposure else { return }
        self.exposure = nil
        guard exposure.restoresEnhancedInterface else { return }
        _ = ax.set(ax.application(exposure.processID), "AXEnhancedUserInterface", to: false)
    }

    private func expose(_ root: CFTypeRef, processID: pid_t, bundleID: String) {
        guard exposure?.processID != processID, let name = Self.exposureAttribute(bundleID: bundleID) else { return }
        var restores = false
        if name == "AXEnhancedUserInterface" {
            // Leave another assistive client's setting alone, including when this reader is released.
            let current = ax.copy(root, name, timeout: 0.05)
            guard (current.value as? Bool) != true else {
                exposure = .init(processID: processID, requestedAt: ax.now, restoresEnhancedInterface: false)
                return
            }
            // Only claim the flag when it was read as off. After a timed-out read it may
            // belong to VoiceOver, so Kleio sets it but never clears it.
            restores = current.error == .success ? (current.value as? Bool) == false : current.error == .noValue
        }
        // Teams applies the flag but reports kAXErrorNotImplemented, so the result is not a reliable signal.
        _ = ax.set(root, name, to: true)
        exposure = .init(processID: processID, requestedAt: ax.now, restoresEnhancedInterface: restores)
    }

    private func snapshot(application: RecordingApplication, forCallDetection: Bool) -> MeetingMuteParser.Snapshot {
        limits = forCallDetection ? Self.callLimits : Self.muteLimits
        deadline = ax.now + limits.duration
        visited = 0
        webAreas = 0
        func unavailable(_ reason: String) -> MeetingMuteParser.Snapshot {
            nodes.removeAll(keepingCapacity: true)
            if !forCallDetection { identities.removeAll(keepingCapacity: true) }
            return .init(contexts: [], failure: reason)
        }
        let nativeProvider: MeetingMuteParser.Provider? = forCallDetection && application.bundleID == "com.apple.FaceTime"
            ? .faceTime : MeetingMuteParser.Provider.native(bundleID: application.bundleID)
        let isBrowser = Self.browserBundles.contains(application.bundleID)
        guard nativeProvider != nil || isBrowser else {
            return unavailable("Automatic mute reading is unavailable for this app.")
        }
        guard ax.isTrusted else { return unavailable("Accessibility access is required to read meeting mute controls.") }
        guard let pid = ax.processID(bundleID: application.bundleID) else { return unavailable("A unique running meeting app could not be found.") }
        if processID != pid {
            nodes.removeAll(keepingCapacity: true)
            identities.removeAll(keepingCapacity: true)
            processID = pid
        }
        let root = ax.application(pid)
        if forCallDetection { expose(root, processID: pid, bundleID: application.bundleID) }
        do {
            var contexts: [MeetingMuteParser.Context] = []
            var currentIdentities: [Identity] = []
            for window in try windows(root) {
                if isBrowser {
                    try webContexts(window, depth: 0, contexts: &contexts, currentIdentities: &currentIdentities)
                } else if let provider = nativeProvider {
                    let id = identity(for: window, documentDigest: nil, current: &currentIdentities)
                    var controls: [MeetingMuteParser.Control] = []
                    try collectControls(window, depth: 0, controls: &controls)
                    contexts.append(.init(id: id, provider: provider, controls: controls))
                }
            }
            try checkBudget()
            if forCallDetection {
                // Retain hidden browser contexts across unreadable or unrelated foreground tabs.
                let retained = identities.filter { previous in
                    !currentIdentities.contains { $0.token == previous.token }
                }
                identities = Array((currentIdentities + retained).prefix(128))
            } else {
                identities = currentIdentities
            }
            return .init(contexts: contexts)
        } catch {
            return unavailable("Meeting controls are unreadable or exceeded the read time limit.")
        }
    }

    /// Windows on another Space are missing from AXWindows, but the main or focused window can still be read.
    private func windows(_ root: CFTypeRef) throws -> [CFTypeRef] {
        guard var windows = try attribute(root, kAXWindowsAttribute) as? [CFTypeRef] else { throw ReadFailure.unavailable }
        for name in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            // These are extras, so an error reading one means no extra window rather than a failed read.
            guard let window = (try? attribute(root, name)) ?? nil,
                  !windows.contains(where: { CFEqual($0, window) }) else { continue }
            windows.append(window)
        }
        return windows
    }

    private func checkBudget() throws {
        guard ax.now < deadline, visited < limits.nodes else { throw ReadFailure.unavailable }
    }

    private func attribute(_ element: CFTypeRef, _ name: String) throws -> CFTypeRef? {
        try checkBudget()
        let timeout = Float(min(limits.callTimeout, max(0.001, deadline - ax.now)))
        let (error, value) = ax.copy(element, name, timeout: timeout)
        try checkBudget()
        switch error {
        case .success: return value
        case .attributeUnsupported, .noValue: return nil
        default: throw ReadFailure.unavailable
        }
    }

    private func role(_ element: CFTypeRef) throws -> String {
        try checkBudget()
        visited += 1
        let key = CFHash(element)
        if let cached = nodes[key], CFEqual(cached.element, element), !Self.controlRoles.contains(cached.role) { return cached.role }
        guard let role = try attribute(element, kAXRoleAttribute) as? String else { throw ReadFailure.unavailable }
        nodes[key] = .init(element: element, role: role)
        if nodes.count > limits.nodes { nodes.removeAll(keepingCapacity: true) }
        return role
    }

    private func children(_ element: CFTypeRef) throws -> [CFTypeRef] {
        try attribute(element, kAXChildrenAttribute) as? [CFTypeRef] ?? []
    }

    /// Beyond the depth limit, call detection keeps what it has read. Mute sync fails the read.
    private func withinDepth(_ depth: Int) throws -> Bool {
        guard depth >= limits.depth else { return true }
        if limits.failsBeyondDepth { throw ReadFailure.unavailable }
        return false
    }

    private func collectControls(_ element: CFTypeRef, depth: Int, controls: inout [MeetingMuteParser.Control], isWebDocument: Bool = false) throws {
        guard try withinDepth(depth) else { return }
        let role = try role(element)
        guard !Self.skippedRoles.contains(role) else { return }
        if role == "AXWebArea" { webAreas += 1 }
        // An embedded document has a separate origin and cannot supply the outer call's controls.
        if isWebDocument && depth > 0 && role == "AXWebArea" { return }
        if Self.controlRoles.contains(role) {
            let readStartedAt = ax.now
            var labels: [String] = []
            for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
                if let text = try attribute(element, name) as? String { labels.append(text) }
            }
            guard let enabled = try attribute(element, kAXEnabledAttribute) as? NSNumber else { throw ReadFailure.unavailable }
            controls.append(.init(labels: labels, enabled: enabled.boolValue, role: role,
                                  readStartedAt: readStartedAt, observedAt: ax.now))
            return
        }
        for child in try children(element) { try collectControls(child, depth: depth + 1, controls: &controls, isWebDocument: isWebDocument) }
    }

    private func webContexts(_ element: CFTypeRef, depth: Int, contexts: inout [MeetingMuteParser.Context], currentIdentities: inout [Identity]) throws {
        guard try withinDepth(depth) else { return }
        let role = try role(element)
        guard !Self.skippedRoles.contains(role), !Self.controlRoles.contains(role) else { return }
        if role == "AXWebArea" {
            let raw = try attribute(element, kAXURLAttribute)
            let url = (raw as? URL) ?? (raw as? String).flatMap(URL.init(string:))
            guard let url, let provider = MeetingMuteParser.Provider.web(url: url) else { return }
            // Keep only an opaque digest in memory to detect navigation. Never emit room URLs.
            let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
            let id = identity(for: element, documentDigest: digest, current: &currentIdentities)
            var controls: [MeetingMuteParser.Control] = []
            try collectControls(element, depth: 0, controls: &controls, isWebDocument: true)
            contexts.append(.init(id: id, provider: provider, controls: controls))
            return
        }
        for child in try children(element) { try webContexts(child, depth: depth + 1, contexts: &contexts, currentIdentities: &currentIdentities) }
    }

    private func identity(for element: CFTypeRef, documentDigest: String?, current: inout [Identity]) -> String {
        let existing = identities.first { CFEqual($0.element, element) && $0.documentDigest == documentDigest }
        let identity = existing ?? Identity(element: element, documentDigest: documentDigest, token: UUID().uuidString)
        current.append(identity)
        return identity.token
    }
}
