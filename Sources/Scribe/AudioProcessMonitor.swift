import AppKit
import Foundation

@MainActor
final class AudioProcessMonitor {
    nonisolated private static let nativeConferenceBundleIDs: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams2",
        "com.microsoft.teams",
        "com.apple.FaceTime",
        "com.webex.meetinghost",
        "Cisco-Systems.Spark",
    ]

    nonisolated private static let browserBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "company.thebrowser.Browser",
        "com.microsoft.edgemac",
        "org.mozilla.firefox",
    ]

    private var meteringTap: SystemAudioTap?

    func hasConferencingProcess(for event: AutoRecordEvent) -> Bool {
        let runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return Self.hasConferencingProcess(runningBundleIDs: runningBundleIDs, joinURL: event.joinURL)
    }

    nonisolated static func hasConferencingProcess(runningBundleIDs: Set<String>, joinURL: URL?) -> Bool {
        if !runningBundleIDs.isDisjoint(with: nativeConferenceBundleIDs) {
            return true
        }
        guard eventUsesBrowserConference(joinURL) else { return false }
        return !runningBundleIDs.isDisjoint(with: browserBundleIDs)
    }

    func startMetering(onLevel: @escaping @Sendable (Float) -> Void) throws {
        guard meteringTap == nil else { return }
        let tap = SystemAudioTap()
        do {
            try tap.startMetering(onLevel: onLevel)
            meteringTap = tap
        } catch {
            tap.stop()
            throw error
        }
    }

    func stopMetering() {
        meteringTap?.stop()
        meteringTap = nil
    }

    nonisolated private static func eventUsesBrowserConference(_ joinURL: URL?) -> Bool {
        guard let host = joinURL?.host?.lowercased() else { return false }
        return host == "meet.google.com" ||
            host.hasSuffix(".meet.google.com") ||
            host == "teams.microsoft.com" ||
            host.hasSuffix(".teams.microsoft.com") ||
            host == "teams.live.com" ||
            host.hasSuffix(".teams.live.com")
    }
}
