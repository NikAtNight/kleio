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
        case teams, slack, zoom, meet

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

    private static func normalize(_ label: String) -> String {
        // Accept a keyboard shortcut suffix without accepting arbitrary text after a label.
        let lower = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let range = lower.range(of: #"\s*\([⌘⇧⌥⌃a-z0-9 +]+\)$"#, options: .regularExpression) else { return lower }
        return String(lower[..<range.lowerBound])
    }

    private static func isLeave(_ label: String, provider: Provider) -> Bool {
        let label = normalize(label)
        switch provider {
        case .meet: return label == "leave call"
        case .teams: return ["leave", "leave call", "leave meeting", "hang up"].contains(label)
        case .slack: return label == "leave huddle"
        case .zoom: return ["leave", "leave meeting", "end meeting"].contains(label)
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

/// Call only from one serial background queue. AX references are never shared with the audio thread.
final class MeetingMuteReader: MeetingMuteReading {
    private struct CachedNode {
        var element: AXUIElement
        var role: String
    }
    private struct Identity {
        var element: AXUIElement
        var documentDigest: String?
        var token: String
    }
    private enum ReadFailure: Error { case unavailable }
    private var nodes: [CFHashCode: CachedNode] = [:]
    private var identities: [Identity] = []
    private var processID: pid_t?
    private var deadline: TimeInterval = 0
    private var visited = 0
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

    func read(application: RecordingApplication) -> MeetingMuteObservation {
        let startedAt = RecordingClock.now
        deadline = startedAt + 0.18
        visited = 0
        func unavailable(_ reason: String) -> MeetingMuteObservation {
            nodes.removeAll(keepingCapacity: true)
            identities.removeAll(keepingCapacity: true)
            return MeetingMuteParser.parse(.init(contexts: [], failure: reason), sourceName: application.name, observedAt: RecordingClock.now)
        }
        let nativeProvider = MeetingMuteParser.Provider.native(bundleID: application.bundleID)
        let isBrowser = Self.browserBundles.contains(application.bundleID)
        guard nativeProvider != nil || isBrowser else {
            return unavailable("Automatic mute reading is unavailable for this app.")
        }
        guard AXIsProcessTrusted() else { return unavailable("Accessibility access is required to read meeting mute controls.") }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: application.bundleID).filter { !$0.isTerminated }
        guard apps.count == 1, let app = apps.first else { return unavailable("A unique running meeting app could not be found.") }
        if processID != app.processIdentifier {
            nodes.removeAll(keepingCapacity: true)
            identities.removeAll(keepingCapacity: true)
            processID = app.processIdentifier
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        do {
            guard let windows = try attribute(root, kAXWindowsAttribute) as? [AXUIElement] else { throw ReadFailure.unavailable }
            var contexts: [MeetingMuteParser.Context] = []
            var currentIdentities: [Identity] = []
            for window in windows {
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
            identities = currentIdentities
            let result = MeetingMuteParser.parse(.init(contexts: contexts), sourceName: application.name, observedAt: RecordingClock.now)
            if case .unavailable = result.state { identities.removeAll(keepingCapacity: true) }
            return result
        } catch {
            return unavailable("Meeting controls are unreadable or exceeded the read time limit.")
        }
    }

    private func checkBudget() throws {
        guard RecordingClock.now < deadline, visited < 1800 else { throw ReadFailure.unavailable }
    }

    private func attribute(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
        try checkBudget()
        // Timeouts belong to each AX object, not its application's subtree.
        let timeout = Float(min(0.015, max(0.001, deadline - RecordingClock.now)))
        guard AXUIElementSetMessagingTimeout(element, timeout) == .success else { throw ReadFailure.unavailable }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        try checkBudget()
        switch error {
        case .success: return value
        case .attributeUnsupported, .noValue: return nil
        default: throw ReadFailure.unavailable
        }
    }

    private func role(_ element: AXUIElement) throws -> String {
        try checkBudget()
        visited += 1
        let key = CFHash(element)
        if let cached = nodes[key], CFEqual(cached.element, element), !Self.controlRoles.contains(cached.role) { return cached.role }
        guard let role = try attribute(element, kAXRoleAttribute) as? String else { throw ReadFailure.unavailable }
        nodes[key] = .init(element: element, role: role)
        if nodes.count > 1800 { nodes.removeAll(keepingCapacity: true) }
        return role
    }

    private func children(_ element: AXUIElement) throws -> [AXUIElement] {
        try attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private func collectControls(_ element: AXUIElement, depth: Int, controls: inout [MeetingMuteParser.Control], isWebDocument: Bool = false) throws {
        guard depth < 28 else { throw ReadFailure.unavailable }
        let role = try role(element)
        guard !Self.skippedRoles.contains(role) else { return }
        // An embedded document has a separate origin and cannot supply the outer call's controls.
        if isWebDocument && depth > 0 && role == "AXWebArea" { return }
        if Self.controlRoles.contains(role) {
            let readStartedAt = RecordingClock.now
            var labels: [String] = []
            for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
                if let text = try attribute(element, name) as? String { labels.append(text) }
            }
            guard let enabled = try attribute(element, kAXEnabledAttribute) as? NSNumber else { throw ReadFailure.unavailable }
            controls.append(.init(labels: labels, enabled: enabled.boolValue, role: role,
                                  readStartedAt: readStartedAt, observedAt: RecordingClock.now))
            return
        }
        for child in try children(element) { try collectControls(child, depth: depth + 1, controls: &controls, isWebDocument: isWebDocument) }
    }

    private func webContexts(_ element: AXUIElement, depth: Int, contexts: inout [MeetingMuteParser.Context], currentIdentities: inout [Identity]) throws {
        guard depth < 28 else { throw ReadFailure.unavailable }
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

    private func identity(for element: AXUIElement, documentDigest: String?, current: inout [Identity]) -> String {
        let existing = identities.first { CFEqual($0.element, element) && $0.documentDigest == documentDigest }
        let identity = existing ?? Identity(element: element, documentDigest: documentDigest, token: UUID().uuidString)
        current.append(identity)
        return identity.token
    }
}
